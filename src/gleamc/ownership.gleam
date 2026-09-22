//// Ownership pass (M6): a direct port of Vesper's `ir_ownership.insert`.
////
//// Model: every handle local owns one reference. At an owning use the
//// argument is moved (if it is the last use) or retained (if still live);
//// ownership liveness then decides where each local dies, emitting a drop
//// at block exit. This is the deterministic refcount mechanism: no GC, and
//// the generated C shows every retain/release.

import gleam/dict.{type Dict}
import gleam/list
import gleamc/ast.{
  type Type, TApp, TBool, TFloat, TFun, TInt, TNamed, TNil, TString, TTuple,
  TVar,
}
import gleamc/checker
import gleamc/ir

pub fn insert(
  module: ir.Module,
  ctors: Dict(String, checker.CtorInfo),
) -> ir.Module {
  let ir.Module(functions) = module
  ir.Module(list.map(functions, fn(function) { insert_fn(function, ctors) }))
}

// ---------------------------------------------------------------------------
// needs_drop
// ---------------------------------------------------------------------------

pub fn needs_drop(ty: Type, ctors: Dict(String, checker.CtorInfo)) -> Bool {
  let fields_of = type_fields(ctors)
  let recursive = recursive_types_from(fields_of)
  needs_drop_seen(ty, fields_of, recursive, [])
}

fn needs_drop_seen(ty, fields_of, recursive, seen) -> Bool {
  case ty {
    TString -> True
    TInt -> False
    TFloat -> False
    TBool -> False
    TNil -> False
    TTuple(types) ->
      list.any(types, fn(inner) {
        needs_drop_seen(inner, fields_of, recursive, seen)
      })
    TFun(_, _) -> True
    TVar(_) -> False
    TApp(_, args) ->
      list.any(args, fn(inner) {
        needs_drop_seen(inner, fields_of, recursive, seen)
      })
    TNamed(name) ->
      case dict.get(recursive, name) {
        Ok(True) -> True
        _ ->
          case list.contains(seen, name) {
            True -> False
            False ->
              case dict.get(fields_of, name) {
                Error(_) -> False
                Ok(fields) ->
                  list.any(fields, fn(inner) {
                    needs_drop_seen(inner, fields_of, recursive, [name, ..seen])
                  })
              }
          }
      }
  }
}

/// Types that participate in a reference cycle (including self-reference).
/// Such types are heap cells with a refcount.
pub fn recursive_types(
  ctors: Dict(String, checker.CtorInfo),
) -> Dict(String, Bool) {
  recursive_types_from(type_fields(ctors))
}

fn recursive_types_from(fields_of) -> Dict(String, Bool) {
  let names = dict.keys(fields_of)
  list.fold(names, dict.new(), fn(acc, name) {
    case reaches(name, name, fields_of, []) {
      True -> dict.insert(acc, name, True)
      False -> acc
    }
  })
}

fn reaches(target, current, fields_of, visited) -> Bool {
  case list.contains(visited, current) {
    True -> False
    False -> {
      let next_visited = [current, ..visited]
      let refs = case dict.get(fields_of, current) {
        Ok(fields) -> list.flat_map(fields, references)
        Error(_) -> []
      }
      list.any(refs, fn(ref) {
        case ref == target {
          True -> True
          False -> reaches(target, ref, fields_of, next_visited)
        }
      })
    }
  }
}

fn references(ty) -> List(String) {
  case ty {
    TNamed(name) -> [name]
    TApp(name, args) -> [name, ..list.flat_map(args, references)]
    TTuple(items) -> list.flat_map(items, references)
    _ -> []
  }
}

