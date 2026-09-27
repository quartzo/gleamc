//// SSA promotion: mark the locals that can live in an SSA register
//// (`ir.Reg`) instead of a memory slot (`ir.Slot`), so the backend skips their
//// entry `alloca` and their `load`/`store`.
////
//// Only *plain* functions are promoted. A machine / frame function keeps every
//// local in its heap frame (the frame is its closure environment and the async
//// state), so it is left untouched.
////
//// Two locals shapes are promoted:
////
//// - a single-definition local whose definition dominates every use and is
////   always rendered as a value (not an sret call, `buffer.take` or a
////   `FileResult` builtin, whose result the backend writes through the
////   destination's address);
//// - the `case` result temporaries: a local written by one `OpCopy` per arm,
////   where every arm jumps to the same join block. Those become an `OpPhi` at
////   the join, replacing the shared slot.
////
//// Unreachable blocks (e.g. the fail block of an exhaustive `case`) are pruned
//// first: they can carry drops of values that no definition dominates, which
//// would otherwise force those values into slots.

import gleam/dict.{type Dict}
import gleam/list
import gleam/string
import gleamc/abi
import gleamc/frame
import gleamc/ir

pub fn promote(module: ir.Module, recursive: Dict(String, Bool)) -> ir.Module {
  let machines = frame.machine_functions(module) |> list_to_dict
  let ir.Module(functions) = module
  ir.Module(
    list.map(functions, fn(function) {
      case dict.has_key(machines, function.name) {
        True -> function
        False -> promote_function(function, recursive)
      }
    }),
  )
}

