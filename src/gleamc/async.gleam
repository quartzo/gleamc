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
import gleam/result
import gleam/string
import gleamc/ast.{TNamed}
import gleamc/ir

/// Applies the asyncness analysis and the call rewrite to every function.
pub fn normalize(module: ir.Module) -> ir.Module {
  let ir.Module(functions) = module
  // A call through a local bound to a bare named function — `__gv_<name>`, or
  // the eta-expanded `__lambda_<n>` forwarder mono emits for `let f = g` — is
  // really a direct call, so rewrite it first: the asyncness fixpoint can then
  // see it and propagate through it.
  let forwarders = forwarder_map(functions)
  let functions =
    list.map(functions, fn(function) {
      devirtualize_function(function, forwarders)
    })
  // Specialise higher-order helpers per known callback so the fixpoint can see
  // through `use` / `result.try` and friends.
  let functions = specialize(functions)
  let asyncs = async_functions(functions)
  ir.Module(
    list.map(functions, fn(function) { normalize_function(function, asyncs) }),
  )
}

// ---------------------------------------------------------------------------
// devirtualization
// ---------------------------------------------------------------------------

/// Maps an eta-expanded forwarder closure (`Gleamc___lambda_<n>`) to the
/// function `g` it just calls with its own parameters.
fn forwarder_map(functions: List(ir.Function)) -> Dict(String, String) {
  list.fold(functions, dict.new(), fn(acc, function) {
    let ir.Function(name, params, _, blocks, _) = function
    case string.starts_with(name, "__lambda_") {
      True ->
        case forwarder_target(params, blocks) {
          Ok(target) -> dict.insert(acc, "Gleamc_" <> name, target)
          Error(_) -> acc
        }
      False -> acc
    }
  })
}

