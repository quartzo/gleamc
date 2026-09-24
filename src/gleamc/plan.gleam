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
    machines: List(String),
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
  let edges =
    list.append(
      list.flat_map(functions, fn(function) { tail_edges(function) }),
      callback_edges(functions),
    )
  let groups = mutual_groups(names, edges)
  let #(states, entries) = number_states(functions)
  let frames =
    list.map(functions, fn(function) {
      let ir.Function(name, _, _, _, locals) = function
      Frame(name, locals)
    })
  // Machine membership is a planning decision: a function that can suspend is
  // emitted as a state machine. The backend consumes this list instead of
  // re-deriving it from the IR.
  let machines = machines(module)
  Plan(
    functions: names,
    frames: frames,
    groups: groups,
    edges: edges,
    states: states,
    entries: entries,
    machines: machines,
  )
}

/// The functions that must be emitted as state machines (they can suspend),
/// in deterministic order. This is the single membership rule, shared by the
/// planner and by any earlier layer that needs it.
pub fn machines(module: ir.Module) -> List(String) {
  let ir.Module(functions) = module
  functions
  |> list.filter(fn(function) { has_suspend(function) || has_capture(function) })
  |> list.map(fn(function) { function.name })
  |> list.sort(fn(a, b) { string.compare(a, b) })
}

/// The members of every eligible dispatcher group, keyed by name. A mutual
/// tail-call group is eligible when it has more than one member, all with the
/// same return type, and does not contain `main`. These functions' indirect
/// tail calls become a jump in the dispatcher; every other indirect tail call
/// is an ordinary call.
pub fn dispatched_members(
  planned: Plan,
  functions: List(ir.Function),
) -> Dict(String, Bool) {
  let by_name =
    dict.from_list(list.map(functions, fn(function) {
      #(function.name, function)
    }))
  let groups = case planned {
    Plan(_, _, groups, _, _, _, _) -> groups
  }
  list.fold(groups, dict.new(), fn(acc, group) {
    let Group(members, _) = group
    let found = list.filter_map(members, fn(name) { dict.get(by_name, name) })
    case
      !list.contains(members, "main")
      && list.length(members) > 1
      && list.length(found) == list.length(members)
      && returns_equal(found)
    {
      True ->
        list.fold(members, acc, fn(acc, name) { dict.insert(acc, name, True) })
      False -> acc
    }
  })
}

fn returns_equal(functions: List(ir.Function)) -> Bool {
  case functions {
    [] -> True
    [first, ..rest] -> {
      let ir.Function(_, _, ret, _, _) = first
      let expected = ir.describe_type(ret)
      list.all(rest, fn(function) {
        let ir.Function(_, _, ret, _, _) = function
        ir.describe_type(ret) == expected
      })
    }
  }
}

/// A function that creates a closure capturing at least one variable: its frame
/// can be referenced by that closure, so it needs a heap frame.
fn has_capture(function: ir.Function) -> Bool {
  list.any(op_list(function), fn(op) {
    case op {
      ir.OpClosure(_, _, captures, _, _) -> !list.is_empty(captures)
      _ -> False
    }
  })
}

fn op_list(function: ir.Function) -> List(ir.Op) {
  let ir.Function(_, _, _, blocks, _) = function
  list.flat_map(blocks, fn(block) {
    let ir.Block(_, ops, _) = block
    ops
  })
}

