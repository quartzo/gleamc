//// Planification pass (machine planning).
////
//// Runs **after** `ownership.insert` and turns the owned IR into the plan
//// the state-machine backend needs: the mutual tail-call groups that must
//// collapse into a single dispatcher (the trampoline), the frame layout per
//// planned function, and the state/entry table.
////
//// This pass is pure and deterministic by construction: every input is an
//// explicit parameter, it reads no global state, and it iterates the IR in
//// list order (no dict iteration order leaks into the output). It does not
//// change ownership or the IR — it only *plans*.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/string
import gleamc/ir

// ---------------------------------------------------------------------------
// plan types
// ---------------------------------------------------------------------------

/// Storage frame of one planned function: its params plus its locals, in IR
/// order. The dispatcher keeps one frame per member (union at emission time).
pub type Frame {
  Frame(function: String, fields: List(ir.Local))
}

/// A planned state: one IR block, globally numbered, tagged with its owner.
pub type State {
  State(index: Int, function: String, block: String, kind: StateKind)
}

pub type StateKind {
  Entry
  Body
  Join
}

/// One mutual tail-call group that becomes a single dispatcher.
pub type Group {
  Group(members: List(String), entries: List(#(String, Int)))
}

/// A tail-call edge `caller -> callee` (callee is in tail position).
pub type Edge {
  Edge(caller: String, callee: String)
}

pub type Plan {
  Plan(
    functions: List(String),
    frames: List(Frame),
    groups: List(Group),
    edges: List(Edge),
    states: List(State),
    entries: List(#(String, Int)),
  )
}

// ---------------------------------------------------------------------------
// entry point
// ---------------------------------------------------------------------------

pub fn plan(module: ir.Module) -> Plan {
  let ir.Module(functions) = module
  let names =
    list.map(functions, fn(function) { function.name })
    |> list.sort(fn(a, b) { string.compare(a, b) })
  let edges = list.flat_map(functions, fn(function) { tail_edges(function) })
  let groups = mutual_groups(names, edges)
  let #(states, entries) = number_states(functions)
  let frames =
    list.map(functions, fn(function) {
      let ir.Function(name, _, _, _, locals) = function
      Frame(name, locals)
    })
  Plan(
    functions: names,
    frames: frames,
    groups: groups,
    edges: edges,
    states: states,
    entries: entries,
  )
}

// ---------------------------------------------------------------------------
// tail-call edges
// ---------------------------------------------------------------------------

/// A tail call is an `OpCall(d, fun, ...)` whose result is the function's
/// return value, either directly (`Ret(d)`) or copied into the `case` result
/// local and forwarded to the return block (`OpCopy(res, d); Jmp(end)` with
/// `end: Ret(res)`).
fn tail_edges(function: ir.Function) -> List(Edge) {
  let ir.Function(name, _, _, blocks, _) = function
  list.filter_map(blocks, fn(block) {
    let ir.Block(_, _, term) = block
    case term {
      ir.Tailcall(fun, _) -> Ok(Edge(name, fun))
      _ -> Error(Nil)
    }
  })
}

// ---------------------------------------------------------------------------
// mutual groups (SCCs of the tail-call graph)
// ---------------------------------------------------------------------------

fn mutual_groups(names: List(String), edges: List(Edge)) -> List(Group) {
  let adjacency = group_adjacency(edges)
  let reach =
    list.fold(names, dict.new(), fn(acc, name) {
      dict.insert(acc, name, reachable(name, adjacency, dict.new()))
    })
  let members =
    list.filter(names, fn(name) {
      case dict.get(reach, name) {
        Ok(reached) ->
          list.any(dict.keys(reached), fn(other) {
            other != name && reaches(other, name, reach)
          })
        Error(_) -> False
      }
    })
  // Assign each name to the group of the first member that reaches it and is
  // reached by it; iterate in `names` order for determinism.
  let #(groups, _seen) =
    list.fold(members, #([], dict.new()), fn(acc, name) {
      let #(groups, seen) = acc
      case dict.get(seen, name) {
        Ok(_) -> #(groups, seen)
        Error(_) -> {
          let group =
            list.filter(members, fn(other) { mutually(name, other, reach) })
          let seen =
            list.fold(group, seen, fn(seen, member) {
              dict.insert(seen, member, True)
            })
          #([group, ..groups], seen)
        }
      }
    })
  list.map(list.reverse(groups), fn(group) { Group(group, []) })
}

fn mutually(a, b, reach) -> Bool {
  a == b || reaches(a, b, reach) && reaches(b, a, reach)
}

fn reaches(a, b, reach) -> Bool {
  case dict.get(reach, a) {
    Ok(reached) ->
      case dict.get(reached, b) {
        Ok(_) -> True
        Error(_) -> False
      }
    Error(_) -> False
  }
}

/// Caller -> callees adjacency, built once (avoids re-scanning the edge list
/// at every step of the reachability DFS, which made it O(V^2 * E)).
fn group_adjacency(edges: List(Edge)) -> Dict(String, List(String)) {
  list.fold(edges, dict.new(), fn(acc, edge) {
    let Edge(caller, callee) = edge
    let existing = case dict.get(acc, caller) {
      Ok(found) -> found
      Error(_) -> []
    }
    dict.insert(acc, caller, [callee, ..existing])
  })
}

fn reachable(name, adjacency, seen) -> Dict(String, Bool) {
  case dict.get(seen, name) {
    Ok(_) -> seen
    Error(_) -> {
      let seen = dict.insert(seen, name, True)
      let next = case dict.get(adjacency, name) {
        Ok(found) -> found
        Error(_) -> []
      }
      list.fold(next, seen, fn(acc, callee) { reachable(callee, adjacency, acc) })
    }
  }
}

// ---------------------------------------------------------------------------
// state numbering
// ---------------------------------------------------------------------------

fn number_states(
  functions: List(ir.Function),
) -> #(List(State), List(#(String, Int))) {
  list.fold(functions, #([], []), fn(acc, function) {
    let #(states, entries) = acc
    let ir.Function(name, _, _, blocks, _) = function
    let base = list.length(states)
    let new_states =
      blocks
      |> list.index_map(fn(block, offset) {
        let ir.Block(label, _, _) = block
        State(base + offset, name, label, kind_at(label, offset))
      })
    #(list.append(states, new_states), list.append(entries, [#(name, base)]))
  })
}

