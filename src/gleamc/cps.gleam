//// CPS pass (port of Vesper `cps.py`): suspend split + machine marking.
////
//// Runs **after** `ownership.insert` and **before** `plan`/the machine
//// backend. It only makes async suspension control flow explicit: each block
//// is split at every `OpSuspend`, so each segment becomes a state with its own
//// resume label. Tail calls (direct and indirect) are **not** handled here —
//// they are created in `lower`, where the tail position is known.

import gleam/int
import gleam/list
import gleamc/ir

/// Applies the split to every function of the owned module.
pub fn normalize(module: ir.Module) -> ir.Module {
  let ir.Module(functions) = module
  ir.Module(list.map(functions, normalize_function))
}

fn normalize_function(function: ir.Function) -> ir.Function {
  let ir.Function(name, params, ret, blocks, locals) = function
  let blocks = list.flat_map(blocks, split_suspends)
  ir.Function(name, params, ret, blocks, locals)
}

// ---------------------------------------------------------------------------
// suspend split (port of Vesper `cps.py`)
// ---------------------------------------------------------------------------

/// Splits a block at every `OpSuspend`, so each segment becomes a state with
/// its own label and the suspension records its resume label. A function with
/// a `Suspend` is thereby a state machine (the emitter drives it through
/// `gleamc_sched_run`). Blocks without a suspension are returned unchanged.
fn split_suspends(block: ir.Block) -> List(ir.Block) {
  let ir.Block(label, ops, term) = block
  let segments = segment(ops)
  case list.length(segments) {
    1 -> [block]
    n -> {
      let labels =
        list.index_map(segments, fn(_, index) {
          case index {
            0 -> label
            _ -> label <> "_s" <> int.to_string(index)
          }
        })
      list.index_map(segments, fn(segment_ops, index) {
        let last = index == n - 1
        let next = case last {
          True -> ""
          False -> list_at(labels, index + 1)
        }
        let ops = case last {
          True -> segment_ops
          False -> set_resumes(segment_ops, next)
        }
        let term = case last {
          True -> term
          False -> ir.Jmp(next)
        }
        ir.Block(list_at(labels, index), ops, term)
      })
    }
  }
}

/// Splits an op list into segments, each ending right after a `Suspend`.
fn segment(ops: List(ir.Op)) -> List(List(ir.Op)) {
  segment_loop(ops, [], [])
}

fn segment_loop(ops, current, done) {
  case ops {
    [] -> list.reverse([list.reverse(current), ..done])
    [op, ..rest] -> {
      let current = [op, ..current]
      case op {
        ir.OpSuspend(_, _, _) ->
          segment_loop(rest, [], [list.reverse(current), ..done])
        _ -> segment_loop(rest, current, done)
      }
    }
  }
}

/// Stamps the resume label on the (single) `Suspend` ending a segment.
fn set_resumes(ops, resume) {
  list.map(ops, fn(op) {
    case op {
      ir.OpSuspend(dest, fut, _) -> ir.OpSuspend(dest, fut, resume)
      _ -> op
    }
  })
}

fn list_at(items: List(a), index: Int) -> a {
  case items {
    [first, ..] if index == 0 -> first
    [_, ..rest] -> list_at(rest, index - 1)
    [] -> panic as "cps: index out of range"
  }
}

