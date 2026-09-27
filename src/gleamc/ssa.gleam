//// SSA promotion (S1): mark the locals that can live in an SSA register
//// (`ir.Reg`) instead of a memory slot (`ir.Slot`), so the backend skips their
//// entry `alloca` and their `load`/`store`.
////
//// Only *plain* functions are promoted. A machine / frame function keeps every
//// local in its heap frame (the frame is its closure environment and the async
//// state), so it is left untouched.
////
//// A local is promoted when:
////
//// - it has exactly one definition (multi-defined `case` result temporaries stay
////   in a slot until S2 inserts `phi`);
//// - that definition dominates every use. `ownership` can leave a `drop` on a
////   path that does not pass through the definition (e.g. a `case` fail block),
////   and an SSA value is not available there;
//// - the definition is always rendered as a value: not an `sret` call, a
////   `buffer.take`, or a `FileResult` builtin, whose result the backend writes
////   through the destination's address;
//// - it is not `__frame` / `__env` or a machine start's `result_dest`.

import gleam/dict.{type Dict}
import gleam/list
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
  let dom = dominators(blocks)
  // definition count, the defining op, the defining block and the use blocks
  let #(def_count, def_op, def_block, uses) =
    list.fold(
      blocks,
      #(dict.new(), dict.new(), dict.new(), dict.new()),
      fn(acc, block) {
        let ir.Block(label, ops, term) = block
        let acc =
          list.fold(ops, acc, fn(acc, op) { record_def(acc, label, op) })
        let acc =
          list.fold(ops, acc, fn(acc, op) {
            record_uses(acc, label, ir.op_reads(op))
          })
        record_uses(acc, label, ir.term_reads(term))
      },
    )
  let params_set = list_to_dict(params)
  let result_dests =
    list.fold(blocks, dict.new(), fn(acc, block) {
      let ir.Block(_, ops, _) = block
      list.fold(ops, acc, fn(acc, op) {
        case op {
          ir.OpMachineStart(_, _, _, dest) -> dict.insert(acc, dest, True)
          _ -> acc
        }
      })
    })
  let locals =
    list.map(locals, fn(local) {
      let ir.Local(n, ty, _) = local
      ir.Local(
        n,
        ty,
        classify(
          n,
          def_count,
          def_op,
          def_block,
          uses,
          dom,
          params_set,
          result_dests,
          recursive,
        ),
      )
    })
  ir.Function(name, params, ret, blocks, locals)
}

fn record_def(acc, label, op) {
  let #(counts, ops_by_name, blocks_by_name, uses) = acc
  case ir.op_dest(op) {
    Ok(dest) -> {
      let n = case dict.get(counts, dest) {
        Ok(n) -> n + 1
        Error(_) -> 1
      }
      #(
        dict.insert(counts, dest, n),
        dict.insert(ops_by_name, dest, op),
        dict.insert(blocks_by_name, dest, label),
        uses,
      )
    }
    Error(_) -> acc
  }
}

fn record_uses(acc, label, reads) {
  let #(counts, ops_by_name, blocks_by_name, uses) = acc
  let uses =
    list.fold(reads, uses, fn(uses, operand) {
      case operand {
        ir.Var(n) -> push_use(uses, n, label)
        ir.Lit(_) -> uses
      }
    })
  #(counts, ops_by_name, blocks_by_name, uses)
}

fn push_use(uses, name, label) {
  let existing = case dict.get(uses, name) {
    Ok(labels) -> labels
    Error(_) -> []
  }
  dict.insert(uses, name, [label, ..existing])
}

fn classify(
  name,
  def_count,
  def_op,
  def_block,
  uses,
  dom,
  params,
  result_dests,
  recursive,
) -> ir.Storage {
  case name == frame.frame_local || name == "__env" {
    True -> ir.Slot
    False ->
      case dict.has_key(result_dests, name) {
        True -> ir.Slot
        False ->
          case dict.has_key(params, name) {
            // A parameter is defined by the ABI, so it dominates every block.
            True -> ir.Reg
            False ->
              case dict.get(def_count, name) {
                Ok(1) -> {
                  let block = case dict.get(def_block, name) {
                    Ok(b) -> b
                    Error(_) -> ""
                  }
                  let uses = case dict.get(uses, name) {
                    Ok(labels) -> labels
                    Error(_) -> []
                  }
                  case dict.get(def_op, name) {
                    Ok(op) ->
                      case op_forces_slot(op, recursive) {
                        True -> ir.Slot
                        False ->
                          case dominates_all(dom, block, uses) {
                            True -> ir.Reg
                            False -> ir.Slot
                          }
                      }
                    Error(_) -> ir.Slot
                  }
                }
                _ -> ir.Slot
              }
          }
      }
  }
}

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

fn list_to_dict(names: List(String)) -> Dict(String, Bool) {
  list.fold(names, dict.new(), fn(acc, name) { dict.insert(acc, name, True) })
}

// ---------------------------------------------------------------------------
// dominators (iterative, over the IR CFG)
// ---------------------------------------------------------------------------

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
