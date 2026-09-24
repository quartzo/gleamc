# Frame as environment (design)

**Status: implemented.** The closure environment (`__env`) is gone: the function
**frame** is the environment. This document records the design and the
responsibilities/artifacts of each layer, so the change respects the cascade
([cascade.md](cascade.md)).

Implemented:

- `frame.materialize` (between `lower` and `ownership`) adds `OpFrameNew` at the
  entry of every machine function and marks every capturing closure as a frame
  capture (`env_ty` names the defining frame).
- `ownership` retains the frame for a capturing closure and the machine's own
  reference at exits; **frame-claim**: the frame owns its kept-alive fields
  (captured or live across a suspension), so `ownership` does not emit flow
  drops for them.
- The backend generates a frame teardown per frame type (`@__frame_<fn>_drop`)
  that drops the frame-owned fields at refcount 1->0, and calls it at the
  machine boundary (wrapper) or the dispatcher return.
- Mutual tail-call **groups** are unified with the machine: every dispatcher
  member has its own heap frame (`%__fr_m<idx>`), so a member's frame is a
  capturable environment and TCO still holds.
- The generated IR contains no `__Env_*` type and no `env_drop`.

## Motivation

Today a lifted lambda copies its captured variables into an `__Env_*` heap box
that has its own reference count and a hidden `env_drop` teardown. A function
value is `{code, env, env_drop}`.

Two problems follow:

- `ownership` never sees the captured values: it sees "the operands of
  `OpClosure` are owning" and `OpEnvGet` as opaque.
- When a function value is moved through a tail or indirect call, the callee
  receives only the environment pointer, and the box is not released by anyone.
  This is the `use` leak (`live blocks = 1`).

## The frame

A frame is a **composite, reference-counted type** for a function. It holds the
variables that must survive a point where the stack cannot be trusted:

> a variable belongs in the frame **if and only if** it is **captured by a
> closure** or **live across a suspension** (`OpSuspend`).

Everything else — parameters and temporaries that are neither captured nor live
across a suspension — stays a plain IR local (register/stack). The rule is
uniform over parameters and locals.

There is **no bespoke frame teardown**: releasing a frame is the normal drop of
a composite type, which drops its fields (the same generated glue used for
structs). The frame is not a special mechanism; it is the function's saved state.

Two kinds of "jump" are distinguished:

- a tail call inside a mutual group is a `br` to another member's entry in the
  **same** dispatcher frame — the frame is preserved, so no frame variable is
  needed;
- a suspension (CPS) returns control and cannot rely on the stack; anything live
  there goes to the frame. `spawn` already transfers the task frame to the
  scheduler, so spawned frames are already heap.

## Execution plan

### New pass: `frame.gleam` (lowering, between `lower` and `ownership`)

Input: plain IR (after `lower`). Output: IR with the frame materialized as a
value. It is the only new pass.

1. Determine machine functions using the shared membership rule
   `plan.machines(module)` (functions with `OpSuspend`; captures will be added
   when lambda lifting switches over).
2. Compute the frame field set: variables captured by a closure, plus variables
   live at an `OpSuspend`. The suspension points are already explicit, so this
   is a local liveness query — no interprocedural analysis.
3. Materialize the frame:
   - define the frame value at the function entry (`OpFrameNew` of the
     function's frame type);
   - rewrite each field variable: it stops being a plain local and becomes a
     frame field; reads become field gets, writes become field sets;
   - the frame type is a named composite (`__Frame_<fn>`) with those fields.
4. Leave every other local untouched.

The pass changes no retain/drop and no tail call.

### `ownership` (IR → IR)

- Sees the frame value as a handle: schedules `OpRetain`/`OpDrop` for it.
- The frame's fields are dropped by the frame's composite drop glue, not by
  flow drops; `ownership` must therefore not emit drops for the field variables
  separately.
- A closure that captures the frame retains it (`OpClosure`).
- Remains the **sole** producer of `OpRetain`/`OpDrop`.

### `cps` (IR → IR)

Unchanged in responsibility: split blocks at `OpSuspend`. It now operates on an
IR where the frame fields are already material, which is exactly the state that
must survive a suspension.

### `plan` (IR → Plan)

- Owns machine membership (`plan.machines`), already consumed by the backend.
- `plan.Frame` describes the frame fields (captured ∪ suspend-live) instead of
  every local.

### Backend

- `llvm.gleam`: `OpFrameNew` allocates the frame with `gleamc_alloc`; field
  get/set lower to GEP/load/store; `OpDrop(frame)` lowers to the generated
  `Gleamc_Rc_drop_<frame>`; the machine `_step`/wrapper operate on the frame
  value. The backend renders the abstract frame concept, it does not invent
  ownership.

### Removed

- `__Env_*`, `env_drop`, and `OpEnvGet` over a copied box become the frame and
  field get/set.
- `EEnvGet`/`__env` in `mono`/`lower` become frame-field accesses; the closure
  references the defining frame; the callee materializes captures from it.

## Artifacts (for diagnosis)

| Stage | Artifact |
|---|---|
| after `frame` | IR (not yet dumpable; add to `--ir` when the pass lands) |
| after `ownership` | `--ir` dump |
| plan | `plan.to_text` (frames now list the frame fields) |
| LLVM IR | `gleam run -- <file>` (writes `<file>.ll`) |

## Validation

- `use_test.use_desugar_test` prints `live blocks = 0`; `use_pattern_test`
  passes.
- A lambda returned from a function (`fn make(s) { fn() { s } }`) runs after its
  defining function returned, without dangling or leaking.
- Nested captures (`outer`/`mid`/`inner`) read the right values.
- Constant-stack recursion still holds (`loop(1_000_000)`).
- `gleam test` is green and `scripts/diff.sh` matches the official toolchain.
- The generated IR contains no `__Env_*` type and no `env_drop` field.

## Ordering of work

1. `frame.gleam`: membership + field-set analysis + materialization (unchanged
   semantics, no closure capture yet), so the frame exists as a value. Tests
   stay green.
2. `ownership`: retain/drop the frame; stop flow-dropping frame fields.
3. Backends: lower `OpFrameNew`/field get/set/`OpDrop(frame)`; LLVM heap + rc,
   C inline.
4. `mono`/`lower`: closures reference the defining frame; captures become frame
   fields; the callee materializes them.
5. Remove `__Env_*`/`env_drop`/`OpEnvGet` and the `__env` parameter.
6. Re-check the owned ABI clone (`owned_clone.gleam`) against the frame handle.
