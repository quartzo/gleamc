//// Frame analysis (the first slice of the frame-environment work).
////
//// A variable belongs in a function's frame if and only if it is captured by a
//// closure or live across a suspension (`OpSuspend`). This module computes that
//// set from the IR. Materializing the frame as an explicit IR value
//// (`OpFrameNew` plus field get/set) is the next step; this module is the
//// analysis it will consume.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/string
import gleamc/ast.{TNil}
import gleamc/ir

/// The synthetic local that holds the frame handle.
pub const frame_local = "__frame"

/// The composite type of a function's frame. The name matches the machine
/// frame type emitted by the backend (`%__frame_<fn>`).
pub fn frame_type_name(function_name: String) -> String {
  "__frame_" <> function_name
}

/// Functions that must be worked through a heap frame: a closure captures one
/// of their locals, so the locals cannot live on the native stack. Async is not
/// part of this rule: a `Future` is a value awaited through the libuv loop, so
/// the frame never needs to carry a suspension state.
pub fn machine_functions(module: ir.Module) -> List(String) {
  let ir.Module(functions) = module
  functions
  |> list.filter(fn(function) { has_capture(function) })
  |> list.map(fn(function) { function.name })
  |> list.sort(fn(a, b) { string.compare(a, b) })
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

/// Materializes the frame of every machine function as an explicit IR value:
/// `OpFrameNew` at the entry, and every capturing closure references the
/// defining frame instead of copying its captures. The frame's allocation is
/// rendered by the backend (a heap cell); `ownership` schedules its release.
pub fn materialize(module: ir.Module) -> ir.Module {
  // `link_closures` rewires every capturing closure to its defining frame;
  // `demote_module` then adds `OpFrameNew` and lowers each frame field of the
  // machine functions to explicit stores/loads.
  demote_module(link_closures(module))
}

/// Keyed by lifted-lambda name: (defining frame type, capture slots).
fn link_closures(module: ir.Module) -> ir.Module {
  let ir.Module(functions) = module
  let infos =
    list.fold(functions, dict.new(), fn(acc, function) {
      let ir.Function(name, _, _, blocks, locals) = function
      let slots = slot_map(locals)
      let frame_ty = frame_type_name(name)
      list.fold(blocks, acc, fn(acc, block) {
        let ir.Block(_, ops, _) = block
        list.fold(ops, acc, fn(acc, op) {
          case op {
            ir.OpClosure(_, code, captures, _, _) ->
              case list.is_empty(captures) {
                True -> acc
                False ->
                  dict.insert(acc, code_to_name(code), #(
                    frame_ty,
                    capture_slots(captures, slots),
                  ))
              }
            _ -> acc
          }
        })
      })
    })
  ir.Module(list.map(functions, fn(function) { relink(function, infos) }))
}

fn relink(function: ir.Function, infos) -> ir.Function {
  let ir.Function(name, params, ret, blocks, locals) = function
  let own_frame = frame_type_name(name)
  // A lifted lambda reads its captures from the *defining* function's frame.
  let #(env_frame, own_slots) = case dict.get(infos, name) {
    Ok(#(defining_frame, slots)) -> #(defining_frame, slots)
    Error(_) -> #(own_frame, [])
  }
  let blocks =
    list.map(blocks, fn(block) {
      let ir.Block(label, ops, term) = block
      let ops =
        list.map(ops, fn(op) {
          case op {
            // The closure references the defining frame (env_ty marks it as a
            // frame capture); the capture operands stay so ownership can see
            // which locals the frame owns.
            ir.OpClosure(dest, code, captures, _env_ty, fn_ty) ->
              case list.is_empty(captures) {
                // No captures: a bare function value, no environment at all.
                True -> ir.OpClosure(dest, code, [], "", fn_ty)
                False -> ir.OpClosure(dest, code, captures, own_frame, fn_ty)
              }
            // Captured-variable reads become reads of the defining frame's slot.
            ir.OpEnvGet(dest, _, index, ty) ->
              ir.OpEnvGet(dest, env_frame, list_at(own_slots, index), ty)
            _ -> op
          }
        })
      ir.Block(label, ops, term)
    })
  ir.Function(name, params, ret, blocks, locals)
}

