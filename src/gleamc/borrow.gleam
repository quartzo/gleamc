//// Interprocedural borrow/move analysis.
////
//// Classifies every function parameter as `Borrow` (the callee only reads it)
//// or `Owned` (the callee consumes it: returns it, stores it, captures it, or
//// hands it to another owning position). A parameter is `Borrow` exactly when
//// no path consumes it.
////
//// Because "hands it to another owning position" depends on the callee's
//// modes, the analysis is a monotone fixpoint over the call graph: start
//// optimistic (everything `Borrow`) and upgrade to `Owned` until stable. FFI
//// modes come from `ffi_modes`; indirect calls and functions whose value is
//// taken are forced `Owned`, so callers and callees always agree on the ABI.

import gleam/dict.{type Dict}
import gleam/list
import gleam/string
import gleamc/ffi_modes
import gleamc/ir

pub fn analyze(module: ir.Module) -> Dict(String, List(ffi_modes.ParamMode)) {
  let ir.Module(functions) = module
  let ffi = ffi_modes.table()
  let optimistic =
    list.fold(functions, dict.new(), fn(acc, function) {
      let ir.Function(name, params, _, _, _) = function
      dict.insert(acc, name, list.map(params, fn(_) { ffi_modes.Borrow }))
    })
  let address_taken = address_taken_names(module)
  let initial =
    list.fold(functions, optimistic, fn(acc, function) {
      let ir.Function(name, params, _, _, _) = function
      case list.contains(address_taken, name) {
        True ->
          dict.insert(acc, name, list.map(params, fn(_) { ffi_modes.Owned }))
        False -> acc
      }
    })
  // A tail call moves its arguments, so the callee's corresponding parameters
  // must be `Owned` (the callee releases them at their last use).
  let targets = tail_targets(functions)
  let initial =
    list.fold(functions, initial, fn(acc, function) {
      let ir.Function(name, params, _, _, _) = function
      case dict.get(targets, name) {
        Error(_) -> acc
        Ok(targets) ->
          dict.insert(
            acc,
            name,
            list.index_map(params, fn(param, index) {
              case tail_target_name(targets, param, index) {
                True -> ffi_modes.Owned
                False ->
                  ffi_modes.mode_at(
                    case dict.get(acc, name) {
                      Ok(modes) -> modes
                      Error(_) -> list.map(params, fn(_) { ffi_modes.Borrow })
                    },
                    index,
                  )
              }
            }),
          )
      }
    })
  let callers = callers_map(functions)
  let by_name =
    list.fold(functions, dict.new(), fn(acc, function) {
      let ir.Function(name, _, _, _, _) = function
      dict.insert(acc, name, function)
    })
  let queue =
    list.map(functions, fn(function) {
      let ir.Function(name, _, _, _, _) = function
      name
    })
  iterate(by_name, ffi, callers, initial, queue)
}

/// Reverse call graph: callee -> functions that call it (direct calls and tail
/// calls), so a mode upgrade can be propagated to exactly the callers that
/// depend on it instead of rescanning every function on every iteration.
fn callers_map(functions) -> Dict(String, List(String)) {
  list.fold(functions, dict.new(), fn(acc, function) {
    let ir.Function(name, _, _, blocks, _) = function
    let callees =
      list.flat_map(blocks, fn(block) {
        let ir.Block(_, ops, term) = block
        let from_ops =
          list.filter_map(ops, fn(op) {
            case op {
              ir.OpCall(_, fun, _, _) -> Ok(fun)
              _ -> Error(Nil)
            }
          })
        let from_term = case term {
          ir.Tailcall(fun, _) -> [fun]
          _ -> []
        }
        list.append(from_ops, from_term)
      })
    list.fold(callees, acc, fn(acc, callee) {
      let existing = case dict.get(acc, callee) {
        Ok(found) -> found
        Error(_) -> []
      }
      dict.insert(acc, callee, [name, ..existing])
    })
  })
}

/// Parameter names (by position) of each function that are the target of a
/// tail call somewhere in the module.
fn tail_targets(functions) -> Dict(String, List(String)) {
  let params_by_name =
    list.fold(functions, dict.new(), fn(acc, function) {
      let ir.Function(name, params, _, _, _) = function
      dict.insert(acc, name, params)
    })
  list.fold(functions, dict.new(), fn(acc, function) {
    let ir.Function(_, _, _, blocks, _) = function
    list.fold(blocks, acc, fn(acc, block) {
      let ir.Block(_, _, term) = block
      case term {
        ir.Tailcall(fun, _) ->
          case dict.get(params_by_name, fun) {
            Ok(params) -> dict.insert(acc, fun, params)
            Error(_) -> acc
          }
        _ -> acc
      }
    })
  })
}