/// Type name -> all field types across its variants.
pub fn type_fields(
  ctors: Dict(String, checker.CtorInfo),
) -> Dict(String, List(Type)) {
  list.fold(dict.to_list(ctors), dict.new(), fn(acc, entry) {
    let #(_ctor, info) = entry
    let checker.CtorInfo(type_name, fields) = info
    let field_types =
      list.map(fields, fn(field) {
        let #(_, field_ty) = field
        field_ty
      })
    let existing = case dict.get(acc, type_name) {
      Ok(found) -> found
      Error(_) -> []
    }
    dict.insert(acc, type_name, list.append(existing, field_types))
  })
}

// ---------------------------------------------------------------------------
// per-function pass
// ---------------------------------------------------------------------------

fn insert_fn(function: ir.Function, ctors) -> ir.Function {
  let ir.Function(name, params, ret, blocks, locals) = function
  let handles =
    list.fold(locals, dict.new(), fn(acc, local) {
      let ir.Local(local_name, local_ty) = local
      case needs_drop(local_ty, ctors) {
        True -> dict.insert(acc, local_name, local_ty)
        False -> acc
      }
    })
  case dict.is_empty(handles) {
    True -> function
    False ->
      ir.Function(
        name,
        params,
        ret,
        insert_blocks(blocks, params, locals, handles),
        locals,
      )
  }
}

