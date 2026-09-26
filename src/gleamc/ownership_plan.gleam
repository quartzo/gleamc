//// Ownership analysis (M6): computes, for one function, the refcount plan that
//// the `ownership` pass applies.
////
//// This module never mutates the IR: it returns a `Plan` of retain/drop/move
//// decisions, so the hard part (liveness, moves, extraction move-out) is
//// testable in isolation and the applier only inserts the ops.
////
//// Model: every handle local owns one reference. At an owning use the argument
//// is moved (if it is the last use) or retained (if still live); ownership
//// liveness then decides where each local dies, emitting a drop at block exit.

import gleam/dict.{type Dict}
import gleam/list
import gleamc/ast.{
  type Type, TApp, TBool, TFloat, TFun, TInt, TNamed, TNil, TString, TTuple,
  TVar, buffer_elem_name,
}
import gleamc/checker
import gleamc/ffi_modes
import gleamc/ir

/// The refcount plan for one function: the filtered handle locals and, per
/// block, the retains to insert (keyed by op index), the extraction dests that
/// move out of a consumed container, and the locals to drop.
pub type Plan {
  Plan(
    handles: Dict(String, Type),
    blocks: Dict(String, BlockPlan),
  )
}

pub type BlockPlan {
  BlockPlan(
    retains: Dict(Int, List(#(String, Type))),
    moved_dests: Dict(String, Bool),
    drops: List(#(String, Type)),
  )
}

/// Compute the plan for a (critical-edge-split) function body. `Error(Nil)`
/// means the function has no handle locals, so the applier leaves it untouched.
pub fn compute(
  blocks: List(ir.Block),
  params: List(String),
  locals: List(ir.Local),
  param_modes,
  fields_of,
  recursive,
  variant_count,
  modes,
  ffi,
) -> Result(Plan, Nil) {
  let handles =
    list.fold(locals, dict.new(), fn(acc, local) {
      let ir.Local(local_name, local_ty) = local
      case needs_drop_in(local_ty, fields_of, recursive) {
        True -> dict.insert(acc, local_name, local_ty)
        False -> acc
      }
    })
  // Borrow-only field/tuple/env extractions *of a parameter* (or of another
  // such view) are references into the container, not owned values: they
  // carry no retain/drop. Mirrors Vesper's `FieldRef`.
  let borrow_uses = borrow_only_uses(blocks, modes, ffi)
  let views = extraction_views(blocks, borrow_uses, params)
  let handles =
    dict.filter(handles, fn(view_name, _) { !has_key(views, view_name) })
  case dict.is_empty(handles) {
    True -> Error(Nil)
    False -> {
      // Parameters this function does not own. Passing one to an owned target
      // (a tail or indirect call) is an ownership transfer, so the caller must
      // retain it first: unlike an owned local's last use, there is no existing
      // reference to hand over.
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
      // A `Suspend` defines its destination in the *resume* block (the value
      // only exists after the future completes), so the resume block owns the
      // definition.
      let resume_defs =
        list.fold(blocks, dict.new(), fn(acc, block) {
          case block.term {
            ir.Suspend(_, dest, resume, _) -> dict.insert(acc, resume, dest)
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
      // An owned parameter was transferred by the caller, so it is a root
      // owner like a fresh temporary and its fields may be moved out.
      let owned_params =
        list.index_map(params, fn(param, index) {
          #(param, ffi_modes.mode_at(param_modes, index))
        })
        |> list.fold(dict.new(), fn(acc, pair) {
          let #(param, mode) = pair
          case mode {
            ffi_modes.Owned -> dict.insert(acc, param, True)
            ffi_modes.Borrow -> acc
          }
        })
      // A container that is a pure, root-owned value: a fresh temporary or an
      // owned parameter, not extracted from another aggregate, and read only by
      // field/tuple extractions.
      let pure_subjects =
        pure_extraction_subjects(blocks, handles, params, owned_params)

      let block_plans =
        list.fold(blocks, dict.new(), fn(acc, block) {
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
          let #(moved_dests, elided_subjects) =
            full_destructure_moves(
              block,
              dead,
              handles,
              fields_of,
              recursive,
              variant_count,
              pure_subjects,
            )
          let drops =
            list.filter_map(locals, fn(local) {
              let ir.Local(local_name, local_ty) = local
              case dict.get(dead, local_name) {
                Ok(_) ->
                  case dict.get(elided_subjects, local_name) {
                    Ok(_) -> Error(Nil)
                    Error(_) -> Ok(#(local_name, local_ty))
                  }
                Error(_) -> Error(Nil)
              }
            })
          dict.insert(acc, block.label, BlockPlan(pre, moved_dests, drops))
        })
      Ok(Plan(handles, block_plans))
    }
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
    // `Buffer(a)` is a refcounted cell that must be released even when its
    // element type is trivial (e.g. `Buffer(Int)`).
    TApp("Buffer", _) -> True
    TApp(_, args) ->
      list.any(args, fn(inner) {
        needs_drop_seen(inner, fields_of, recursive, seen)
      })
    TNamed(name) ->
      case buffer_elem_name(name) {
        // A monomorphised `Buffer(a)` (`TNamed("Buffer_<elem>")`).
        Ok(_) -> True
        Error(_) ->
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
                        needs_drop_seen(
                          inner,
                          fields_of,
                          recursive,
                          [name, ..seen],
                        )
                      })
                  }
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
// borrow-only views
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// extraction move-out
// ---------------------------------------------------------------------------

/// A handle local eligible for the extraction move-out: a root-owned value
/// (a fresh temporary, or an owned parameter), not itself extracted from
/// another aggregate (a nested value), and read only by field/tuple
/// extractions.
fn pure_extraction_subjects(
  blocks,
  handles: Dict(String, Type),
  params,
  owned_params,
) {
  let param_set =
    list.fold(params, dict.new(), fn(acc, param) {
      dict.insert(acc, param, True)
    })
  let impure =
    list.fold(blocks, dict.new(), fn(acc, block) {
      let ir.Block(_, ops, term) = block
      let acc =
        list.fold(ops, acc, fn(acc, op) {
          case op {
            ir.OpField(_, ir.Var(_), _, _, _) -> acc
            ir.OpTupleGet(_, ir.Var(_), _, _) -> acc
            _ -> list.fold(ir.op_reads(op), acc, set_add_var)
          }
        })
      list.fold(ir.term_reads(term), acc, set_add_var)
    })
  let extraction_dests =
    list.fold(blocks, dict.new(), fn(acc, block) {
      let ir.Block(_, ops, _) = block
      list.fold(ops, acc, fn(acc, op) {
        case op {
          ir.OpField(dest, _, _, _, _) -> dict.insert(acc, dest, True)
          ir.OpTupleGet(dest, _, _, _) -> dict.insert(acc, dest, True)
          ir.OpEnvGet(dest, _, _, _) -> dict.insert(acc, dest, True)
          ir.OpFrameGet(dest, _, _, _) -> dict.insert(acc, dest, True)
          _ -> acc
        }
      })
    })
  list.fold(dict.keys(handles), dict.new(), fn(acc, name) {
    case
      dict.has_key(param_set, name) && !has_key(owned_params, name)
      || dict.has_key(impure, name)
      || dict.has_key(extraction_dests, name)
    {
      True -> acc
      False -> dict.insert(acc, name, True)
    }
  })
}

/// Destructuring a dead single-variant container whose owned fields are all
/// extracted moves the fields out of the container instead of duplicating them
/// (no `OpRetain` on the extraction) and leaves the container with nothing to
/// drop. Returns `#(moved dests, elided subjects)`.
fn full_destructure_moves(
  block: ir.Block,
  dead,
  handles: Dict(String, Type),
  fields_of,
  recursive,
  variant_count,
  pure_subjects,
) {
  let ir.Block(_, ops, _) = block
  // A field read by more than one owning extraction cannot be moved: both
  // dests would alias the container's single reference, so `repeated` marks
  // those subjects as ineligible.
  let #(owning, repeated) =
    list.fold(ops, #(dict.new(), dict.new()), fn(acc, op) {
      let #(owning, repeated) = acc
      case op {
        ir.OpField(dest, ir.Var(subject), _, index, _) ->
          add_owning_extract(owning, repeated, subject, dest, index, handles)
        ir.OpTupleGet(dest, ir.Var(subject), index, _) ->
          add_owning_extract(owning, repeated, subject, dest, index, handles)
        _ -> acc
      }
    })
  let all_dests =
    list.fold(ops, dict.new(), fn(acc, op) {
      let existing = fn(subject) {
        case dict.get(acc, subject) {
          Ok(found) -> found
          Error(_) -> []
        }
      }
      case op {
        ir.OpField(dest, ir.Var(subject), _, _, _) ->
          dict.insert(acc, subject, [dest, ..existing(subject)])
        ir.OpTupleGet(dest, ir.Var(subject), _, _) ->
          dict.insert(acc, subject, [dest, ..existing(subject)])
        _ -> acc
      }
    })
  list.fold(dict.to_list(owning), #(dict.new(), dict.new()), fn(acc, entry) {
    let #(moved, elided) = acc
    let #(subject, indices) = entry
    case dict.get(dead, subject), dict.get(repeated, subject) {
      Ok(_), Error(_) ->
        case dict.get(pure_subjects, subject) {
          Error(_) -> acc
          Ok(_) ->
            case dict.get(handles, subject) {
              Error(_) -> acc
              Ok(subject_ty) ->
                case owned_field_indices(
                  subject_ty,
                  fields_of,
                  recursive,
                  variant_count,
                ) {
                  Error(_) -> acc
                  Ok(owned) ->
                    case indices_covered(owned, indices) {
                      False -> acc
                      True -> {
                        let dests = case dict.get(all_dests, subject) {
                          Ok(found) -> found
                          Error(_) -> []
                        }
                        let moved =
                          list.fold(dests, moved, fn(acc, dest) {
                            dict.insert(acc, dest, True)
                          })
                        #(moved, dict.insert(elided, subject, True))
                      }
                    }
                }
            }
        }
      _, _ -> acc
    }
  })
}

fn add_owning_extract(owning, repeated, subject, dest, index, handles) {
  case dict.get(handles, dest) {
    Ok(_) -> {
      let existing = case dict.get(owning, subject) {
        Ok(found) -> found
        Error(_) -> dict.new()
      }
      let repeated = case dict.has_key(existing, index) {
        True -> dict.insert(repeated, subject, True)
        False -> repeated
      }
      #(dict.insert(owning, subject, dict.insert(existing, index, True)), repeated)
    }
    Error(_) -> #(owning, repeated)
  }
}

/// The field indices of a single-variant container that own a reference (need
/// dropping). Multi-variant and non-struct containers are not eligible.
fn owned_field_indices(ty: Type, fields_of, recursive, variant_count) {
  let fields = case ty {
    TNamed(name) ->
      case dict.get(variant_count, name) {
        Ok(1) ->
          case dict.get(fields_of, name) {
            Ok(fs) -> Ok(fs)
            Error(_) -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
  case fields {
    Error(_) -> Error(Nil)
    Ok(fs) ->
      Ok(
        list.filter_map(
          list.index_map(fs, fn(field_ty, index) { #(field_ty, index) }),
          fn(pair) {
            let #(field_ty, index) = pair
            case needs_drop_in(field_ty, fields_of, recursive) {
              True -> Ok(index)
              False -> Error(Nil)
            }
          },
        ),
      )
  }
}

fn indices_covered(owned: List(Int), indices) -> Bool {
  list.all(owned, fn(index) { dict.has_key(indices, index) })
}

// ---------------------------------------------------------------------------
// liveness (backward, straight from Vesper's analyze/insert)
// ---------------------------------------------------------------------------

pub fn successors(term: ir.Terminator) -> List(String) {
  case term {
    ir.Jmp(label) -> [label]
    ir.Branch(_, then, otherwise) -> [then, otherwise]
    ir.Ret(_) -> []
    ir.Tailcall(_, _) -> []
    ir.TailcallIndirect(_, _) -> []
    ir.TailMachine(_, _) -> []
    ir.Suspend(_, _, resume, _) -> [resume]
    ir.Unreachable -> []
  }
}

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
  set_union(live, read_set(ir.term_reads(term), handles, views))
}

/// The handle names read by `operands`, as a set, without building the
/// intermediate lists `expand_names`/`handle_names` would allocate.
fn read_set(operands, handles, views) -> Dict(String, Bool) {
  list.fold(operands, dict.new(), fn(acc, operand) {
    add_read(acc, operand, handles, views)
  })
}

fn add_read(acc, operand, handles, views) {
  case operand {
    ir.Var(name) ->
      case dict.has_key(handles, name) {
        True -> dict.insert(acc, name, True)
        False ->
          case dict.get(views, name) {
            Ok(container) -> add_read(acc, ir.Var(container), handles, views)
            Error(_) -> acc
          }
      }
    ir.Lit(_) -> acc
  }
}

// ---------------------------------------------------------------------------
// backward op walk: retains + moved set
// ---------------------------------------------------------------------------

fn back_ops(reversed_ops, index, handles, live, pre, moved, modes, ffi, views) {
  case reversed_ops {
    [] -> #(pre, moved)
    [op, ..rest] -> {
      let reads = read_set(ir.op_reads(op), handles, views)
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
      let live = set_union(reads, set_diff(live, sets_from(defs)))
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
          [#(var_name, var_ty), ..acc]
        })
      dict.insert(pre, index, list.append(existing, added))
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
    // The delegated callee receives the owned arguments (the backend retains
    // them); the flow must not drop them here.
    ir.TailMachine(fun, args) ->
      sets_from(handle_names(
        ir.tailcall_owning_modes(fun, args, modes, ffi),
        handles,
      ))
    // The pending future is handed to the driver and released by the machine on
    // resume, so the flow does not drop it at the suspension.
    ir.Suspend(fut, _, _, _) -> sets_from(handle_names([fut], handles))
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

// Sets are `Dict(String, Bool)`. These fold the dictionary directly instead of
// `dict.keys`, which would allocate a list on every liveness iteration.
fn set_union(
  a: Dict(String, Bool),
  b: Dict(String, Bool),
) -> Dict(String, Bool) {
  dict.fold(b, a, fn(acc, name, _) { set_add(acc, name) })
}

fn set_diff(
  a: Dict(String, Bool),
  b: Dict(String, Bool),
) -> Dict(String, Bool) {
  dict.fold(b, a, fn(acc, name, _) { dict.delete(acc, name) })
}

fn set_intersect(
  a: Dict(String, Bool),
  b: Dict(String, Bool),
) -> Dict(String, Bool) {
  dict.fold(a, dict.new(), fn(acc, name, _) {
    case dict.has_key(b, name) {
      True -> set_add(acc, name)
      False -> acc
    }
  })
}

fn sets_equal(a: Dict(String, Bool), b: Dict(String, Bool)) -> Bool {
  dict.size(a) == dict.size(b)
  && dict.fold(a, True, fn(acc, name, _) { acc && dict.has_key(b, name) })
}

fn all_handles(handles) {
  dict.fold(handles, dict.new(), fn(acc, name, _) { set_add(acc, name) })
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