fn capture_slots(captures, slots) -> List(Int) {
  list.map(captures, fn(capture) {
    case capture {
      ir.Var(name) ->
        case dict.get(slots, name) {
          Ok(slot) -> slot
          Error(_) -> 0
        }
      ir.Lit(_) -> 0
    }
  })
}

fn slot_map(locals) -> Dict(String, Int) {
  let #(_, _, map) =
    list.fold(locals, #(dict.new(), 0, dict.new()), fn(acc, local) {
      let #(seen, next, map) = acc
      let ir.Local(name, _) = local
      case dict.has_key(seen, name) {
        True -> #(seen, next, map)
        False ->
          #(
            dict.insert(seen, name, True),
            next + 1,
            dict.insert(map, name, next),
          )
      }
    })
  map
}

fn list_at(slots: List(Int), index: Int) -> Int {
  case slots {
    [first, ..] if index == 0 -> first
    [_, ..rest] -> list_at(rest, index - 1)
    [] -> 0
  }
}

fn code_to_name(code: String) -> String {
  case string.starts_with(code, "__gv_") {
    True -> string.drop_start(code, 5)
    False ->
      case string.starts_with(code, "Gleamc_") {
        True -> string.drop_start(code, 7)
        False -> code
      }
  }
}

/// Demotes the frame fields of every machine function to explicit stores/loads
/// on the `__frame` value, so `ownership` sees and manages each value.
fn demote_module(module: ir.Module) -> ir.Module {
  let ir.Module(functions) = module
  let machines = machine_functions(module)
  ir.Module(list.map(functions, fn(function) {
    case list.contains(machines, function.name) {
      True -> demote_function(function)
      False -> function
    }
  }))
}

fn demote_function(function: ir.Function) -> ir.Function {
  let ir.Function(name, params, ret, blocks, locals) = function
  let frame_ty = frame_type_name(name)
  let by_name =
    list.fold(locals, dict.new(), fn(acc, local) {
      let ir.Local(n, t) = local
      dict.insert(acc, n, t)
    })
  // Slots follow the function's local layout (the frame's storage), so they
  // match the backend's `unique_locals` order.
  let all_slots = slot_map(locals)
  let field_slots =
    list.fold(frame_field_names(function), dict.new(), fn(acc, n) {
      case dict.get(all_slots, n) {
        Ok(slot) -> dict.insert(acc, n, slot)
        Error(_) -> acc
      }
    })
  // Parameters that are frame fields are stored into the frame at entry.
  let param_stores =
    list.filter_map(params, fn(param) {
      case dict.get(field_slots, param) {
        Ok(slot) ->
          Ok(ir.OpFrameSet(ir.Var(frame_local), slot, ir.Var(param)))
        Error(_) -> Error(Nil)
      }
    })
  let #(blocks, _) =
    list.fold(blocks, #([], 0), fn(state, block) {
      let #(acc, counter) = state
      let #(block, counter) =
        demote_block(block, field_slots, by_name, counter)
      #(list.append(acc, [block]), counter)
    })
  let prologue = [ir.OpFrameNew(frame_local, frame_ty), ..param_stores]
  let blocks = case blocks {
    [] -> []
    [ir.Block(label, ops, term), ..rest] ->
      [ir.Block(label, list.append(prologue, ops), term), ..rest]
  }
  // The `OpFrameGet` destinations are new locals.
  let read_locals =
    list.flat_map(blocks, fn(block) {
      let ir.Block(_, ops, _) = block
      list.filter_map(ops, fn(op) {
        case op {
          ir.OpFrameGet(dest, _, _, ty) -> Ok(ir.Local(dest, ty))
          _ -> Error(Nil)
        }
      })
    })
  let locals = list.append(locals, read_locals)
  ir.Function(name, params, ret, blocks, locals)
}

fn demote_block(block, field_slots, by_name, counter) {
  let ir.Block(label, ops, term) = block
  let #(ops, counter) =
    list.fold(ops, #([], counter), fn(state, op) {
      let #(acc, counter) = state
      let #(gets, repl, counter) = case op {
        // Closures keep their capture operands; they reference the frame value.
        ir.OpClosure(_, _, _, _, _) -> #([], dict.new(), counter)
        _ -> block_reads(ir.op_reads(op), field_slots, by_name, counter)
      }
      let op = rewrite_op(op, repl)
      let stores = case ir.op_dest(op) {
        Ok(dest) ->
          case dict.get(field_slots, dest) {
            Ok(slot) -> [ir.OpFrameSet(ir.Var(frame_local), slot, ir.Var(dest))]
            Error(_) -> []
          }
        Error(_) -> []
      }
      #(list.append(acc, list.append(gets, [op, ..stores])), counter)
    })
  let #(gets, repl, counter) =
    block_reads(ir.term_reads(term), field_slots, by_name, counter)
  let term = rewrite_term(term, repl)
  #(ir.Block(label, list.append(ops, gets), term), counter)
}