fn forwarder_target(params, blocks) -> Result(String, Nil) {
  case blocks {
    [ir.Block(_, [], ir.Tailcall(target, args))] -> {
      let forwarded = list.filter(params, fn(p) { p != "__env" })
      case operand_names(args) == forwarded {
        True -> Ok(target)
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn operand_names(operands) -> List(String) {
  list.filter_map(operands, fn(operand) {
    case operand {
      ir.Var(name) -> Ok(name)
      ir.Lit(_) -> Error(Nil)
    }
  })
}

/// Rewrites `f(x)` (an indirect call) into `target(x)` when the local `f` is
/// only ever bound to a closure with no captures whose target is known (a bare
/// named function, or a forwarder). The closure's environment is null, so the
/// direct call is equivalent.
fn devirtualize_function(
  function: ir.Function,
  forwarders: Dict(String, String),
) -> ir.Function {
  let ir.Function(name, params, ret, blocks, locals) = function
  let targets = resolve_targets(blocks, forwarders)
  case dict.size(targets) {
    0 -> function
    _ -> {
      let blocks =
        list.map(blocks, fn(block) {
          let ir.Block(label, ops, term) = block
          let ops = list.map(ops, fn(op) { devirt_op(op, targets) })
          ir.Block(label, ops, devirt_term(term, targets))
        })
      ir.Function(name, params, ret, blocks, locals)
    }
  }
}

/// Maps each local to the single named function it can hold, if unique.
fn resolve_targets(blocks, forwarders) -> Dict(String, String) {
  let sets =
    list.fold(blocks, dict.new(), fn(acc, block) {
      let ir.Block(_, ops, _) = block
      list.fold(ops, acc, fn(acc, op) {
        case op {
          ir.OpClosure(dest, code, [], _, _) ->
            case target_of(code, forwarders) {
              Ok(fn_name) -> add_target(acc, dest, fn_name)
              Error(_) -> acc
            }
          _ -> acc
        }
      })
    })
  let copies =
    list.flat_map(blocks, fn(block) {
      let ir.Block(_, ops, _) = block
      list.filter_map(ops, fn(op) {
        case op {
          ir.OpCopy(dest, ir.Var(src), _) -> Ok(#(dest, src))
          _ -> Error(Nil)
        }
      })
    })
  let sets = grow_targets(copies, sets)
  dict.from_list(
    list.filter_map(dict.to_list(sets), fn(entry) {
      let #(local, targets) = entry
      case targets {
        [only] -> Ok(#(local, only))
        _ -> Error(Nil)
      }
    }),
  )
}

fn add_target(sets, local, target) {
  let existing = result.unwrap(dict.get(sets, local), [])
  case list.contains(existing, target) {
    True -> sets
    False -> dict.insert(sets, local, [target, ..existing])
  }
}

fn grow_targets(copies, sets) {
  let #(next, changed) =
    list.fold(copies, #(sets, False), fn(acc, copy) {
      let #(acc_sets, changed) = acc
      let #(dest, src) = copy
      let src_targets = result.unwrap(dict.get(acc_sets, src), [])
      let dest_targets = result.unwrap(dict.get(acc_sets, dest), [])
      let merged = union(dest_targets, src_targets)
      case list.length(merged) == list.length(dest_targets) {
        True -> #(acc_sets, changed)
        False -> #(dict.insert(acc_sets, dest, merged), True)
      }
    })
  case changed {
    True -> grow_targets(copies, next)
    False -> next
  }
}

fn union(a: List(String), b: List(String)) -> List(String) {
  list.fold(b, a, fn(acc, item) {
    case list.contains(acc, item) {
      True -> acc
      False -> [item, ..acc]
    }
  })
}

/// The function a closure `code` forwards to, if it is a bare named function
/// (`__gv_<name>`) or a known eta-expansion forwarder.
fn target_of(code: String, forwarders) -> Result(String, Nil) {
  case string.starts_with(code, "__gv_") {
    True -> Ok(string.drop_start(code, 5))
    False -> dict.get(forwarders, code)
  }
}

fn devirt_op(op: ir.Op, targets: Dict(String, String)) -> ir.Op {
  case op {
    ir.OpCallIndirect(dest, ir.Var(local), args, ty) ->
      case dict.get(targets, local) {
        Ok(fn_name) -> ir.OpCall(dest, fn_name, args, ty)
        Error(_) -> op
      }
    _ -> op
  }
}

fn devirt_term(
  term: ir.Terminator,
  targets: Dict(String, String),
) -> ir.Terminator {
  case term {
    ir.TailcallIndirect(ir.Var(local), args) ->
      case dict.get(targets, local) {
        Ok(fn_name) -> ir.Tailcall(fn_name, args)
        Error(_) -> term
      }
    _ -> term
  }
}

// ---------------------------------------------------------------------------
// higher-order specialization
// ---------------------------------------------------------------------------

/// Rewrites a direct call to a higher-order function whose callback argument is
/// a known closure into a call to a clone of that function where the callback
/// is called directly (passing the closure's environment). This lets the
/// asyncness fixpoint see through `use` / `result.try` and similar helpers.
fn specialize(functions: List(ir.Function)) -> List(ir.Function) {
  let indirect =
    list.fold(functions, dict.new(), fn(acc, function) {
      case indirect_params(function) {
        [] -> acc
        indices -> dict.insert(acc, function.name, indices)
      }
    })
  case dict.size(indirect) {
    0 -> functions
    _ -> {
      let by_name = dict.from_list(list.map(functions, fn(f) { #(f.name, f) }))
      let #(rewritten, clones, _) =
        list.fold(functions, #([], dict.new(), 0), fn(acc, function) {
          let #(out, clones, counter) = acc
          let #(function, clones, counter) =
            specialize_function(function, by_name, indirect, clones, counter)
          #([function, ..out], clones, counter)
        })
      let clones =
        list.map(dict.values(clones), fn(entry) {
          let #(_, function) = entry
          function
        })
      list.append(list.reverse(rewritten), clones)
    }
  }
}

/// The parameter positions a function calls indirectly.
fn indirect_params(function: ir.Function) -> List(Int) {
  let ir.Function(_, params, _, blocks, _) = function
  list.fold(blocks, [], fn(acc, block) {
    let ir.Block(_, ops, term) = block
    let acc =
      list.fold(ops, acc, fn(acc, op) {
        case op {
          ir.OpCallIndirect(_, ir.Var(p), _, _) -> add_index(acc, params, p)
          _ -> acc
        }
      })
    case term {
      ir.TailcallIndirect(ir.Var(p), _) -> add_index(acc, params, p)
      _ -> acc
    }
  })
}

fn add_index(acc, params, name) {
  case param_index(params, name) {
    Ok(i) ->
      case list.contains(acc, i) {
        True -> acc
        False -> [i, ..acc]
      }
    Error(_) -> acc
  }
}

fn param_index(params, name) -> Result(Int, Nil) {
  param_index_loop(params, name, 0)
}

fn param_index_loop(params, name, i) {
  case params {
    [] -> Error(Nil)
    [p, ..rest] ->
      case p == name {
        True -> Ok(i)
        False -> param_index_loop(rest, name, i + 1)
      }
  }
}

fn specialize_function(function, by_name, indirect, clones, counter) {
  let ir.Function(name, params, ret, blocks, locals) = function
  let closures = resolve_closures(blocks)
  let #(blocks, clones, counter, extras) =
    list.fold(blocks, #([], clones, counter, []), fn(acc, block) {
      let #(out, clones, counter, extras) = acc
      let #(block, clones, counter, extra) =
        specialize_block(block, closures, by_name, indirect, clones, counter)
      #([block, ..out], clones, counter, list.append(extra, extras))
    })
  #(
    ir.Function(
      name,
      params,
      ret,
      list.reverse(blocks),
      list.append(locals, extras),
    ),
    clones,
    counter,
  )
}

fn specialize_block(block, closures, by_name, indirect, clones, counter) {
  let ir.Block(label, ops, term) = block
  let #(ops, clones, counter, extras) =
    list.fold(ops, #([], clones, counter, []), fn(acc, op) {
      let #(out, clones, counter, extras) = acc
      let #(op, extras2, clones, counter) =
        specialize_op(op, closures, by_name, indirect, clones, counter)
      #(list.append(out, [op]), clones, counter, list.append(extras, extras2))
    })
  #(ir.Block(label, ops, term), clones, counter, extras)
}

/// A direct call to a known higher-order function with a known closure argument
/// becomes a call to a specialized clone.
fn specialize_op(op, closures, by_name, indirect, clones, counter) {
  case op {
    ir.OpCall(dest, g, args, ret) ->
      case dict.get(indirect, g) {
        Ok(indices) ->
          case find_specializable(args, indices, closures) {
            Ok(#(index, code)) -> {
              let #(clone_name, clones, counter) =
                get_clone(g, index, code, by_name, clones, counter)
              #(ir.OpCall(dest, clone_name, args, ret), [], clones, counter)
            }
            Error(_) -> #(op, [], clones, counter)
          }
        Error(_) -> #(op, [], clones, counter)
      }
    _ -> #(op, [], clones, counter)
  }
}

/// The first callback argument that is a known closure.
fn find_specializable(args, indices, closures) -> Result(#(Int, String), Nil) {
  case indices {
    [] -> Error(Nil)
    [index, ..rest] ->
      case list_nth(args, index) {
        Ok(ir.Var(v)) ->
          case dict.get(closures, v) {
            Ok(#(code, _env_ty)) -> Ok(#(index, code))
            Error(_) -> find_specializable(args, rest, closures)
          }
        _ -> find_specializable(args, rest, closures)
      }
  }
}

fn get_clone(g, index, code, by_name, clones, counter) {
  let key = g <> "|" <> int.to_string(index) <> "|" <> code
  case dict.get(clones, key) {
    Ok(#(name, _)) -> #(name, clones, counter)
    Error(_) -> {
      case dict.get(by_name, g) {
        Ok(function) -> {
          let name = g <> "__di" <> int.to_string(counter)
          let clone = make_clone(function, index, code, name, counter)
          #(name, dict.insert(clones, key, #(name, clone)), counter + 1)
        }
        Error(_) -> #(g, clones, counter)
      }
    }
  }
}

/// A copy of `function` with indirect calls through parameter `index` replaced
/// by direct calls to `code` (carrying the closure's environment).
fn make_clone(function, index, code, name, counter) {
  let ir.Function(original, params, ret, blocks, locals) = function
  let target = case list_nth(params, index) {
    Ok(t) -> t
    Error(_) -> ""
  }
  let #(code_name, bare) = closure_code_name(code)
  let #(blocks, extras, _) =
    list.fold(blocks, #([], [], counter), fn(acc, block) {
      let #(out, extras, counter) = acc
      let ir.Block(label, ops, term) = block
      let #(ops, term, extra, counter) =
        clone_block(ops, term, target, code_name, bare, original, name, counter)
      #(
        [ir.Block(label, ops, term), ..out],
        list.append(extra, extras),
        counter,
      )
    })
  ir.Function(
    name,
    params,
    ret,
    list.reverse(blocks),
    list.append(locals, extras),
  )
}

fn clone_block(
  ops,
  term,
  target,
  code_name,
  bare,
  original,
  clone_name,
  counter,
) {
  let #(ops, extra, counter) =
    list.fold(ops, #([], [], counter), fn(acc, op) {
      let #(out, extra, counter) = acc
      case op {
        // A self-call inside the specialised clone recurses into the clone, so
        // every iteration keeps the callback direct.
        ir.OpCall(dest, g, args, ret) if g == original -> #(
          list.append(out, [ir.OpCall(dest, clone_name, args, ret)]),
          extra,
          counter,
        )
        ir.OpCallIndirect(dest, ir.Var(p), args, ret) if p == target -> {
          case bare {
            True -> #(
              list.append(out, [ir.OpCall(dest, code_name, args, ret)]),
              extra,
              counter,
            )
            False -> {
              let env = "__dienv" <> int.to_string(counter)
              #(
                list.append(out, [
                  ir.OpClosureEnv(env, ir.Var(p), TNamed("void*")),
                  ir.OpCall(dest, code_name, [ir.Var(env), ..args], ret),
                ]),
                [ir.Local(env, TNamed("void*"), ir.Slot), ..extra],
                counter + 1,
              )
            }
          }
        }
        _ -> #(list.append(out, [op]), extra, counter)
      }
    })
  case term {
    ir.Tailcall(g, args) if g == original -> #(
      ops,
      ir.Tailcall(clone_name, args),
      extra,
      counter,
    )
    ir.TailcallIndirect(ir.Var(p), args) if p == target ->
      case bare {
        True -> #(ops, ir.Tailcall(code_name, args), extra, counter)
        False -> {
          let env = "__dienv" <> int.to_string(counter)
          #(
            list.append(ops, [
              ir.OpClosureEnv(env, ir.Var(p), TNamed("void*")),
            ]),
            ir.Tailcall(code_name, [ir.Var(env), ..args]),
            [ir.Local(env, TNamed("void*"), ir.Slot), ..extra],
            counter + 1,
          )
        }
      }
    _ -> #(ops, term, extra, counter)
  }
}