fn insert_blocks(
  blocks: List(ir.Block),
  params: List(String),
  locals: List(ir.Local),
  handles: Dict(String, Type),
) {
  let succ_map =
    list.fold(blocks, dict.new(), fn(acc, block) {
      dict.insert(acc, block.label, successors(block.term))
    })
  let preds_map =
    list.fold(blocks, dict.new(), fn(acc, block) {
      list.fold(successors(block.term), acc, fn(acc2, succ) {
        let existing = case dict.get(acc2, succ) {
          Ok(found) -> found
          Error(_) -> []
        }
        dict.insert(acc2, succ, [block.label, ..existing])
      })
    })
  let use_def =
    list.fold(blocks, dict.new(), fn(acc, block) {
      dict.insert(acc, block.label, block_use_def(block, handles))
    })
  let live_in = compute_liveness(blocks, succ_map, use_def)
  let live_out =
    list.fold(blocks, dict.new(), fn(acc, block) {
      dict.insert(
        acc,
        block.label,
        successors_live(block.term, succ_map, live_in),
      )
    })

  let backward =
    list.fold(blocks, dict.new(), fn(acc, block) {
      let base_live = case dict.get(live_out, block.label) {
        Ok(found) -> found
        Error(_) -> dict.new()
      }
      let live = add_term_reads(base_live, block.term, handles)
      let reversed = list.reverse(block.ops)
      let #(pre, moved) =
        back_ops(
          reversed,
          list.length(block.ops) - 1,
          handles,
          live,
          dict.new(),
          dict.new(),
        )
      dict.insert(acc, block.label, #(pre, moved))
    })

  let entry = case list.first(blocks) {
    Ok(block) -> block.label
    Error(_) -> ""
  }
  let entry_owned =
    list.fold(params, dict.new(), fn(acc, param) {
      case dict.get(handles, param) {
        Ok(_) -> set_add(acc, param)
        Error(_) -> acc
      }
    })
  let defs_map =
    list.fold(dict.to_list(use_def), dict.new(), fn(acc, entry_pair) {
      let #(label, #(_use, defs)) = entry_pair
      dict.insert(acc, label, defs)
    })
  let moved_map =
    list.fold(dict.to_list(backward), dict.new(), fn(acc, entry_pair) {
      let #(label, #(_pre, moved)) = entry_pair
      dict.insert(acc, label, moved)
    })
  let owned_out_map =
    forward_owned(
      blocks,
      entry,
      entry_owned,
      all_handles(handles),
      preds_map,
      live_out,
      defs_map,
      moved_map,
      dict.new(),
      dict.new(),
      0,
    )

  list.map(blocks, fn(block) {
    let pre = case dict.get(backward, block.label) {
      Ok(#(found, _)) -> found
      Error(_) -> dict.new()
    }
    let owned_out = case dict.get(owned_out_map, block.label) {
      Ok(found) -> found
      Error(_) -> dict.new()
    }
    let live_out_block = case dict.get(live_out, block.label) {
      Ok(found) -> found
      Error(_) -> dict.new()
    }
    let dead =
      set_diff(
        set_diff(owned_out, live_out_block),
        transferred_set(block.term, handles),
      )
    let drops =
      list.filter_map(locals, fn(local) {
        let ir.Local(local_name, local_ty) = local
        case dict.get(dead, local_name) {
          Ok(_) -> Ok(ir.OpDrop(local_name, local_ty))
          Error(_) -> Error(Nil)
        }
      })
    let new_ops = insert_retains(block.ops, 0, pre, [])
    let new_ops = add_extract_retains(new_ops, handles)
    ir.Block(block.label, list.append(new_ops, drops), block.term)
  })
}

fn add_extract_retains(ops, handles) {
  list.flat_map(ops, fn(op) {
    case op {
      ir.OpField(dest, _, _, _, ty) -> extract_pair(op, dest, ty, handles)
      ir.OpTupleGet(dest, _, _, ty) -> extract_pair(op, dest, ty, handles)
      _ -> [op]
    }
  })
}

/// Extracting a handle field is a shallow copy: the new local needs its own
/// reference, otherwise dropping the container frees the payload under it.
fn extract_pair(op, dest, ty, handles) {
  case dict.get(handles, dest) {
    Ok(_) -> [op, ir.OpRetain(dest, ty)]
    Error(_) -> [op]
  }
}

fn successors(term: ir.Terminator) -> List(String) {
  case term {
    ir.Jmp(label) -> [label]
    ir.Branch(_, then, otherwise) -> [then, otherwise]
    ir.Ret(_) -> []
    ir.Unreachable -> []
  }
}

// ---------------------------------------------------------------------------
// liveness (backward, straight from Vesper's analyze/insert)
// ---------------------------------------------------------------------------

fn block_use_def(block: ir.Block, handles: Dict(String, Type)) {
  let #(used, defs) =
    list.fold(block.ops, #(dict.new(), dict.new()), fn(acc, op) {
      let #(use_acc, defs_acc) = acc
      let use_acc =
        list.fold(handle_names(ir.op_reads(op), handles), use_acc, fn(u, name) {
          case dict.get(defs_acc, name) {
            Ok(_) -> u
            Error(_) -> set_add(u, name)
          }
        })
      let defs_acc = case ir.op_dest(op) {
        Ok(dest_name) ->
          case dict.get(handles, dest_name) {
            Ok(_) -> set_add(defs_acc, dest_name)
            Error(_) -> defs_acc
          }
        Error(_) -> defs_acc
      }
      #(use_acc, defs_acc)
    })
  let used =
    list.fold(
      handle_names(ir.term_reads(block.term), handles),
      used,
      fn(u, name) {
        case dict.get(defs, name) {
          Ok(_) -> u
          Error(_) -> set_add(u, name)
        }
      },
    )
  #(used, defs)
}

fn compute_liveness(blocks: List(ir.Block), succ_map, use_def) {
  iterate_liveness(blocks, succ_map, use_def, dict.new(), 0)
}

fn iterate_liveness(
  blocks: List(ir.Block),
  succ_map,
  use_def,
  current,
  iteration,
) {
  case iteration > 200 {
    True -> current
    False -> {
      let #(next, changed) =
        list.fold(blocks, #(current, False), fn(acc, block) {
          let #(state, changed_so_far) = acc
          let out = successors_live(block.term, succ_map, state)
          let #(used, defs) = case dict.get(use_def, block.label) {
            Ok(found) -> found
            Error(_) -> #(dict.new(), dict.new())
          }
          let in_set = set_union(used, set_diff(out, defs))
          let previous = case dict.get(state, block.label) {
            Ok(found) -> found
            Error(_) -> dict.new()
          }
          #(
            dict.insert(state, block.label, in_set),
            changed_so_far || !sets_equal(previous, in_set),
          )
        })
      case changed {
        True -> iterate_liveness(blocks, succ_map, use_def, next, iteration + 1)
        False -> next
      }
    }
  }
}

