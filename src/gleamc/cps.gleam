//// CPS pass: split blocks at non-tail member calls.
////
//// Runs **after** `ownership.insert` and **before** `plan`/the machine
//// backend. It makes control flow explicit for a non-tail call between two
//// members of a dispatcher: the block is split after the call so the return
//// has a label to resume at (the backend does the frame push + jump). Async is
//// not a suspension here — a `Future` is a value awaited through the libuv
//// loop — so the machine never sees it. Tail calls (direct and indirect) are
//// **not** handled here; they are created in `lower`, where the tail position
//// is known.

import gleam/dict
import gleam/int
import gleam/list
import gleamc/ir
import gleamc/plan

/// Applies the split to every function of the owned module.
pub fn normalize(module: ir.Module) -> ir.Module {
  let ir.Module(functions) = module
  // Members of a dispatcher: a non-tail call between them can be done with a
  // frame push + jump instead of a native call, if the block is split so the
  // return has a label to resume at (the backend does the push/jump).
  let members = plan.dispatched_members(plan.plan(module), functions)
  ir.Module(list.map(functions, fn(function) {
    normalize_function(function, members)
  }))
}

fn normalize_function(function: ir.Function, members) -> ir.Function {
  let ir.Function(name, params, ret, blocks, locals) = function
  let blocks = case dict.has_key(members, name) {
    True ->
      list.flat_map(blocks, fn(block) { split_calls(block, members) })
    False -> blocks
  }
  ir.Function(name, params, ret, blocks, locals)
}

/// Splits a block so that every non-tail call to a dispatcher member ends its
/// segment. The following block is the resume label (its terminator is the
/// original one). The backend turns the segment-final `OpCall` into a frame
/// push + jump, and the member's `Ret` resumes the saved label.
fn split_calls(block: ir.Block, members) -> List(ir.Block) {
  let ir.Block(label, ops, term) = block
  let segments = segment_calls(ops, members, [], [])
  case list.length(segments) {
    1 -> [block]
    n -> {
      let labels =
        list.index_map(segments, fn(_, index) {
          case index {
            0 -> label
            _ -> label <> "_c" <> int.to_string(index)
          }
        })
      list.index_map(segments, fn(segment_ops, index) {
        let last = index == n - 1
        let term = case last {
          True -> term
          False -> ir.Jmp(list_at(labels, index + 1))
        }
        ir.Block(list_at(labels, index), segment_ops, term)
      })
    }
  }
}

fn segment_calls(ops, members, current, done) {
  case ops {
    [] -> list.reverse([list.reverse(current), ..done])
    [op, ..rest] -> {
      let current = [op, ..current]
      let ends = case op {
        ir.OpCall(_, fun, _, _) -> dict.has_key(members, fun)
        _ -> False
      }
      case ends {
        True ->
          segment_calls(rest, members, [], [list.reverse(current), ..done])
        False -> segment_calls(rest, members, current, done)
      }
    }
  }
}

fn list_at(items: List(a), index: Int) -> a {
  case items {
    [first, ..] if index == 0 -> first
    [_, ..rest] -> list_at(rest, index - 1)
    [] -> panic as "cps: index out of range"
  }
}

