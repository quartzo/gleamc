//// Async lowering (IR -> IR): turn an async function into a synchronous
//// state machine.
////
//// There is no "yield point" in the output: the function is a plain state
//// machine whose control flow is ordinary IR, and a `Future` is an ordinary
//// value. The machine's frame holds the state, the pending future, the result
//// and every local live across a state transition.
////
//// Liveness is computed over the state graph: a transition that returns to the
//// driver and resumes at another state is just an edge from the returning
//// block to the resumed block, so the standard backward analysis applies.

import gleam/dict.{type Dict}
import gleam/list
import gleamc/ir

/// The successor blocks of a terminator within a single run (a `Jmp`/`Branch`
/// stays in the same state; the runtime-resumed edge is supplied separately in
/// `resumes`).
fn term_successors(term: ir.Terminator) -> List(String) {
  case term {
    ir.Jmp(label) -> [label]
    ir.Branch(_, then, otherwise) -> [then, otherwise]
    _ -> []
  }
}

/// A backward liveness fixpoint over the block graph, where `resumes` adds the
/// runtime edge from a returning block to the block it resumes at.
pub fn live_out_map(
  blocks: List(ir.Block),
  resumes: Dict(String, String),
) -> Dict(String, Dict(String, Bool)) {
  let initial =
    list.fold(blocks, dict.new(), fn(acc, block) {
      let ir.Block(label, _, _) = block
      dict.insert(acc, label, dict.new())
    })
  fixpoint(blocks, resumes, initial)
}

fn fixpoint(blocks, resumes, live_out) {
  let #(next, changed) =
    list.fold(blocks, #(dict.new(), False), fn(acc, block) {
      let #(result, changed) = acc
      let ir.Block(label, _, term) = block
      let succs = case dict.get(resumes, label) {
        Ok(resume) -> [resume, ..term_successors(term)]
        Error(_) -> term_successors(term)
      }
      let out =
        list.fold(succs, dict.new(), fn(set, succ) {
          case dict.get(live_out, succ) {
            Ok(found) -> dict.merge(set, found)
            Error(_) -> set
          }
        })
      let previous = case dict.get(live_out, label) {
        Ok(found) -> found
        Error(_) -> dict.new()
      }
      #(dict.insert(result, label, out), changed || !dict_equal(previous, out))
    })
  case changed {
    True -> fixpoint(blocks, resumes, next)
    False -> next
  }
}

/// Locals live at every runtime transition (a block in `resumes`): these must
/// live in the heap frame. The reads of the returning block itself are
/// included, since the resumed block cannot see them otherwise.
pub fn live_at_transitions(
  function: ir.Function,
  resumes: Dict(String, String),
) -> List(String) {
  let ir.Function(_, _, _, blocks, _) = function
  let live_out = live_out_map(blocks, resumes)
  blocks
  |> list.filter(fn(block) { dict.has_key(resumes, block.label) })
  |> list.flat_map(fn(block) {
    let base = case dict.get(live_out, block.label) {
      Ok(found) -> found
      Error(_) -> dict.new()
    }
    let with_reads =
      list.fold(ir.term_reads(block.term), base, fn(acc, operand) {
        case operand {
          ir.Var(name) -> dict.insert(acc, name, True)
          ir.Lit(_) -> acc
        }
      })
    dict.keys(with_reads)
  })
  |> dedupe
}

fn dict_equal(a, b) {
  dict.size(a) == dict.size(b)
  && list.all(dict.to_list(a), fn(entry) {
    let #(key, _) = entry
    dict.has_key(b, key)
  })
}

fn dedupe(names: List(String)) -> List(String) {
  names
  |> list.fold(dict.new(), fn(acc, name) { dict.insert(acc, name, True) })
  |> dict.keys
}