fn successors_live(term: ir.Terminator, _succ_map, state) {
  list.fold(successors(term), dict.new(), fn(acc, succ) {
    let succ_live = case dict.get(state, succ) {
      Ok(found) -> found
      Error(_) -> dict.new()
    }
    set_union(acc, succ_live)
  })
}

fn add_term_reads(live, term: ir.Terminator, handles) {
  list.fold(handle_names(ir.term_reads(term), handles), live, set_add)
}

// ---------------------------------------------------------------------------
// backward op walk: retains + moved set
// ---------------------------------------------------------------------------

fn back_ops(reversed_ops, index, handles, live, pre, moved) {
  case reversed_ops {
    [] -> #(pre, moved)
    [op, ..rest] -> {
      let reads = handle_names(ir.op_reads(op), handles)
      let defs = case ir.op_dest(op) {
        Ok(dest_name) ->
          case dict.get(handles, dest_name) {
            Ok(_) -> [dest_name]
            Error(_) -> []
          }
        Error(_) -> []
      }
      let #(pre, moved) =
        list.fold(
          dict.to_list(owning_counts(ir.op_owning(op))),
          #(pre, moved),
          fn(acc, entry) {
            let #(pre_acc, moved_acc) = acc
            let #(var_name, count) = entry
            case dict.get(handles, var_name) {
              Error(_) -> acc
              Ok(var_ty) -> {
                let last =
                  !set_member(live, var_name) && !list.contains(defs, var_name)
                let retained = case last {
                  True -> count - 1
                  False -> count
                }
                #(
                  retain_n(pre_acc, index, var_name, var_ty, retained),
                  case last {
                    True -> set_add(moved_acc, var_name)
                    False -> moved_acc
                  },
                )
              }
            }
          },
        )
      let live = set_union(sets_from(reads), set_diff(live, sets_from(defs)))
      back_ops(rest, index - 1, handles, live, pre, moved)
    }
  }
}

fn owning_counts(owning) {
  list.fold(owning, dict.new(), fn(acc, operand) {
    case operand {
      ir.Var(name) ->
        dict.insert(acc, name, case dict.get(acc, name) {
          Ok(count) -> count + 1
          Error(_) -> 1
        })
      ir.Lit(_) -> acc
    }
  })
}

fn retain_n(pre, index, var_name, var_ty, count) {
  case count <= 0 {
    True -> pre
    False -> {
      let existing = case dict.get(pre, index) {
        Ok(found) -> found
        Error(_) -> []
      }
      let added =
        list.fold(replicate(count), [], fn(acc, _) {
          [ir.OpRetain(var_name, var_ty), ..acc]
        })
      dict.insert(pre, index, list.append(existing, added))
    }
  }
}

fn insert_retains(ops, index, pre, acc) {
  case ops {
    [] -> acc
    [op, ..rest] -> {
      let retains = case dict.get(pre, index) {
        Ok(found) -> found
        Error(_) -> []
      }
      // retains go BEFORE the op | the keeps lists in forward order
      let acc = list.append(acc, list.append(retains, [op]))
      insert_retains(rest, index + 1, pre, acc)
    }
  }
}

// ---------------------------------------------------------------------------
// forward ownership liveness (must-ownership)
// ---------------------------------------------------------------------------