fn read_field(operand, field_slots, by_name, counter) {
  case operand {
    ir.Var(name) ->
      case dict.get(field_slots, name) {
        Ok(slot) -> {
          let temp = "__frg_" <> int.to_string(counter)
          let ty = case dict.get(by_name, name) {
            Ok(t) -> t
            Error(_) -> TNil
          }
          Ok(#(
            name,
            temp,
            ir.OpFrameGet(temp, ir.Var(frame_local), slot, ty),
            counter + 1,
          ))
        }
        Error(_) -> Error(Nil)
      }
    ir.Lit(_) -> Error(Nil)
  }
}

fn block_reads(reads, field_slots, by_name, counter) {
  list.fold(reads, #([], dict.new(), counter), fn(state, operand) {
    let #(gets, repl, counter) = state
    case read_field(operand, field_slots, by_name, counter) {
      Ok(#(name, temp, get, next)) ->
        #(list.append(gets, [get]), dict.insert(repl, name, temp), next)
      Error(_) -> state
    }
  })
}

fn rewrite_op(op: ir.Op, repl) -> ir.Op {
  case op {
    ir.OpBinop(d, o, l, r) -> ir.OpBinop(d, o, sub(l, repl), sub(r, repl))
    ir.OpUnop(d, o, x) -> ir.OpUnop(d, o, sub(x, repl))
    ir.OpCall(d, f, args, rt) -> ir.OpCall(d, f, subs(args, repl), rt)
    ir.OpBuiltin(d, n, args, rt) -> ir.OpBuiltin(d, n, subs(args, repl), rt)
    ir.OpTuple(d, elems, ty) -> ir.OpTuple(d, subs(elems, repl), ty)
    ir.OpBitArray(d, elems, ty) -> ir.OpBitArray(d, subs(elems, repl), ty)
    ir.OpTupleGet(d, t, i, ty) -> ir.OpTupleGet(d, sub(t, repl), i, ty)
    ir.OpCtor(d, c, tn, args, ty) -> ir.OpCtor(d, c, tn, subs(args, repl), ty)
    ir.OpTagIs(d, s, c, tn) -> ir.OpTagIs(d, sub(s, repl), c, tn)
    ir.OpField(d, s, c, i, ty) -> ir.OpField(d, sub(s, repl), c, i, ty)
    ir.OpCopy(d, s, ty) -> ir.OpCopy(d, sub(s, repl), ty)
    ir.OpCallIndirect(d, f, args, rt) ->
      ir.OpCallIndirect(d, sub(f, repl), subs(args, repl), rt)
    ir.OpSuspend(d, fut, resume) -> ir.OpSuspend(d, sub(fut, repl), resume)
    _ -> op
  }
}

fn rewrite_term(term: ir.Terminator, repl) -> ir.Terminator {
  case term {
    ir.Branch(c, t, o) -> ir.Branch(sub(c, repl), t, o)
    ir.Ret(v) -> ir.Ret(sub(v, repl))
    ir.Tailcall(f, args) -> ir.Tailcall(f, subs(args, repl))
    ir.TailcallIndirect(f, args) ->
      ir.TailcallIndirect(sub(f, repl), subs(args, repl))
    _ -> term
  }
}

fn sub(operand: ir.Operand, repl) -> ir.Operand {
  case operand {
    ir.Var(n) ->
      case dict.get(repl, n) {
        Ok(temp) -> ir.Var(temp)
        Error(_) -> operand
      }
    ir.Lit(_) -> operand
  }
}

fn subs(args: List(ir.Operand), repl) -> List(ir.Operand) {
  list.map(args, fn(a) { sub(a, repl) })
}