fn has_suspend(function: ir.Function) -> Bool {
  let ir.Function(_, _, _, blocks, _) = function
  list.any(blocks, fn(block) {
    let ir.Block(_, ops, _) = block
    list.any(ops, fn(op) {
      case op {
        ir.OpSuspend(_, _, _) -> True
        _ -> False
      }
    })
  })
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
  // Top-level functions used as values are closures whose code is
  // `__gv_<name>` and whose capture list is empty. Resolving those lets an
  // indirect tail call (continuation) participate in the same dispatcher as
  // a direct one.
  let known =
    list.fold(blocks, dict.new(), fn(acc, block) {
      let ir.Block(_, ops, _) = block
      list.fold(ops, acc, fn(acc2, op) {
        case op {
          ir.OpClosure(dest, code, [], "", _) ->
            case string.starts_with(code, "__gv_") {
              True -> dict.insert(acc2, dest, string.drop_start(code, 5))
              False -> acc2
            }
          _ -> acc2
        }
      })
    })
  list.filter_map(blocks, fn(block) {
    let ir.Block(_, _, term) = block
    case term {
      ir.Tailcall(fun, _) -> Ok(Edge(name, fun))
      ir.TailcallIndirect(ir.Var(v), _) ->
        case dict.get(known, v) {
          Ok(target) -> Ok(Edge(name, target))
          Error(_) -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}

/// Interprocedural callback edges. When a function `h` tail-calls one of its
/// function-typed parameters and a call site of `h` passes a closure whose code
/// is statically known, `h` can transfer control to that code. This links a CPS
/// combinator such as `result.try` back to the continuation lambda its caller
/// supplied, closing the tail-call cycle so the mutual dispatcher collapses it
/// into `br`s.
fn callback_edges(functions: List(ir.Function)) -> List(Edge) {
  let callback_indices =
    list.fold(functions, dict.new(), fn(acc, function) {
      let ir.Function(name, params, _, blocks, _) = function
      let indices =
        params
        |> list.index_map(fn(param, index) { #(param, index) })
        |> list.filter_map(fn(pair) {
          let #(param, index) = pair
          case called_indirectly(blocks, param) {
            True -> Ok(index)
            False -> Error(Nil)
          }
        })
      dict.insert(acc, name, indices)
    })
  let sites =
    list.fold(functions, dict.new(), fn(acc, function) {
      let ir.Function(_, _, _, blocks, _) = function
      let closures = closure_codes(blocks)
      list.fold(blocks, acc, fn(acc2, block) {
        let ir.Block(_, ops, term) = block
        let acc3 =
          list.fold(ops, acc2, fn(a, op) {
            case op {
              ir.OpCall(_, callee, args, _) ->
                record_sites(a, closures, callee, args)
              _ -> a
            }
          })
        case term {
          ir.Tailcall(callee, args) -> record_sites(acc3, closures, callee, args)
          _ -> acc3
        }
      })
    })
  list.flat_map(dict.to_list(callback_indices), fn(entry) {
    let #(name, indices) = entry
    list.filter_map(indices, fn(index) {
      case dict.get(sites, #(name, index)) {
        Ok(code) -> Ok(Edge(name, code_to_name(code)))
        Error(_) -> Error(Nil)
      }
    })
  })
}

fn record_sites(acc, closures, callee, args) {
  list.index_fold(args, acc, fn(a, arg, index) {
    case arg {
      ir.Var(v) ->
        case dict.get(closures, v) {
          Ok(code) -> dict.insert(a, #(callee, index), code)
          Error(_) -> a
        }
      ir.Lit(_) -> a
    }
  })
}

fn called_indirectly(blocks: List(ir.Block), param: String) -> Bool {
  list.any(blocks, fn(block) {
    let ir.Block(_, ops, term) = block
    let in_ops =
      list.any(ops, fn(op) {
        case op {
          ir.OpCallIndirect(_, ir.Var(name), _, _) -> name == param
          _ -> False
        }
      })
    case term {
      ir.TailcallIndirect(ir.Var(name), _) -> name == param || in_ops
      _ -> in_ops
    }
  })
}

fn closure_codes(blocks: List(ir.Block)) -> Dict(String, String) {
  list.fold(blocks, dict.new(), fn(acc, block) {
    let ir.Block(_, ops, _) = block
    list.fold(ops, acc, fn(acc2, op) {
      case op {
        ir.OpClosure(dest, code, _, _, _) -> dict.insert(acc2, dest, code)
        _ -> acc2
      }
    })
  })
}

/// The IR function a closure code pointer denotes: lambdas carry the
/// `Gleamc_` prefix, top-level function values the `__gv_` prefix.
fn code_to_name(code: String) -> String {
  case string.starts_with(code, "Gleamc_") {
    True -> string.drop_start(code, 7)
    False ->
      case string.starts_with(code, "__gv_") {
        True -> string.drop_start(code, 5)
        False -> code
      }
  }
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
  let Plan(_functions, frames, groups, edges, states, entries, machines) = plan
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
  let machines_text =
    "\n  machines:\n"
    <> string.join(
      list.map(machines, fn(name) { "    " <> name }),
      "\n",
    )
  header
  <> frames_text
  <> groups_text
  <> edges_text
  <> entries_text
  <> states_text
  <> machines_text
  <> "\n}\n"
}
