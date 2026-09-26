//// Ownership pass (M6): a direct port of Vesper's `ir_ownership.insert`.
////
//// Model: every handle local owns one reference. At an owning use the
//// argument is moved (if it is the last use) or retained (if still live);
//// ownership liveness then decides where each local dies, emitting a drop
//// at block exit. This is the deterministic refcount mechanism: no GC, and
//// the generated C shows every retain/release.
////
//// The decision logic lives in `ownership_plan` (analysis); this module only
//// applies the plan, inserting the `OpRetain`/`OpDrop` ops. Keeping the two
//// apart makes the move/borrow analysis testable on its own.

import gleam/dict.{type Dict}
import gleam/list
import gleam/string
import gleamc/ast.{type Type, TNamed}
import gleamc/borrow
import gleamc/checker
import gleamc/ffi_modes
import gleamc/frame
import gleamc/ir
import gleamc/owned_clone
import gleamc/ownership_plan.{type Plan}

pub fn insert(
  module: ir.Module,
  ctors: Dict(String, checker.CtorInfo),
) -> ir.Module {
  let modes = borrow.analyze(module)
  // `type_fields`/`recursive_types` are module-wide; compute them once instead
  // of rebuilding them on every `needs_drop` call (once per local per function).
  let fields_of = type_fields(ctors)
  let recursive = recursive_types(ctors)
  // Type name -> number of variants, used to restrict the extraction move-out
  // to single-variant (struct) containers.
  let variant_count =
    dict.fold(ctors, dict.new(), fn(acc, _ctor, info) {
      let checker.CtorInfo(type_name, _) = info
      let n = case dict.get(acc, type_name) {
        Ok(found) -> found
        Error(_) -> 0
      }
      dict.insert(acc, type_name, n + 1)
    })
  // Tail/indirect call sites use the `Owned` ABI; give those functions an
  // all-`Owned` clone so ordinary calls keep the natural modes. Only handle
  // parameters make the distinction observable, so scalar-only functions are
  // left alone.
  let is_handle = fn(ty) { needs_drop_in(ty, fields_of, recursive) }
  let #(module, modes) = owned_clone.apply(module, modes, is_handle)
  let ir.Module(functions) = module
  let machines = frame.machine_functions(module)
  let ffi = ffi_modes.table()
  ir.Module(
    list.map(functions, fn(function) {
      let owned =
        insert_fn(function, fields_of, recursive, variant_count, modes, ffi)
      case list.contains(machines, function.name) {
        True -> add_frame_lifecycle(owned)
        False -> owned
      }
    }),
  )
}

// ---------------------------------------------------------------------------
// needs_drop (type-level; the decision itself lives in `ownership_plan`)
// ---------------------------------------------------------------------------

pub fn needs_drop(ty: Type, ctors: Dict(String, checker.CtorInfo)) -> Bool {
  ownership_plan.needs_drop(ty, ctors)
}

/// Like `needs_drop`, but with `fields_of`/`recursive` precomputed by the
/// caller (avoiding an O(N) `type_fields` rebuild on every call).
pub fn needs_drop_in(ty: Type, fields_of, recursive) -> Bool {
  ownership_plan.needs_drop_in(ty, fields_of, recursive)
}

/// Types that participate in a reference cycle (including self-reference).
/// Such types are heap cells with a refcount.
pub fn recursive_types(
  ctors: Dict(String, checker.CtorInfo),
) -> Dict(String, Bool) {
  ownership_plan.recursive_types(ctors)
}

/// Type name -> all field types across its variants.
pub fn type_fields(
  ctors: Dict(String, checker.CtorInfo),
) -> Dict(String, List(Type)) {
  ownership_plan.type_fields(ctors)
}

// ---------------------------------------------------------------------------
// per-function pass: split critical edges, plan, apply
// ---------------------------------------------------------------------------

fn insert_fn(
  function: ir.Function,
  fields_of,
  recursive,
  variant_count,
  modes,
  ffi,
) -> ir.Function {
  let ir.Function(name, params, ret, blocks, locals) = function
  // Partial ownership at a join cannot be resolved per block: a value may be
  // owned on one incoming edge (from its definition) and not on another. Split
  // critical edges so each edge has its own block, where the dead drop lands.
  let blocks = split_critical_edges(blocks)
  let param_modes = case dict.get(modes, name) {
    Ok(found) -> found
    Error(_) -> list.map(params, fn(_) { ffi_modes.Borrow })
  }
  case
    ownership_plan.compute(
      blocks,
      params,
      locals,
      param_modes,
      fields_of,
      recursive,
      variant_count,
      modes,
      ffi,
    )
  {
    Error(_) -> function
    Ok(plan) -> ir.Function(name, params, ret, apply_plan(blocks, plan), locals)
  }
}

/// Insert the retains and drops the plan calls for, block by block.
fn apply_plan(blocks: List(ir.Block), plan: Plan) -> List(ir.Block) {
  let ownership_plan.Plan(handles, block_plans) = plan
  list.map(blocks, fn(block) {
    let bp = case dict.get(block_plans, block.label) {
      Ok(found) -> found
      Error(_) -> ownership_plan.BlockPlan(dict.new(), dict.new(), [])
    }
    let ownership_plan.BlockPlan(retains, moved_dests, drop_pairs) = bp
    let new_ops = insert_retains(block.ops, 0, retains, [])
    let new_ops = add_extract_retains(new_ops, handles, moved_dests)
    let drops =
      list.map(drop_pairs, fn(pair) {
        let #(drop_name, drop_ty) = pair
        ir.OpDrop(drop_name, drop_ty)
      })
    ir.Block(block.label, list.append(new_ops, drops), block.term)
  })
}