/// Variables captured by a closure created inside `function`.
pub fn captured_vars(function: ir.Function) -> List(String) {
  let ir.Function(_, _, _, blocks, _) = function
  let names =
    list.flat_map(blocks, fn(block) {
      let ir.Block(_, ops, _) = block
      list.flat_map(ops, fn(op) {
        case op {
          ir.OpClosure(_, _, captures, _, _) ->
            list.filter_map(captures, fn(operand) {
              case operand {
                ir.Var(name) -> Ok(name)
                ir.Lit(_) -> Error(Nil)
              }
            })
          _ -> []
        }
      })
    })
  dedupe(names)
}

/// Variables live at a suspension point: if the stack cannot be trusted when
/// control yields, these are the locals that must live in the frame.
pub fn suspend_live_vars(function: ir.Function) -> List(String) {
  let ir.Function(_, _, _, blocks, _) = function
  let live_out = live_out_map(blocks)
  let names =
    list.flat_map(blocks, fn(block) {
      let ir.Block(label, ops, _) = block
      let ir.Block(_, _, term) = block
      let base = case dict.get(live_out, label) {
        Ok(found) -> found
        Error(_) -> dict.new()
      }
      let base = list.fold(ir.term_reads(term), base, add_read)
      // Walk the ops backwards; every `OpSuspend` records the live set at that
      // point (uses after it, plus everything live out of the block).
      let #(_, acc) =
        list.fold(list.reverse(ops), #(base, []), fn(state, op) {
          let #(live, acc) = state
          let acc = case op {
            ir.OpSuspend(_, _, _) -> list.append(set_keys(live), acc)
            _ -> acc
          }
          #(op_transfer(live, op), acc)
        })
      acc
    })
  dedupe(names)
}

/// The frame fields of `function`: captured variables plus variables live at a
/// suspension.
pub fn frame_field_names(function: ir.Function) -> List(String) {
  dedupe(
    list.append(captured_vars(function), suspend_live_vars(function)),
  )
}

// ---------------------------------------------------------------------------
// local liveness (backward, per block over the IR CFG)
// ---------------------------------------------------------------------------

fn live_set() -> Dict(String, Bool) {
  dict.new()
}

fn live_out_map(blocks: List(ir.Block)) -> Dict(String, Dict(String, Bool)) {
  let initial = list.fold(blocks, dict.new(), fn(acc, block) {
    let ir.Block(label, _, _) = block
    dict.insert(acc, label, live_set())
  })
  fixpoint(blocks, initial)
}

fn fixpoint(
  blocks: List(ir.Block),
  live_out: Dict(String, Dict(String, Bool)),
) -> Dict(String, Dict(String, Bool)) {
  let #(next, changed) =
    list.fold(blocks, #(dict.new(), False), fn(acc, block) {
      let #(result, changed) = acc
      let ir.Block(label, _, term) = block
      let succs = successors(term)
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
      #(
        dict.insert(result, label, out),
        changed || !dict_equal(previous, out),
      )
    })
  case changed {
    True -> fixpoint(blocks, next)
    False -> live_out
  }
}

fn successors(term: ir.Terminator) -> List(String) {
  case term {
    ir.Jmp(label) -> [label]
    ir.Branch(_, then, otherwise) -> [then, otherwise]
    _ -> []
  }
}

fn op_transfer(live: Dict(String, Bool), op: ir.Op) -> Dict(String, Bool) {
  let live = list.fold(ir.op_reads(op), live, add_read)
  case ir.op_dest(op) {
    Ok(dest) -> dict.delete(live, dest)
    Error(_) -> live
  }
}

fn add_read(live: Dict(String, Bool), operand: ir.Operand) -> Dict(String, Bool) {
  case operand {
    ir.Var(name) -> dict.insert(live, name, True)
    ir.Lit(_) -> live
  }
}

fn dict_equal(a: Dict(String, Bool), b: Dict(String, Bool)) -> Bool {
  dict.size(a) == dict.size(b)
  && list.all(dict.to_list(a), fn(entry) {
    let #(key, _) = entry
    dict.has_key(b, key)
  })
}

fn set_keys(set: Dict(String, Bool)) -> List(String) {
  dict.keys(set)
}

fn dedupe(names: List(String)) -> List(String) {
  names
  |> list.fold(dict.new(), fn(acc, name) { dict.insert(acc, name, True) })
  |> dict.keys
}