/// The IR function name a closure `code` refers to, and whether it has no
/// environment (`__gv_` bare functions).
fn closure_code_name(code: String) -> #(String, Bool) {
  case string.starts_with(code, "__gv_") {
    True -> #(string.drop_start(code, 5), True)
    False ->
      case string.starts_with(code, "Gleamc_") {
        True -> #(string.drop_start(code, 7), False)
        False -> #(code, False)
      }
  }
}

/// Maps each local to the single closure it can hold, if unique.
fn resolve_closures(blocks) -> Dict(String, #(String, String)) {
  let sets =
    list.fold(blocks, dict.new(), fn(acc, block) {
      let ir.Block(_, ops, _) = block
      list.fold(ops, acc, fn(acc, op) {
        case op {
          ir.OpClosure(dest, code, _, env_ty, _) ->
            add_closure(acc, dest, code, env_ty)
          _ -> acc
        }
      })
    })
  let copies =
    list.flat_map(blocks, fn(block) {
      let ir.Block(_, ops, _) = block
      list.filter_map(ops, fn(op) {
        case op {
          ir.OpCopy(dest, ir.Var(src), _) -> Ok(#(dest, src))
          _ -> Error(Nil)
        }
      })
    })
  let sets = grow_closures(copies, sets)
  dict.from_list(
    list.filter_map(dict.to_list(sets), fn(entry) {
      let #(local, closures) = entry
      case closures {
        [only] -> Ok(#(local, only))
        _ -> Error(Nil)
      }
    }),
  )
}

fn add_closure(sets, local, code, env_ty) {
  let existing = result.unwrap(dict.get(sets, local), [])
  let item = #(code, env_ty)
  case list.contains(existing, item) {
    True -> sets
    False -> dict.insert(sets, local, [item, ..existing])
  }
}

fn grow_closures(copies, sets) {
  let #(next, changed) =
    list.fold(copies, #(sets, False), fn(acc, copy) {
      let #(acc_sets, changed) = acc
      let #(dest, src) = copy
      let src_closures = result.unwrap(dict.get(acc_sets, src), [])
      let dest_closures = result.unwrap(dict.get(acc_sets, dest), [])
      let merged = union_closures(dest_closures, src_closures)
      case list.length(merged) == list.length(dest_closures) {
        True -> #(acc_sets, changed)
        False -> #(dict.insert(acc_sets, dest, merged), True)
      }
    })
  case changed {
    True -> grow_closures(copies, next)
    False -> next
  }
}

fn union_closures(a, b) {
  list.fold(b, a, fn(acc, item) {
    case list.contains(acc, item) {
      True -> acc
      False -> [item, ..acc]
    }
  })
}

fn list_nth(items, index) -> Result(a, Nil) {
  case items {
    [] -> Error(Nil)
    [first, ..rest] ->
      case index {
        0 -> Ok(first)
        _ -> list_nth(rest, index - 1)
      }
  }
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

/// A real suspension awaiting something external (`time.timer`, `uv.fs_*`) or a
/// boxed mailbox/task value (`process.receive`, `task.await`). `Machine` is the
/// mode the async pass itself emits, so it does not count here.
fn has_host_suspend(function: ir.Function) -> Bool {
  let ir.Function(_, _, _, blocks, _) = function
  list.any(blocks, fn(block) {
    case block.term {
      ir.Suspend(_, _, _, ir.Host) -> True
      ir.Suspend(_, _, _, ir.Boxed) -> True
      ir.Suspend(_, _, _, ir.BoxedBorrow) -> True
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
                  ir.Suspend(ir.Var(fut), dest, resume, ir.Machine),
                )
              let #(more, locals, counter) =
                normalize_ops(rest, term, ret, asyncs, locals, counter, resume)
              #([this, ..more], locals, counter)
            }
            False ->
              prepend_op(op, rest, term, ret, asyncs, locals, counter, label)
          }
        _ -> prepend_op(op, rest, term, ret, asyncs, locals, counter, label)
      }
  }
}

fn prepend_op(op, rest, term, ret, asyncs, locals, counter, label) {
  let #(blocks, locals, counter) =
    normalize_ops(rest, term, ret, asyncs, locals, counter, label)
  case blocks {
    [ir.Block(first, first_ops, first_term), ..more] -> #(
      [ir.Block(first, [op, ..first_ops], first_term), ..more],
      locals,
      counter,
    )
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
        True -> #(
          [ir.Block(label, [], ir.TailMachine(fun, args))],
          locals,
          counter,
        )
        False -> #([ir.Block(label, [], term)], locals, counter)
      }
    _ -> #([ir.Block(label, [], term)], locals, counter)
  }
}

fn fresh_local(prefix, ty, locals, counter) {
  let name = prefix <> int.to_string(counter)
  #(name, [ir.Local(name, ty, ir.Slot), ..locals], counter + 1)
}
