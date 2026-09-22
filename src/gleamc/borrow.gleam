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

const max_iterations = 200

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
  iterate(functions, ffi, initial, 0)
}

fn iterate(functions, ffi, state, iteration) {
  case iteration >= max_iterations {
    True -> state
    False -> {
      let #(next, changed) =
        list.fold(functions, #(state, False), fn(acc, function) {
          let #(current, changed_so_far) = acc
          let #(updated, this_changed) = upgrade(function, ffi, current)
          #(updated, changed_so_far || this_changed)
        })
      case changed {
        True -> iterate(functions, ffi, next, iteration + 1)
        False -> next
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
  list.fold(blocks, dict.new(), fn(acc, block) {
    let ir.Block(_, ops, term) = block
    let acc =
      list.fold(ops, acc, fn(set, op) {
        ir.op_owning_modes(op, state, ffi)
        |> list.fold(set, fn(set, operand) {
          case operand {
            ir.Var(name) ->
              case list.contains(params, name) {
                True -> dict.insert(set, name, True)
                False -> set
              }
            ir.Lit(_) -> set
          }
        })
      })
    case term {
      ir.Ret(ir.Var(name)) ->
        case list.contains(params, name) {
          True -> dict.insert(acc, name, True)
          False -> acc
        }
      _ -> acc
    }
  })
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
