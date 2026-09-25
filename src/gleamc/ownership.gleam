//// Ownership pass (M6): a direct port of Vesper's `ir_ownership.insert`.
////
//// Model: every handle local owns one reference. At an owning use the
//// argument is moved (if it is the last use) or retained (if still live);
//// ownership liveness then decides where each local dies, emitting a drop
//// at block exit. This is the deterministic refcount mechanism: no GC, and
//// the generated C shows every retain/release.

import gleam/dict.{type Dict}
import gleam/list
import gleam/string
import gleamc/ast.{
  type Type, TApp, TBool, TFloat, TFun, TInt, TNamed, TNil, TString, TTuple,
  TVar,
}
import gleamc/borrow
import gleamc/checker
import gleamc/ffi_modes
import gleamc/frame
import gleamc/ir
import gleamc/owned_clone

pub fn insert(
  module: ir.Module,
  ctors: Dict(String, checker.CtorInfo),
) -> ir.Module {
  let modes = borrow.analyze(module)
  // `type_fields`/`recursive_types` are module-wide; compute them once instead
  // of rebuilding them on every `needs_drop` call (once per local per function).
  let fields_of = type_fields(ctors)
  let recursive = recursive_types(ctors)
  // Tail/indirect call sites use the `Owned` ABI; give those functions an
  // all-`Owned` clone so ordinary calls keep the natural modes. Only handle
  // parameters make the distinction observable, so scalar-only functions are
  // left alone.
  let is_handle = fn(ty) { needs_drop_in(ty, fields_of, recursive) }
  let #(module, modes) = owned_clone.apply(module, modes, is_handle)
  let ir.Module(functions) = module
  let machines = frame.machine_functions(module)
  let ffi = ffi_modes.table()
  ir.Module(
    list.map(functions, fn(function) {
      let owned = insert_fn(function, fields_of, recursive, modes, ffi)
      case list.contains(machines, function.name) {
        True -> add_frame_lifecycle(owned)
        False -> owned
      }
    }),
  )
}

/// The frame is an ownership-managed value. A closure that captures it takes a
/// reference (`OpRetain`); the machine releases its own reference at every exit
/// (`OpDrop`). `OpFrameNew` (rendered by the backend) is the allocation.
fn add_frame_lifecycle(function: ir.Function) -> ir.Function {
  let ir.Function(name, params, ret, blocks, locals) = function
  let ty = TNamed(frame.frame_type_name(name))
  let blocks =
    list.map(blocks, fn(block) {
      let ir.Block(label, ops, term) = block
      let ops =
        list.flat_map(ops, fn(op) {
          case is_frame_capture_op(op) {
            True -> [ir.OpRetain(frame.frame_local, ty), op]
            False -> [op]
          }
        })
      let ops = case is_exit(term) {
        True -> list.append(ops, [ir.OpDrop(frame.frame_local, ty)])
        False -> ops
      }
      ir.Block(label, ops, term)
    })
  ir.Function(name, params, ret, blocks, locals)
}

fn is_frame_capture_op(op: ir.Op) -> Bool {
  case op {
    ir.OpClosure(_, _, _, env_ty, _) -> string.starts_with(env_ty, "__frame_")
    _ -> False
  }
}

fn is_exit(term: ir.Terminator) -> Bool {
  case term {
    ir.Ret(_) | ir.Tailcall(_, _) | ir.TailcallIndirect(_, _) -> True
    _ -> False
  }
}

// ---------------------------------------------------------------------------
// needs_drop
// ---------------------------------------------------------------------------

pub fn needs_drop(ty: Type, ctors: Dict(String, checker.CtorInfo)) -> Bool {
  let fields_of = type_fields(ctors)
  let recursive = recursive_types_from(fields_of)
  needs_drop_in(ty, fields_of, recursive)
}

/// Like `needs_drop`, but with `fields_of`/`recursive` precomputed by the
/// caller (avoiding an O(N) `type_fields` rebuild on every call).
pub fn needs_drop_in(ty: Type, fields_of, recursive) -> Bool {
  needs_drop_seen(ty, fields_of, recursive, [])
}