fn kind_at(label, offset) -> StateKind {
  case offset, string.starts_with(label, "case_") {
    0, _ -> Entry
    _, True -> Join
    _, False -> Body
  }
}

// ---------------------------------------------------------------------------
// deterministic text dump
// ---------------------------------------------------------------------------

pub fn to_text(plan: Plan) -> String {
  let Plan(_functions, frames, groups, edges, states, entries) = plan
  let header = "plan {\n"
  let frames_text =
    "  frames:\n"
    <> string.join(
      list.map(frames, fn(frame) {
        let Frame(name, fields) = frame
        "    "
        <> name
        <> "("
        <> string.join(
          list.map(fields, fn(field) {
            let ir.Local(field_name, field_ty) = field
            field_name <> ": " <> ir.describe_type(field_ty)
          }),
          ", ",
        )
        <> ")"
      }),
      "\n",
    )
  let groups_text =
    "\n  groups:\n"
    <> string.join(
      list.map(groups, fn(group) {
        let Group(members, _) = group
        "    [" <> string.join(members, ", ") <> "]"
      }),
      "\n",
    )
  let edges_text =
    "\n  edges:\n"
    <> string.join(
      list.map(edges, fn(edge) {
        let Edge(caller, callee) = edge
        "    " <> caller <> " -> " <> callee
      }),
      "\n",
    )
  let entries_text =
    "\n  entries:\n"
    <> string.join(
      list.map(entries, fn(entry) {
        let #(name, index) = entry
        "    " <> name <> " = @" <> int.to_string(index)
      }),
      "\n",
    )
  let states_text =
    "\n  states:\n"
    <> string.join(
      list.map(states, fn(state) {
        let State(index, function, block, _kind) = state
        "    @" <> int.to_string(index) <> " " <> function <> "::" <> block
      }),
      "\n",
    )
  header
  <> frames_text
  <> groups_text
  <> edges_text
  <> entries_text
  <> states_text
  <> "\n}\n"
}
