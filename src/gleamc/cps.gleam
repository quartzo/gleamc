//// Late CPS / continuation normalisation (pre-machine).
////
//// Runs **after** `ownership.insert` and **before** `plan`/the machine
//// backend. It makes continuation control flow explicit in the IR: an
//// indirect call whose result is immediately returned is no longer an
//// `OpCallIndirect` followed by `Ret`, but an `ir.TailcallIndirect`
//// terminator. That is the shape the flat state machine consumes: the
//// callee (a function value / continuation) becomes a state edge instead of
//// a `call`/`callindirect` that grows the native stack.
////
//// Ownership already inserted the retains/drops for the call's arguments, so
//// this pass only changes *how* control leaves the block, not the reference
//// discipline: the owning arguments travel with the terminator.

import gleam/list
import gleam/string
import gleamc/ir

/// Applies the normalisation to every function of the owned module.
pub fn normalize(module: ir.Module) -> ir.Module {
  let ir.Module(functions) = module
  ir.Module(list.map(functions, normalize_function))
}

fn normalize_function(function: ir.Function) -> ir.Function {
  let ir.Function(name, params, ret, blocks, locals) = function
  ir.Function(name, params, ret, list.map(blocks, normalize_block), locals)
}

/// Turns a block ending in `OpCallIndirect(d, f, args); Ret(d)` into
/// `...; TailcallIndirect(f, args)`. When the callee is a local that holds a
/// capture-free top-level function value (`OpClosure(_, "__gv_<name>", [], "",
/// _)`), the indirect call is resolved to a direct `Tailcall`, so it can join
/// the mutual dispatcher like any other direct tail call.
fn normalize_block(block: ir.Block) -> ir.Block {
  let ir.Block(label, ops, term) = block
  case tail_indirect(ops, term) {
    Ok(#(ops, fval, args)) -> {
      let term = case resolve_fn_value(ops, fval) {
        Ok(name) -> ir.Tailcall(name, args)
        Error(_) -> ir.TailcallIndirect(fval, args)
      }
      ir.Block(label, ops, term)
    }
    Error(_) -> block
  }
}

/// Resolves a function-value operand to its top-level function name when the
/// same block builds it as a capture-free global value.
fn resolve_fn_value(ops: List(ir.Op), fval: ir.Operand) {
  case fval {
    ir.Var(v) ->
      list.find_map(ops, fn(op) {
        case op {
          ir.OpClosure(dest, code, [], "", _) ->
            case dest == v && string.starts_with(code, "__gv_") {
              True -> Ok(string.drop_start(code, 5))
              False -> Error(Nil)
            }
          _ -> Error(Nil)
        }
      })
    ir.Lit(_) -> Error(Nil)
  }
}

/// Matches the tail shape `ops ++ [OpCallIndirect(dest, fval, args, _)]` with
/// `Ret(Var(dest))`. Returns the ops without the call plus the callee/args.
fn tail_indirect(ops: List(ir.Op), term: ir.Terminator) {
  case list.reverse(ops) {
    [ir.OpCallIndirect(dest, fval, args, _), ..rest] ->
      case term {
        ir.Ret(ir.Var(returned)) ->
          case returned == dest {
            True -> Ok(#(list.reverse(rest), fval, args))
            False -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}