fn needs_drop_seen(ty, fields_of, recursive, seen) -> Bool {
  case ty {
    TString -> True
    TNamed("BitArray") -> True
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

fn insert_fn(function: ir.Function, fields_of, recursive, modes, ffi) -> ir.Function {
  let ir.Function(name, params, ret, blocks, locals) = function
  let handles =
    list.fold(locals, dict.new(), fn(acc, local) {
      let ir.Local(local_name, local_ty) = local
      case needs_drop_in(local_ty, fields_of, recursive) {
        True -> dict.insert(acc, local_name, local_ty)
        False -> acc
      }
    })
  // Partial ownership at a join cannot be resolved per block: a value may be
  // owned on one incoming edge (from its definition) and not on another. Split
  // critical edges so each edge has its own block, where the dead drop lands.
  let blocks = split_critical_edges(blocks)
  // Borrow-only field/tuple/env extractions *of a parameter* (or of another
  // such view) are references into the container, not owned values: they
  // carry no retain/drop. Mirrors Vesper's `FieldRef`.
  let borrow = borrow_only_uses(blocks, modes, ffi)
  let views = extraction_views(blocks, borrow, params)
  let handles =
    dict.filter(handles, fn(view_name, _) { !has_key(views, view_name) })
  case dict.is_empty(handles) {
    True -> function
    False -> {
      let param_modes = case dict.get(modes, name) {
        Ok(found) -> found
        Error(_) -> list.map(params, fn(_) { ffi_modes.Borrow })
      }
      ir.Function(
        name,
        params,
        ret,
        insert_blocks(
          blocks,
          params,
          locals,
          handles,
          modes,
          ffi,
          param_modes,
          views,
        ),
        locals,
      )
    }
  }
}

/// Inserts an empty block on every critical edge — a branch target that also
/// has another predecessor — so a value that dies only on that edge can be
/// dropped in the new block instead of leaking (or being dropped for a path
/// that never owned it).
fn split_critical_edges(blocks: List(ir.Block)) -> List(ir.Block) {
  let preds =
    list.fold(blocks, dict.new(), fn(acc, block) {
      list.fold(successors(block.term), acc, fn(acc, succ) {
        let count = case dict.get(acc, succ) {
          Ok(found) -> found
          Error(_) -> 0
        }
        dict.insert(acc, succ, count + 1)
      })
    })
  list.flat_map(blocks, fn(block) {
    case block.term {
      ir.Branch(cond, then, otherwise) -> {
        let #(then, then_blocks) = split_edge(block.label, "t", then, preds)
        let #(otherwise, else_blocks) =
          split_edge(block.label, "f", otherwise, preds)
        [
          ir.Block(block.label, block.ops, ir.Branch(cond, then, otherwise)),
          ..list.append(then_blocks, else_blocks),
        ]
      }
      _ -> [block]
    }
  })
}

fn split_edge(from: String, tag: String, target: String, preds) {
  let count = case dict.get(preds, target) {
    Ok(found) -> found
    Error(_) -> 0
  }
  case count > 1 {
    True -> {
      let label = from <> "_ce_" <> tag
      #(label, [ir.Block(label, [], ir.Jmp(target))])
    }
    False -> #(target, [])
  }
}

/// Reads of a view count as reads of its container (transitively), so the
/// container stays live while the view is used.
fn expand_names(names, views) -> List(ir.Operand) {
  list.fold(names, names, fn(acc, operand) {
    case operand {
      ir.Var(name) ->
        case dict.get(views, name) {
          Ok(container) ->
            list.append(acc, expand_names([ir.Var(container)], views))
          Error(_) -> acc
        }
      ir.Lit(_) -> acc
    }
  })
}

fn has_key(d, key) {
  case dict.get(d, key) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn set_add_var(set, operand) {
  case operand {
    ir.Var(name) -> dict.insert(set, name, True)
    ir.Lit(_) -> set
  }
}

/// Names whose every use is a borrow position (never moved/owned).
fn borrow_only_uses(blocks, modes, ffi) -> Dict(String, Bool) {
  let all =
    list.fold(blocks, dict.new(), fn(acc, block) {
      let ir.Block(_, ops, term) = block
      let acc =
        list.fold(ops, acc, fn(acc, op) {
          list.fold(ir.op_reads(op), acc, set_add_var)
        })
      list.fold(ir.term_reads(term), acc, set_add_var)
    })
  let owning =
    list.fold(blocks, dict.new(), fn(acc, block) {
      let ir.Block(_, ops, term) = block
      let acc =
        list.fold(ops, acc, fn(acc, op) {
          list.fold(ir.op_owning_modes(op, modes, ffi), acc, set_add_var)
        })
      list.fold(ir.term_reads(term), acc, set_add_var)
    })
  list.fold(dict.keys(all), dict.new(), fn(acc, name) {
    case set_member(owning, name) {
      True -> acc
      False -> dict.insert(acc, name, True)
    }
  })
}

/// Extraction dests that are borrow-only and whose container is a parameter
/// (or another such view): safe references. Views of owned temporaries are
/// left owning (their container may be released while the view is used).
fn extraction_views(blocks, borrow, params) -> Dict(String, String) {
  let param_set =
    list.fold(params, dict.new(), fn(acc, name) { dict.insert(acc, name, True) })
  list.fold(blocks, dict.new(), fn(acc, block) {
    let ir.Block(_, ops, _) = block
    list.fold(ops, acc, fn(acc, op) {
      let pair = case op {
        ir.OpField(dest, ir.Var(subject), _, _, _) -> #(dest, subject)
        ir.OpTupleGet(dest, ir.Var(subject), _, _) -> #(dest, subject)
        ir.OpEnvGet(dest, _, _, _) -> #(dest, "")
        // Reading a frame field is a borrowed view: the frame owns the value
        // (and outlives the read), exactly like an environment read.
        ir.OpFrameGet(dest, _, _, _) -> #(dest, "")
        _ -> #("", "")
      }
      let #(dest, subject) = pair
      case dest {
        "" -> acc
        _ ->
          case set_member(borrow, dest) {
            True ->
              case set_member(param_set, subject) || has_key(acc, subject) {
                True -> dict.insert(acc, dest, subject)
                False -> acc
              }
            False -> acc
          }
      }
    })
  })
}

fn insert_blocks(
  blocks: List(ir.Block),
  params: List(String),
  locals: List(ir.Local),
  handles: Dict(String, Type),
  modes,
  ffi,
  param_modes,
  views,
) {
  // Parameters this function does not own. Passing one to an owned target (a
  // tail or indirect call) is an ownership transfer, so the caller must retain
  // it first: unlike an owned local's last use, there is no existing reference
  // to hand over.
  let borrowed_params =
    list.index_map(params, fn(param, index) {
      #(param, ffi_modes.mode_at(param_modes, index))
    })
    |> list.fold(dict.new(), fn(acc, pair) {
      let #(param, mode) = pair
      case mode {
        ffi_modes.Borrow -> dict.insert(acc, param, True)
        ffi_modes.Owned -> acc
      }
    })
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
  // A `Suspend` defines its destination in the *resume* block (the value only
  // exists after the future completes), so the resume block owns the definition.
  let resume_defs =
    list.fold(blocks, dict.new(), fn(acc, block) {
      case block.term {
        ir.Suspend(_, dest, resume) -> dict.insert(acc, resume, dest)
        _ -> acc
      }
    })
  let use_def =
    list.fold(blocks, dict.new(), fn(acc, block) {
      let #(used, defs) = block_use_def(block, handles, views)
      let defs = case dict.get(resume_defs, block.label) {
        Ok(dest) ->
          case dict.get(handles, dest) {
            Ok(_) -> dict.insert(defs, dest, True)
            Error(_) -> defs
          }
        Error(_) -> defs
      }
      dict.insert(acc, block.label, #(used, defs))
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
      let live = add_term_reads(base_live, block.term, handles, views)
      let reversed = list.reverse(block.ops)
      let #(pre, moved) =
        back_ops(
          reversed,
          list.length(block.ops) - 1,
          handles,
          live,
          dict.new(),
          dict.new(),
          modes,
          ffi,
          views,
        )
      let #(pre, moved) = case block.term {
        ir.Tailcall(fun, args) ->
          term_retains(
            fun,
            args,
            list.length(block.ops),
            handles,
            base_live,
            pre,
            moved,
            modes,
            ffi,
            borrowed_params,
          )
        // The callee is unknown, so every argument is treated as owning.
        ir.TailcallIndirect(_, args) ->
          term_retains_owning(
            args,
            list.length(block.ops),
            handles,
            base_live,
            pre,
            moved,
            borrowed_params,
          )
        _ -> #(pre, moved)
      }
      dict.insert(acc, block.label, #(pre, moved))
    })

  let entry = case list.first(blocks) {
    Ok(block) -> block.label
    Error(_) -> ""
  }
  let entry_owned =
    list.index_map(params, fn(param, index) {
      #(param, ffi_modes.mode_at(param_modes, index))
    })
    |> list.fold(dict.new(), fn(acc, pair) {
      let #(param, mode) = pair
      case mode {
        ffi_modes.Owned ->
          case dict.get(handles, param) {
            Ok(_) -> set_add(acc, param)
            Error(_) -> acc
          }
        ffi_modes.Borrow -> acc
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
        transferred_set(block.term, handles, modes, ffi),
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
      ir.OpEnvGet(dest, _, _, ty) -> extract_pair(op, dest, ty, handles)
      ir.OpFrameGet(dest, _, _, ty) -> extract_pair(op, dest, ty, handles)
      _ -> [op]
    }
  })
}

/// Owning extraction needs its own reference; borrow-only views were removed
/// from `handles`, so they are not retained here.
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
    ir.Tailcall(_, _) -> []
    ir.TailcallIndirect(_, _) -> []
    ir.Suspend(_, _, resume) -> [resume]
    ir.Unreachable -> []
  }
}

// ---------------------------------------------------------------------------
// liveness (backward, straight from Vesper's analyze/insert)
// ---------------------------------------------------------------------------

fn block_use_def(block: ir.Block, handles: Dict(String, Type), views) {
  let #(used, defs) =
    list.fold(block.ops, #(dict.new(), dict.new()), fn(acc, op) {
      let #(use_acc, defs_acc) = acc
      let use_acc =
        list.fold(
          handle_names(expand_names(ir.op_reads(op), views), handles),
          use_acc,
          fn(u, name) {
            case dict.get(defs_acc, name) {
              Ok(_) -> u
              Error(_) -> set_add(u, name)
            }
          },
        )
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
      handle_names(expand_names(ir.term_reads(block.term), views), handles),
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

fn compute_liveness(
  blocks: List(ir.Block),
  succ_map: Dict(String, List(String)),
  use_def: Dict(String, #(Dict(String, Bool), Dict(String, Bool))),
) -> Dict(String, Dict(String, Bool)) {
  let preds_map = build_preds(succ_map)
  let queue = list.map(blocks, fn(block) { block.label })
  live_loop(queue, succ_map, preds_map, use_def, dict.new())
}

fn build_preds(succ_map: Dict(String, List(String))) -> Dict(String, List(String)) {
  dict.fold(succ_map, dict.new(), fn(acc, label, succs) {
    list.fold(succs, acc, fn(acc, succ) {
      let existing = case dict.get(acc, succ) {
        Ok(found) -> found
        Error(_) -> []
      }
      dict.insert(acc, succ, [label, ..existing])
    })
  })
}

/// Backward liveness worklist: a block is revisited only when one of its
/// successors changed, so the whole pass is O(edges * handles), not O(blocks)
/// per sweep with a fixed iteration cap.
fn live_loop(queue, succ_map, preds_map, use_def, live_in) {
  case queue {
    [] -> live_in
    [label, ..rest] -> {
      let out = case dict.get(succ_map, label) {
        Ok(succs) ->
          list.fold(succs, dict.new(), fn(acc, succ) {
            set_union(acc, case dict.get(live_in, succ) {
              Ok(found) -> found
              Error(_) -> dict.new()
            })
          })
        Error(_) -> dict.new()
      }
      let #(used, defs) = case dict.get(use_def, label) {
        Ok(found) -> found
        Error(_) -> #(dict.new(), dict.new())
      }
      let in_set = set_union(used, set_diff(out, defs))
      let previous = case dict.get(live_in, label) {
        Ok(found) -> found
        Error(_) -> dict.new()
      }
      case sets_equal(previous, in_set) {
        True -> live_loop(rest, succ_map, preds_map, use_def, live_in)
        False -> {
          let live_in = dict.insert(live_in, label, in_set)
          let preds = case dict.get(preds_map, label) {
            Ok(found) -> found
            Error(_) -> []
          }
          live_loop(list.append(preds, rest), succ_map, preds_map, use_def, live_in)
        }
      }
    }
  }
}


fn successors_live(
  term: ir.Terminator,
  _succ_map: Dict(String, List(String)),
  state: Dict(String, Dict(String, Bool)),
) -> Dict(String, Bool) {
  list.fold(successors(term), dict.new(), fn(acc, succ) {
    let succ_live = case dict.get(state, succ) {
      Ok(found) -> found
      Error(_) -> dict.new()
    }
    set_union(acc, succ_live)
  })
}

fn add_term_reads(live, term: ir.Terminator, handles, views) {
  list.fold(
    handle_names(expand_names(ir.term_reads(term), views), handles),
    live,
    set_add,
  )
}

// ---------------------------------------------------------------------------
// backward op walk: retains + moved set
// ---------------------------------------------------------------------------

fn back_ops(reversed_ops, index, handles, live, pre, moved, modes, ffi, views) {
  case reversed_ops {
    [] -> #(pre, moved)
    [op, ..rest] -> {
      let reads = handle_names(expand_names(ir.op_reads(op), views), handles)
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
          dict.to_list(owning_counts(ir.op_owning_modes(op, modes, ffi))),
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
      back_ops(rest, index - 1, handles, live, pre, moved, modes, ffi, views)
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
  // `acc` is the reverse of the output produced so far, so appending to the
  // end of the result is O(1) (per element) instead of O(n) per op.
  case ops {
    [] -> {
      let trailing = case dict.get(pre, index) {
        Ok(found) -> found
        Error(_) -> []
      }
      list.reverse(list.append(list.reverse(trailing), acc))
    }
    [op, ..rest] -> {
      let retains = case dict.get(pre, index) {
        Ok(found) -> found
        Error(_) -> []
      }
      // final order is `retains ++ [op]`, so reversed it is `[op] ++ rev(retains)`.
      let acc = list.append([op], list.append(list.reverse(retains), acc))
      insert_retains(rest, index + 1, pre, acc)
    }
  }
}

// ---------------------------------------------------------------------------
// forward ownership liveness (must-ownership)
// ---------------------------------------------------------------------------

fn forward_owned(
  blocks: List(ir.Block),
  entry: String,
  entry_owned: Dict(String, Bool),
  all: Dict(String, Bool),
  preds_map: Dict(String, List(String)),
  live_out: Dict(String, Dict(String, Bool)),
  defs_map: Dict(String, Dict(String, Bool)),
  moved_map: Dict(String, Dict(String, Bool)),
) -> Dict(String, Dict(String, Bool)) {
  let succ_map =
    list.fold(blocks, dict.new(), fn(acc, block) {
      dict.insert(acc, block.label, successors(block.term))
    })
  let out_map =
    list.fold(blocks, dict.new(), fn(acc, block) {
      dict.insert(acc, block.label, all)
    })
  let queue = list.map(blocks, fn(block) { block.label })
  forward_loop(
    queue,
    succ_map,
    entry,
    entry_owned,
    all,
    preds_map,
    live_out,
    defs_map,
    moved_map,
    out_map,
  )
}

fn forward_loop(
  queue,
  succ_map,
  entry,
  entry_owned,
  all,
  preds_map,
  live_out,
  defs_map,
  moved_map,
  out_map,
) {
  case queue {
    [] -> out_map
    [label, ..rest] -> {
      let in_set = case label == entry {
        True -> entry_owned
        False -> {
          let preds = case dict.get(preds_map, label) {
            Ok(found) -> found
            Error(_) -> []
          }
          list.fold(preds, all, fn(acc, pred) {
            let pred_out = case dict.get(out_map, pred) {
              Ok(found) -> found
              Error(_) -> all
            }
            let pred_live = case dict.get(live_out, pred) {
              Ok(found) -> found
              Error(_) -> dict.new()
            }
            set_intersect(acc, set_intersect(pred_out, pred_live))
          })
        }
      }
      let defs = case dict.get(defs_map, label) {
        Ok(found) -> found
        Error(_) -> dict.new()
      }
      let moved = case dict.get(moved_map, label) {
        Ok(found) -> found
        Error(_) -> dict.new()
      }
      let out = set_diff(set_union(in_set, defs), moved)
      let previous = case dict.get(out_map, label) {
        Ok(found) -> found
        Error(_) -> all
      }
      case sets_equal(previous, out) {
        True ->
          forward_loop(
            rest,
            succ_map,
            entry,
            entry_owned,
            all,
            preds_map,
            live_out,
            defs_map,
            moved_map,
            out_map,
          )
        False -> {
          let out_map = dict.insert(out_map, label, out)
          let succs = case dict.get(succ_map, label) {
            Ok(found) -> found
            Error(_) -> []
          }
          forward_loop(
            list.append(succs, rest),
            succ_map,
            entry,
            entry_owned,
            all,
            preds_map,
            live_out,
            defs_map,
            moved_map,
            out_map,
          )
        }
      }
    }
  }
}
fn term_retains(
  fun,
  args,
  index,
  handles,
  base_live,
  pre,
  moved,
  modes,
  ffi,
  borrowed_params,
) {
  let owning = ir.tailcall_owning_modes(fun, args, modes, ffi)
  term_retains_owning(
    owning,
    index,
    handles,
    base_live,
    pre,
    moved,
    borrowed_params,
  )
}

fn term_retains_owning(
  owning,
  index,
  handles,
  base_live,
  pre,
  moved,
  borrowed_params,
) {
  list.fold(dict.to_list(owning_counts(owning)), #(pre, moved), fn(acc, entry) {
    let #(pre_acc, moved_acc) = acc
    let #(var_name, count) = entry
    case dict.get(handles, var_name) {
      Error(_) -> acc
      Ok(var_ty) -> {
        let last = !set_member(base_live, var_name)
        // A borrowed parameter has no reference to hand over, so the transfer
        // needs `count` new retains even on its last use; an owned local's last
        // use already carries one reference, hence `count - 1`.
        let borrowed = set_member(borrowed_params, var_name)
        let retained = case last, borrowed {
          True, True -> count
          True, False -> count - 1
          False, _ -> count
        }
        let moved = case last, borrowed {
          True, False -> set_add(moved_acc, var_name)
          _, _ -> moved_acc
        }
        #(retain_n(pre_acc, index, var_name, var_ty, retained), moved)
      }
    }
  })
}

fn transferred_set(term: ir.Terminator, handles, modes, ffi) {
  case term {
    ir.Ret(operand) -> sets_from(handle_names([operand], handles))
    ir.Tailcall(fun, args) ->
      sets_from(handle_names(
        ir.tailcall_owning_modes(fun, args, modes, ffi),
        handles,
      ))
    // The target state receives the closure's environment (the frame), not the
    // function value itself, so the function value is released by its owner.
    ir.TailcallIndirect(_, args) ->
      sets_from(handle_names(args, handles))
    // The pending future is handed to the driver and released by the machine on
    // resume, so the flow does not drop it at the suspension.
    ir.Suspend(fut, _, _) -> sets_from(handle_names([fut], handles))
    _ -> dict.new()
  }
}

// ---------------------------------------------------------------------------
// set helpers (a set is a Dict(name, True))
// ---------------------------------------------------------------------------

fn set_add(set: Dict(String, Bool), name: String) -> Dict(String, Bool) {
  dict.insert(set, name, True)
}

fn set_member(set: Dict(String, Bool), name: String) -> Bool {
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

fn sets_from(names: List(String)) -> Dict(String, Bool) {
  list.fold(names, dict.new(), set_add)
}

fn set_union(
  a: Dict(String, Bool),
  b: Dict(String, Bool),
) -> Dict(String, Bool) {
  list.fold(dict.keys(b), a, set_add)
}

fn set_diff(
  a: Dict(String, Bool),
  b: Dict(String, Bool),
) -> Dict(String, Bool) {
  list.fold(dict.keys(b), a, fn(acc, name) { dict.delete(acc, name) })
}

fn set_intersect(
  a: Dict(String, Bool),
  b: Dict(String, Bool),
) -> Dict(String, Bool) {
  list.fold(dict.keys(a), dict.new(), fn(acc, name) {
    case dict.get(b, name) {
      Ok(_) -> set_add(acc, name)
      Error(_) -> acc
    }
  })
}

fn sets_equal(a: Dict(String, Bool), b: Dict(String, Bool)) -> Bool {
  dict.size(a) == dict.size(b)
  && list.all(dict.keys(a), fn(name) {
    case dict.get(b, name) {
      Ok(_) -> True
      Error(_) -> False
    }
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
