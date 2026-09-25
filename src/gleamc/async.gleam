//// Async pass (IR -> IR): make suspension explicit at every async call.
////
//// Runs **after** `lower` and **before** `frame`. A function is async if it
//// suspends (a host `Suspend`) or calls an async function; the relation is
//// transitive, so the whole call graph that reaches an `await` becomes async.
////
//// A call to an async function is rewritten from a blocking call into
//// "start the callee as a task on the cooperative driver, then suspend on the
//// future that completes when it does". The callee's result is copied straight
//// into the caller's destination, so the caller never runs a nested loop: the
//// one driver in `gleamc_run_until` owns the libuv loop.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleamc/ast.{TNamed}
import gleamc/ir

/// Applies the asyncness analysis and the call rewrite to every function.
pub fn normalize(module: ir.Module) -> ir.Module {
  let ir.Module(functions) = module
  let asyncs = async_functions(functions)
  ir.Module(list.map(functions, fn(function) {
    normalize_function(function, asyncs)
  }))
}

// ---------------------------------------------------------------------------
// asyncness
// ---------------------------------------------------------------------------

fn async_functions(functions: List(ir.Function)) -> Dict(String, Bool) {
  let initial =
    list.fold(functions, dict.new(), fn(acc, function) {
      case has_host_suspend(function) {
        True -> dict.insert(acc, function.name, True)
        False -> acc
      }
    })
  grow(functions, initial)
}

fn grow(functions, known) {
  let next =
    list.fold(functions, known, fn(acc, function) {
      let ir.Function(name, _, _, blocks, _) = function
      case dict.has_key(acc, name) {
        True -> acc
        False ->
          case calls_async(blocks, known) {
            True -> dict.insert(acc, name, True)
            False -> acc
          }
      }
    })
  case dict.size(next) == dict.size(known) {
    True -> known
    False -> grow(functions, next)
  }
}

fn has_host_suspend(function: ir.Function) -> Bool {
  let ir.Function(_, _, _, blocks, _) = function
  list.any(blocks, fn(block) {
    case block.term {
      ir.Suspend(_, _, _, False) -> True
      _ -> False
    }
  })
}

fn calls_async(blocks, known) -> Bool {
  list.any(blocks, fn(block) {
    let ir.Block(_, ops, term) = block
    list.any(ops, fn(op) {
      case op {
        ir.OpCall(_, fun, _, _) -> dict.has_key(known, fun)
        _ -> False
      }
    })
    || case term {
      ir.Tailcall(fun, _) -> dict.has_key(known, fun)
      _ -> False
    }
  })
}

// ---------------------------------------------------------------------------
// call rewrite
// ---------------------------------------------------------------------------

fn normalize_function(
  function: ir.Function,
  asyncs: Dict(String, Bool),
) -> ir.Function {
  let ir.Function(name, params, ret, blocks, locals) = function
  let #(blocks, locals, _) =
    list.fold(blocks, #([], locals, 0), fn(acc, block) {
      let #(out, locals, counter) = acc
      let #(new_blocks, locals, counter) =
        normalize_block(block, ret, asyncs, locals, counter)
      #(list.append(out, new_blocks), locals, counter)
    })
  ir.Function(name, params, ret, blocks, locals)
}

fn normalize_block(block, ret, asyncs, locals, counter) {
  let ir.Block(label, ops, term) = block
  normalize_ops(ops, term, ret, asyncs, locals, counter, label)
}

/// Walks the ops of one block; every call to an async function ends the current
/// segment with a `Suspend` and continues in a fresh resume block.
fn normalize_ops(ops, term, ret, asyncs, locals, counter, label) {
  case ops {
    [] -> finish_block(term, ret, asyncs, locals, counter, label)
    [op, ..rest] ->
      case op {
        ir.OpCall(dest, fun, args, _) ->
          case dict.has_key(asyncs, fun) {
            True -> {
              let #(fut, locals, counter) =
                fresh_local("__async_fut", TNamed("Future"), locals, counter)
              let resume = "__async_await" <> int.to_string(counter)
              let counter = counter + 1
              let this =
                ir.Block(
                  label,
                  [ir.OpMachineStart(fut, fun, args, dest)],
                  ir.Suspend(ir.Var(fut), dest, resume, True),
                )
              let #(more, locals, counter) =
                normalize_ops(rest, term, ret, asyncs, locals, counter, resume)
              #([this, ..more], locals, counter)
            }
            False -> prepend_op(op, rest, term, ret, asyncs, locals, counter, label)
          }
        _ -> prepend_op(op, rest, term, ret, asyncs, locals, counter, label)
      }
  }
}

fn prepend_op(op, rest, term, ret, asyncs, locals, counter, label) {
  let #(blocks, locals, counter) =
    normalize_ops(rest, term, ret, asyncs, locals, counter, label)
  case blocks {
    [ir.Block(first, first_ops, first_term), ..more] ->
      #([ir.Block(first, [op, ..first_ops], first_term), ..more], locals, counter)
    [] -> #([ir.Block(label, [op], term)], locals, counter)
  }
}

/// The final segment carries the original terminator. A tail call to an async
/// function also starts + suspends, and returns the awaited result.
fn finish_block(term, _ret, asyncs, locals, counter, label) {
  case term {
    ir.Tailcall(fun, args) ->
      case dict.has_key(asyncs, fun) {
        // A tail call delegates the current machine to the callee: no new task,
        // constant task/stack count. See the `OpMachineTail` lowering.
        True ->
          #([ir.Block(label, [], ir.TailMachine(fun, args))], locals, counter)
        False -> #([ir.Block(label, [], term)], locals, counter)
      }
    _ -> #([ir.Block(label, [], term)], locals, counter)
  }
}

fn fresh_local(prefix, ty, locals, counter) {
  let name = prefix <> int.to_string(counter)
  #(name, [ir.Local(name, ty), ..locals], counter + 1)
}