fn tail_target_name(targets, param, _index) -> Bool {
  list.contains(targets, param)
}

fn iterate(by_name, ffi, callers, state, queue) {
  case queue {
    [] -> state
    [name, ..rest] -> {
      case dict.get(by_name, name) {
        Error(_) -> iterate(by_name, ffi, callers, state, rest)
        Ok(function) -> {
          let #(next, changed) = upgrade(function, ffi, state)
          let rest = case changed {
            True -> {
              let cs = case dict.get(callers, name) {
                Ok(found) -> found
                Error(_) -> []
              }
              list.append(cs, rest)
            }
            False -> rest
          }
          iterate(by_name, ffi, callers, next, rest)
        }
      }
    }
  }
}

fn upgrade(function, ffi, state) {
  let ir.Function(name, params, _, _, _) = function
  let current = case dict.get(state, name) {
    Ok(modes) -> modes
    Error(_) -> list.map(params, fn(_) { ffi_modes.Borrow })
  }
  let consumed = consumed_params(function, ffi, state)
  let #(modes_rev, changed) =
    list.fold(
      list.index_map(params, fn(param, index) { #(param, index) }),
      #([], False),
      fn(acc, pair) {
        let #(param, index) = pair
        let #(reversed, changed_so_far) = acc
        let previous = ffi_modes.mode_at(current, index)
        let next = case previous {
          ffi_modes.Owned -> ffi_modes.Owned
          ffi_modes.Borrow ->
            case dict.get(consumed, param) {
              Ok(_) -> ffi_modes.Owned
              Error(_) -> ffi_modes.Borrow
            }
        }
        #([next, ..reversed], changed_so_far || next != previous)
      },
    )
  #(dict.insert(state, name, list.reverse(modes_rev)), changed)
}

/// Names of this function's parameters used in an owning position somewhere in
/// the body, or returned.
fn consumed_params(function, ffi, state) {
  let ir.Function(_name, params, _, blocks, _) = function
  let param_set =
    list.fold(params, dict.new(), fn(acc, name) { dict.insert(acc, name, True) })
  let returned =
    list.fold(blocks, dict.new(), fn(acc, block) {
      let ir.Block(_, _, term) = block
      case term {
        ir.Ret(ir.Var(name)) -> dict.insert(acc, name, True)
        _ -> acc
      }
    })
  list.fold(blocks, dict.new(), fn(acc, block) {
    let ir.Block(_, ops, term) = block
    let acc =
      list.fold(ops, acc, fn(set, op) {
        let set =
          ir.op_owning_modes(op, state, ffi)
          |> list.fold(set, fn(set, operand) {
            consume_param(set, param_set, operand)
          })
        // A parameter copied into a returned local is returned (through the
        // `case` join): `OpCopy(res, param) ... ; Ret(res)`.
        case op {
          ir.OpCopy(dest, src, _) ->
            case dict.get(returned, dest) {
              Ok(_) -> consume_param(set, param_set, src)
              Error(_) -> set
            }
          _ -> set
        }
      })
    case term {
      ir.Ret(ir.Var(name)) -> consume_param(acc, param_set, ir.Var(name))
      // Tail calls move their arguments (the caller does not return).
      ir.Tailcall(_, args) ->
        list.fold(args, acc, fn(set, arg) { consume_param(set, param_set, arg) })
      _ -> acc
    }
  })
}

fn consume_param(set, param_set, operand) {
  case operand {
    ir.Var(name) ->
      case dict.get(param_set, name) {
        Ok(_) -> dict.insert(set, name, True)
        Error(_) -> set
      }
    ir.Lit(_) -> set
  }
}

/// IR function names whose value is taken as a closure, and can therefore be
/// reached by an indirect call with unknown modes.
fn address_taken_names(module: ir.Module) -> List(String) {
  let ir.Module(functions) = module
  list.flat_map(functions, fn(function) {
    let ir.Function(_, _, _, blocks, _) = function
    list.flat_map(blocks, fn(block) {
      let ir.Block(_, ops, _) = block
      list.filter_map(ops, fn(op) {
        case op {
          ir.OpClosure(_, code, _, _, _) -> Ok(code_to_function_name(code))
          _ -> Error(Nil)
        }
      })
    })
  })
}

/// Closure codes are `__gv_<name>` (top-level function as a value) or
/// `Gleamc_<name>` (a lifted lambda); both map back to the IR function name.
fn code_to_function_name(code: String) -> String {
  case string.starts_with(code, "__gv_") {
    True -> drop_prefix(code, 5)
    False ->
      case string.starts_with(code, "Gleamc_") {
        True -> drop_prefix(code, 7)
        False -> code
      }
  }
}

fn drop_prefix(code: String, length: Int) -> String {
  string.slice(code, length, string.length(code))
}