fn promote_function(
  function: ir.Function,
  recursive: Dict(String, Bool),
) -> ir.Function {
  let ir.Function(name, params, ret, blocks, locals) = function
  let blocks = prune_unreachable(blocks)
  let #(defs, uses) = collect_defs_and_uses(blocks)
  let dom = dominators(blocks)
  let terms = block_terms(blocks)
  let preds = predecessors(blocks)
  let params_set = list_to_dict(params)
  let result_dests = machine_result_dests(blocks)
  let forbidden = list_to_dict([frame.frame_local, "__env"])
  // `case` result temporaries: every definition is an `OpCopy`, every def block
  // jumps to the same join, that join's only predecessors are the def blocks,
  // and the join dominates every use.
  let raw_phi_plans =
    dict.fold(defs, dict.new(), fn(acc, local_name, local_defs) {
      case
        dict.has_key(forbidden, local_name)
        || dict.has_key(result_dests, local_name)
      {
        True -> acc
        False ->
          case phi_candidate(local_defs, terms, preds) {
            Error(_) -> acc
            Ok(#(join, incoming)) ->
              case dominates_all(dom, join, uses_of(uses, local_name)) {
                True -> dict.insert(acc, local_name, #(join, incoming))
                False -> acc
              }
          }
      }
    })
  // A phi operand is read in the join block. A promoted local is a register and
  // can be read there; a slotted operand would need a `load`, which cannot sit
  // after the `phi`s. Keep only plans whose incoming values are already values,
  // iterating so a plan that depends on a dropped plan is dropped too.
  let base_reg =
    list.fold(locals, dict.new(), fn(acc, local) {
      let ir.Local(local_name, _, _) = local
      case dict.has_key(raw_phi_plans, local_name) {
        True -> acc
        False ->
          case
            classify(
              local_name,
              defs,
              uses,
              dom,
              params_set,
              result_dests,
              forbidden,
              recursive,
            )
          {
            ir.Reg -> dict.insert(acc, local_name, True)
            ir.Slot -> acc
          }
      }
    })
  let phi_plans = shrink_phi_plans(raw_phi_plans, base_reg)
  let locals =
    list.map(locals, fn(local) {
      let ir.Local(local_name, ty, _) = local
      let storage = case dict.has_key(phi_plans, local_name) {
        True -> ir.Reg
        False ->
          classify(
            local_name,
            defs,
            uses,
            dom,
            params_set,
            result_dests,
            forbidden,
            recursive,
          )
      }
      ir.Local(local_name, ty, storage)
    })
  let phis = phi_ops(phi_plans)
  let blocks = rewrite_blocks(blocks, phi_plans, phis)
  ir.Function(name, params, ret, blocks, locals)
}

/// Keep only the phi plans whose incoming operands are literals or registers.
/// A plan that reads a local only available through another phi depends on it,
/// so dropping one can drop another; iterate to a fixpoint.
fn shrink_phi_plans(plans, base_reg) {
  let next =
    dict.filter(plans, fn(_dest, plan) {
      let #(_, incoming) = plan
      list.all(incoming, fn(entry) {
        let #(operand, _) = entry
        case operand {
          ir.Lit(_) -> True
          ir.Var(name) ->
            dict.has_key(base_reg, name) || dict.has_key(plans, name)
        }
      })
    })
  case dict.size(next) == dict.size(plans) {
    True -> next
    False -> shrink_phi_plans(next, base_reg)
  }
}

fn uses_of(uses, name) {
  case dict.get(uses, name) {
    Ok(labels) -> labels
    Error(_) -> []
  }
}

fn classify(
  name,
  defs,
  uses,
  dom,
  params,
  result_dests,
  forbidden,
  recursive,
) -> ir.Storage {
  case dict.has_key(forbidden, name) || dict.has_key(result_dests, name) {
    True -> ir.Slot
    False ->
      case dict.has_key(params, name) {
        // A parameter is defined by the ABI, so it dominates every block.
        True -> ir.Reg
        False ->
          case dict.get(defs, name) {
            // Exactly one definition: promote when it is a value and dominates.
            Ok([single]) -> {
              let #(block, op) = single
              case op_forces_slot(op, recursive) {
                True -> ir.Slot
                False ->
                  case dominates_all(dom, block, uses_of(uses, name)) {
                    True -> ir.Reg
                    False -> ir.Slot
                  }
              }
            }
            _ -> ir.Slot
          }
      }
  }
}

/// The ops whose result the backend writes through the local's address (see
/// `llvm.gleam`), so their destination must have a storage slot.
fn op_forces_slot(op: ir.Op, recursive: Dict(String, Bool)) -> Bool {
  case op {
    ir.OpCall(_, _, _, ret_ty) | ir.OpCallIndirect(_, _, _, ret_ty) ->
      abi.ret_needs_sret(ret_ty, recursive)
    ir.OpBuiltin(_, name, _, ret_ty) ->
      name == "buffer.take" || abi.is_file_result(ret_ty)
    _ -> False
  }
}

// ---------------------------------------------------------------------------
// definition and use collection
// ---------------------------------------------------------------------------

fn collect_defs_and_uses(blocks) {
  list.fold(blocks, #(dict.new(), dict.new()), fn(acc, block) {
    let #(defs, uses) = acc
    let ir.Block(label, ops, term) = block
    let defs =
      list.fold(ops, defs, fn(defs, op) {
        case ir.op_dest(op) {
          Ok(dest) -> push_def(defs, dest, #(label, op))
          Error(_) -> defs
        }
      })
    let uses =
      list.fold(ops, uses, fn(uses, op) {
        record_uses(uses, label, ir.op_reads(op))
      })
    let uses = record_uses(uses, label, ir.term_reads(term))
    #(defs, uses)
  })
}

fn push_def(defs, name, entry) {
  let existing = case dict.get(defs, name) {
    Ok(entries) -> entries
    Error(_) -> []
  }
  dict.insert(defs, name, [entry, ..existing])
}

fn record_uses(uses, label, reads) {
  list.fold(reads, uses, fn(uses, operand) {
    case operand {
      ir.Var(name) -> push_use(uses, name, label)
      ir.Lit(_) -> uses
    }
  })
}

fn push_use(uses, name, label) {
  let existing = case dict.get(uses, name) {
    Ok(labels) -> labels
    Error(_) -> []
  }
  dict.insert(uses, name, [label, ..existing])
}

fn machine_result_dests(blocks) {
  list.fold(blocks, dict.new(), fn(acc, block) {
    let ir.Block(_, ops, _) = block
    list.fold(ops, acc, fn(acc, op) {
      case op {
        ir.OpMachineStart(_, _, _, dest) -> dict.insert(acc, dest, True)
        _ -> acc
      }
    })
  })
}

/// A `case` join: every definition is an `OpCopy`, every def block jumps to the
/// same `join`, and `join`'s predecessors are exactly the def blocks.
fn phi_candidate(defs, terms, preds) {
  case defs {
    [] -> Error(Nil)
    [_, ..] -> {
      let copies =
        list.filter_map(defs, fn(entry) {
          let #(block, op) = entry
          case op {
            ir.OpCopy(_, src, _) -> Ok(#(block, src))
            _ -> Error(Nil)
          }
        })
      case list.length(copies) == list.length(defs) {
        False -> Error(Nil)
        True ->
          case joins_of(copies, terms) {
            Error(_) -> Error(Nil)
            Ok(#(join, blocks)) ->
              case predecessor_labels(preds, join) {
                Ok(join_preds) ->
                  case same_set(join_preds, blocks) {
                    True ->
                      Ok(#(
                        join,
                        list.map(copies, fn(entry) {
                          let #(block, src) = entry
                          #(src, block)
                        }),
                      ))
                    False -> Error(Nil)
                  }
                Error(_) -> Error(Nil)
              }
          }
      }
    }
  }
}

fn joins_of(copies, terms) {
  let joins =
    list.filter_map(copies, fn(entry) {
      let #(block, _) = entry
      case dict.get(terms, block) {
        Ok(ir.Jmp(join)) -> Ok(join)
        _ -> Error(Nil)
      }
    })
  case list.length(joins) == list.length(copies) {
    False -> Error(Nil)
    True ->
      case joins {
        [] -> Error(Nil)
        [first, ..rest] ->
          case list.all(rest, fn(join) { join == first }) {
            True ->
              Ok(#(
                first,
                list.map(copies, fn(entry) {
                  let #(block, _) = entry
                  block
                }),
              ))
            False -> Error(Nil)
          }
      }
  }
}

fn predecessor_labels(preds, join) {
  case dict.get(preds, join) {
    Ok(labels) -> Ok(labels)
    Error(_) -> Error(Nil)
  }
}

fn same_set(a: List(String), b: List(String)) -> Bool {
  list.length(a) == list.length(b)
  && list.all(a, fn(label) { list.contains(b, label) })
}

fn block_terms(blocks) {
  list.fold(blocks, dict.new(), fn(acc, block) {
    let ir.Block(label, _, term) = block
    dict.insert(acc, label, term)
  })
}

// ---------------------------------------------------------------------------
// rewriting
// ---------------------------------------------------------------------------

/// Group the phi plans into one ordered `OpPhi` list per join block. Sorted by
/// destination so emission does not depend on dict iteration order.
fn phi_ops(phi_plans) {
  let entries =
    phi_plans
    |> dict.to_list
    |> list.sort(fn(a, b) {
      let #(name_a, _) = a
      let #(name_b, _) = b
      string.compare(name_a, name_b)
    })
  list.fold(entries, dict.new(), fn(acc, entry) {
    let #(dest, plan) = entry
    let #(join, incoming) = plan
    let existing = case dict.get(acc, join) {
      Ok(ops) -> ops
      Error(_) -> []
    }
    dict.insert(acc, join, list.append(existing, [ir.OpPhi(dest, incoming)]))
  })
}

fn rewrite_blocks(blocks, phi_plans, phis) {
  list.map(blocks, fn(block) {
    let ir.Block(label, ops, term) = block
    // Drop the `OpCopy` that fed a promoted join; its value becomes a phi.
    let ops =
      list.filter(ops, fn(op) {
        case op {
          ir.OpCopy(dest, _, _) -> !dict.has_key(phi_plans, dest)
          _ -> True
        }
      })
    let ops = case dict.get(phis, label) {
      Ok(phi_ops) -> list.append(phi_ops, ops)
      Error(_) -> ops
    }
    ir.Block(label, ops, term)
  })
}

// ---------------------------------------------------------------------------
// unreachable block pruning
// ---------------------------------------------------------------------------

fn prune_unreachable(blocks: List(ir.Block)) -> List(ir.Block) {
  case blocks {
    [] -> []
    [ir.Block(entry, _, _), ..] -> {
      let by_label =
        dict.from_list(
          list.map(blocks, fn(block) {
            let ir.Block(label, _, _) = block
            #(label, block)
          }),
        )
      let reachable = reachable_set([entry], dict.new(), by_label)
      list.filter(blocks, fn(block) {
        let ir.Block(label, _, _) = block
        dict.has_key(reachable, label)
      })
    }
  }
}

fn reachable_set(worklist, seen, by_label) {
  case worklist {
    [] -> seen
    [label, ..rest] ->
      case dict.has_key(seen, label) {
        True -> reachable_set(rest, seen, by_label)
        False -> {
          let succs = case dict.get(by_label, label) {
            Ok(block) -> {
              let ir.Block(_, _, term) = block
              successors(term)
            }
            Error(_) -> []
          }
          reachable_set(
            list.append(rest, succs),
            dict.insert(seen, label, True),
            by_label,
          )
        }
      }
  }
}

// ---------------------------------------------------------------------------
// dominators (iterative, over the IR CFG)
// ---------------------------------------------------------------------------

/// Whether the `block` dominates every block in `uses`.
fn dominates_all(dom, block, uses) -> Bool {
  case dict.get(dom, block) {
    Error(_) -> False
    Ok(_) ->
      list.all(uses, fn(use_block) {
        case dict.get(dom, use_block) {
          Ok(doms) -> dict.has_key(doms, block)
          Error(_) -> False
        }
      })
  }
}

fn dominators(blocks: List(ir.Block)) -> Dict(String, Dict(String, Bool)) {
  let labels =
    list.map(blocks, fn(block) {
      let ir.Block(label, _, _) = block
      label
    })
  let all = list_to_dict(labels)
  let entry = case labels {
    [first, ..] -> first
    [] -> ""
  }
  let preds = predecessors(blocks)
  let initial =
    list.fold(labels, dict.new(), fn(acc, label) {
      case label == entry {
        True -> dict.insert(acc, label, list_to_dict([label]))
        False -> {
          let ps = case dict.get(preds, label) {
            Ok(ps) -> ps
            Error(_) -> []
          }
          case ps {
            [] -> dict.insert(acc, label, list_to_dict([label]))
            _ -> dict.insert(acc, label, all)
          }
        }
      }
    })
  fixpoint_dom(preds, entry, initial)
}

fn fixpoint_dom(preds, entry, dom) {
  let #(next, changed) =
    list.fold(dict.keys(dom), #(dict.new(), False), fn(acc, label) {
      let #(acc_map, changed) = acc
      case label == entry {
        True -> #(dict.insert(acc_map, label, list_to_dict([label])), changed)
        False -> {
          let ps = case dict.get(preds, label) {
            Ok(ps) -> ps
            Error(_) -> []
          }
          let inter = case ps {
            [] -> list_to_dict([label])
            _ -> intersect_sets(dom, ps)
          }
          let new = dict.insert(inter, label, True)
          let old = case dict.get(dom, label) {
            Ok(found) -> found
            Error(_) -> dict.new()
          }
          #(dict.insert(acc_map, label, new), changed || !dict_equal(old, new))
        }
      }
    })
  case changed {
    True -> fixpoint_dom(preds, entry, next)
    False -> next
  }
}

fn intersect_sets(dom, labels) {
  case labels {
    [] -> dict.new()
    [first, ..rest] -> {
      let start = case dict.get(dom, first) {
        Ok(found) -> found
        Error(_) -> dict.new()
      }
      list.fold(rest, start, fn(acc, label) {
        let other = case dict.get(dom, label) {
          Ok(found) -> found
          Error(_) -> dict.new()
        }
        dict.filter(acc, fn(key, _value) { dict.has_key(other, key) })
      })
    }
  }
}

fn predecessors(blocks: List(ir.Block)) -> Dict(String, List(String)) {
  list.fold(blocks, dict.new(), fn(acc, block) {
    let ir.Block(label, _, term) = block
    list.fold(successors(term), acc, fn(acc, succ) {
      let existing = case dict.get(acc, succ) {
        Ok(labels) -> labels
        Error(_) -> []
      }
      dict.insert(acc, succ, [label, ..existing])
    })
  })
}

fn successors(term: ir.Terminator) -> List(String) {
  case term {
    ir.Jmp(label) -> [label]
    ir.Branch(_, then, otherwise) -> [then, otherwise]
    ir.Suspend(_, _, resume, _) -> [resume]
    _ -> []
  }
}

fn dict_equal(a: Dict(String, Bool), b: Dict(String, Bool)) -> Bool {
  dict.size(a) == dict.size(b)
  && list.all(dict.to_list(a), fn(entry) {
    let #(key, _) = entry
    dict.has_key(b, key)
  })
}

fn list_to_dict(names: List(String)) -> Dict(String, Bool) {
  list.fold(names, dict.new(), fn(acc, name) { dict.insert(acc, name, True) })
}