/// Inserts an empty block on every critical edge — a branch target that also
/// has another predecessor — so a value that dies only on that edge can be
/// dropped in the new block instead of leaking (or being dropped for a path
/// that never owned it).
fn split_critical_edges(blocks: List(ir.Block)) -> List(ir.Block) {
  let preds =
    list.fold(blocks, dict.new(), fn(acc, block) {
      list.fold(ownership_plan.successors(block.term), acc, fn(acc, succ) {
        let count = case dict.get(acc, succ) {
          Ok(found) -> found
          Error(_) -> 0
        }
        dict.insert(acc, succ, count + 1)
      })
    })
  list.flat_map(blocks, fn(block) {
    case block.term {
      ir.Branch(cond, then, otherwise) -> {
        let #(then, then_blocks) = split_edge(block.label, "t", then, preds)
        let #(otherwise, else_blocks) =
          split_edge(block.label, "f", otherwise, preds)
        [
          ir.Block(block.label, block.ops, ir.Branch(cond, then, otherwise)),
          ..list.append(then_blocks, else_blocks),
        ]
      }
      _ -> [block]
    }
  })
}

fn split_edge(from: String, tag: String, target: String, preds) {
  let count = case dict.get(preds, target) {
    Ok(found) -> found
    Error(_) -> 0
  }
  case count > 1 {
    True -> {
      let label = from <> "_ce_" <> tag
      #(label, [ir.Block(label, [], ir.Jmp(target))])
    }
    False -> #(target, [])
  }
}

fn add_extract_retains(ops, handles, moved) {
  list.flat_map(ops, fn(op) {
    case op {
      ir.OpField(dest, _, _, _, ty) -> extract_pair(op, dest, ty, handles, moved)
      ir.OpTupleGet(dest, _, _, ty) ->
        extract_pair(op, dest, ty, handles, moved)
      ir.OpEnvGet(dest, _, _, ty) -> extract_pair(op, dest, ty, handles, moved)
      ir.OpFrameGet(dest, _, _, ty) ->
        extract_pair(op, dest, ty, handles, moved)
      _ -> [op]
    }
  })
}

/// Owning extraction needs its own reference; borrow-only views were removed
/// from `handles`, so they are not retained here. A dest moved out of a
/// consumed container already owns the container's reference.
fn extract_pair(op, dest, ty, handles, moved) {
  case dict.get(moved, dest) {
    Ok(_) -> [op]
    Error(_) ->
      case dict.get(handles, dest) {
        Ok(_) -> [op, ir.OpRetain(dest, ty)]
        Error(_) -> [op]
      }
  }
}

fn insert_retains(ops, index, pre, acc) {
  // `acc` is the reverse of the output produced so far, so appending to the
  // end of the result is O(1) (per element) instead of O(n) per op.
  case ops {
    [] -> {
      let trailing = case dict.get(pre, index) {
        Ok(found) -> build_retains(found)
        Error(_) -> []
      }
      list.reverse(list.append(list.reverse(trailing), acc))
    }
    [op, ..rest] -> {
      let retains = case dict.get(pre, index) {
        Ok(found) -> build_retains(found)
        Error(_) -> []
      }
      // final order is `retains ++ [op]`, so reversed it is `[op] ++ rev(retains)`.
      let acc = list.append([op], list.append(list.reverse(retains), acc))
      insert_retains(rest, index + 1, pre, acc)
    }
  }
}

fn build_retains(pairs) {
  list.map(pairs, fn(pair) {
    let #(retain_name, retain_ty) = pair
    ir.OpRetain(retain_name, retain_ty)
  })
}

// ---------------------------------------------------------------------------
// frame lifecycle
// ---------------------------------------------------------------------------

/// The frame is an ownership-managed value. A closure that captures it takes a
/// reference (`OpRetain`); the machine releases its own reference at every exit
/// (`OpDrop`). `OpFrameNew` (rendered by the backend) is the allocation.
fn add_frame_lifecycle(function: ir.Function) -> ir.Function {
  let ir.Function(name, params, ret, blocks, locals) = function
  let ty = TNamed(frame.frame_type_name(name))
  let blocks =
    list.map(blocks, fn(block) {
      let ir.Block(label, ops, term) = block
      let ops =
        list.flat_map(ops, fn(op) {
          case is_frame_capture_op(op) {
            True -> [ir.OpRetain(frame.frame_local, ty), op]
            False -> [op]
          }
        })
      let ops = case is_exit(term) {
        True -> list.append(ops, [ir.OpDrop(frame.frame_local, ty)])
        False -> ops
      }
      ir.Block(label, ops, term)
    })
  ir.Function(name, params, ret, blocks, locals)
}

fn is_frame_capture_op(op: ir.Op) -> Bool {
  case op {
    ir.OpClosure(_, _, _, env_ty, _) -> string.starts_with(env_ty, "__frame_")
    _ -> False
  }
}

fn is_exit(term: ir.Terminator) -> Bool {
  case term {
    ir.Ret(_) | ir.Tailcall(_, _) | ir.TailcallIndirect(_, _) -> True
    _ -> False
  }
}