fn forward_owned(
  blocks: List(ir.Block),
  entry,
  entry_owned,
  all,
  preds_map,
  live_out,
  defs_map,
  moved_map,
  owned_in,
  owned_out,
  iteration,
) {
  case iteration > 200 {
    True -> owned_out
    False -> {
      let #(next_in, next_out) =
        list.fold(blocks, #(dict.new(), dict.new()), fn(acc, block) {
          let #(in_map, out_map) = acc
          let in_set = case block.label == entry {
            True -> entry_owned
            False -> {
              let preds = case dict.get(preds_map, block.label) {
                Ok(found) -> found
                Error(_) -> []
              }
              list.fold(preds, all, fn(acc2, pred) {
                let pred_out = case dict.get(owned_out, pred) {
                  Ok(found) -> found
                  Error(_) -> all
                }
                let pred_live = case dict.get(live_out, pred) {
                  Ok(found) -> found
                  Error(_) -> dict.new()
                }
                set_intersect(acc2, set_intersect(pred_out, pred_live))
              })
            }
          }
          let defs = case dict.get(defs_map, block.label) {
            Ok(found) -> found
            Error(_) -> dict.new()
          }
          let moved = case dict.get(moved_map, block.label) {
            Ok(found) -> found
            Error(_) -> dict.new()
          }
          let out_set = set_diff(set_union(in_set, defs), moved)
          #(
            dict.insert(in_map, block.label, in_set),
            dict.insert(out_map, block.label, out_set),
          )
        })
      case
        !sets_equal_maps(next_in, owned_in)
        || !sets_equal_maps(next_out, owned_out)
      {
        True ->
          forward_owned(
            blocks,
            entry,
            entry_owned,
            all,
            preds_map,
            live_out,
            defs_map,
            moved_map,
            next_in,
            next_out,
            iteration + 1,
          )
        False -> next_out
      }
    }
  }
}

fn transferred_set(term: ir.Terminator, handles) {
  case term {
    ir.Ret(operand) -> sets_from(handle_names([operand], handles))
    _ -> dict.new()
  }
}

// ---------------------------------------------------------------------------
// set helpers (a set is a Dict(name, True))
// ---------------------------------------------------------------------------

fn set_add(set, name) {
  dict.insert(set, name, True)
}

fn set_member(set, name) {
  case dict.get(set, name) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn replicate(count: Int) -> List(Int) {
  replicate_loop(count, [])
}

fn replicate_loop(count, acc) {
  case count <= 0 {
    True -> acc
    False -> replicate_loop(count - 1, [0, ..acc])
  }
}

fn sets_from(names) {
  list.fold(names, dict.new(), set_add)
}

fn set_union(a, b) {
  list.fold(dict.keys(b), a, set_add)
}

fn set_diff(a, b) {
  list.fold(dict.keys(b), a, fn(acc, name) { dict.delete(acc, name) })
}

fn set_intersect(a, b) {
  list.fold(dict.keys(a), dict.new(), fn(acc, name) {
    case dict.get(b, name) {
      Ok(_) -> set_add(acc, name)
      Error(_) -> acc
    }
  })
}

fn sets_equal(a, b) {
  dict.size(a) == dict.size(b)
  && list.all(dict.keys(a), fn(name) {
    case dict.get(b, name) {
      Ok(_) -> True
      Error(_) -> False
    }
  })
}

fn sets_equal_maps(a, b) {
  dict.size(a) == dict.size(b)
  && list.all(dict.keys(a), fn(label) {
    let set_a = case dict.get(a, label) {
      Ok(found) -> found
      Error(_) -> dict.new()
    }
    let set_b = case dict.get(b, label) {
      Ok(found) -> found
      Error(_) -> dict.new()
    }
    sets_equal(set_a, set_b)
  })
}

fn all_handles(handles) {
  sets_from(dict.keys(handles))
}

fn handle_names(operands, handles) {
  list.filter_map(operands, fn(operand) {
    case operand {
      ir.Var(name) ->
        case dict.get(handles, name) {
          Ok(_) -> Ok(name)
          Error(_) -> Error(Nil)
        }
      ir.Lit(_) -> Error(Nil)
    }
  })
}
