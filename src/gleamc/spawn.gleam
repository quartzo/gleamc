//// Spawn pass (IR -> IR): turn `process.spawn` / `task.async` into
//// explicit task starts.
////
//// Runs **after** `lower` and **before** `async`. Both builtins take a single
//// `fn() -> ...` value (matching `gleam/erlang/process.spawn` and
//// `gleam/otp/task.async`). The value is either a bare named function
//// (`__gv_<name>`, no environment) or a lifted lambda (`Gleamc___lambda_N`),
//// which may capture an environment. In both cases the worker's machine is
//// started on the cooperative driver **without suspending** the caller.

import gleam/dict
import gleam/list
import gleam/result
import gleam/string
import gleamc/ir

/// Rewrites every `process.spawn` / `task.async` call in the module.
pub fn rewrite(module: ir.Module) -> Result(ir.Module, String) {
  let ir.Module(functions) = module
  use functions <- result.try(
    try_map(functions, fn(function) { rewrite_function(function) }),
  )
  Ok(ir.Module(functions))
}

fn rewrite_function(function) {
  let ir.Function(name, params, ret, blocks, locals) = function
  // Closures are usually defined in the block that calls `spawn`, but collect
  // across every block so a lambda defined earlier still resolves.
  let closures =
    list.fold(blocks, dict.new(), fn(acc, block) {
      let ir.Block(_, ops, _) = block
      list.fold(ops, acc, fn(acc, op) {
        case op {
          ir.OpClosure(dest, code, captures, _, _) ->
            dict.insert(acc, dest, #(code, captures))
          _ -> acc
        }
      })
    })
  use blocks <- result.try(
    try_map(blocks, fn(block) {
      let ir.Block(label, ops, term) = block
      use ops <- result.try(try_map(ops, fn(op) { rewrite_op(op, closures) }))
      Ok(ir.Block(label, ops, term))
    }),
  )
  Ok(ir.Function(name, params, ret, blocks, locals))
}

fn rewrite_op(op, closures) {
  case op {
    ir.OpBuiltin(dest, builtin, [first], _ret)
      if builtin == "process.spawn"
      || builtin == "process.spawn_unlinked"
      || builtin == "task.async"
    -> {
      let into_future = builtin == "task.async"
      case first {
        ir.Var(v) ->
          case dict.get(closures, v) {
            Ok(#(code, _captures)) -> {
              let worker = strip_prefix(code)
              case string.starts_with(worker, "__gv_") {
                // A bare named function: no environment, no arguments.
                True ->
                  Ok(ir.OpTaskStart(
                    dest,
                    string.drop_start(worker, 5),
                    [],
                    into_future,
                  ))
                // A lifted (possibly capturing) lambda: start its machine and
                // adopt the closure's environment.
                False ->
                  Ok(ir.OpTaskStartClosure(dest, worker, first, into_future))
              }
            }
            Error(_) -> Error(builtin <> " expects a function value")
          }
        _ -> Error(builtin <> " expects a function value")
      }
    }
    _ -> Ok(op)
  }
}

fn strip_prefix(code) -> String {
  case string.starts_with(code, "Gleamc_") {
    True -> string.drop_start(code, 7)
    False -> code
  }
}

fn try_map(items, f) -> Result(List(b), String) {
  case items {
    [] -> Ok([])
    [item, ..rest] -> {
      use mapped <- result.try(f(item))
      use rest2 <- result.try(try_map(rest, f))
      Ok([mapped, ..rest2])
    }
  }
}
