# Frame as environment (design)

**Status: implemented.** The closure environment (`__env`) is gone: the function
**frame** is the environment. This document records the design and the
responsibilities/artifacts of each layer.

## The frame

A frame is a **composite, reference-counted heap cell** for a function. It holds
the variables that must survive a point where the native stack cannot be trusted:

> a variable belongs in the frame **if and only if** it is **captured by a
> closure** or **live across a suspension** (`OpSuspend`).

Today only captures matter: async is still lowered inline (see
[machine.md](machine.md)), so a suspension does not unwind the stack and is not
part of frame membership. The `suspend_live_vars` rule is already implemented
and returns to duty when the async state machine is restored.

Everything else — parameters and temporaries that are neither captured nor live
across a suspension — stays a plain IR local. The rule is uniform over
parameters and locals.

## Layers

- `frame.materialize` (between `lower` and `ownership`) determines membership
  (`frame.machine_functions`: functions with a capturing closure, or with a
  suspension once async is restored), adds `OpFrameNew` at the entry of every
  such function, and marks every capturing closure as a frame capture (`env_ty`
  names the defining frame).
- `ownership` sees the frame value as a handle: a capturing closure retains it
  (`OpClosure`), and the machine releases its own reference at every exit
  (`OpDrop(frame)`, emitted at `Ret` and at tail calls).
- The backend renders `OpFrameNew` as a `gleamc_alloc0` cell, field get/set as
  GEP/load/store, and `OpDrop(frame)` as a call to the generated
  `@__frame_<fn>_drop` teardown.
- There is no dispatcher and no mutual tail-call group: tail calls are
  `musttail` calls ([tco-musttail-plan.md](tco-musttail-plan.md)). A capture
  function that tail-calls releases its frame before the call and the `musttail`
  call is immediately followed by its `ret`.

## Motivation (kept)

The old design copied captured variables into an `__Env_*` heap box with its own
`env_drop`. That hid the captured values from `ownership` (it saw only
`OpClosure` operands and opaque `OpEnvGet`), and a function value moved through
a tail/indirect call leaked the box. Making the frame the environment makes the
captured values ordinary frame fields that `ownership` schedules, and the frame
teardown an ordinary composite drop.

## Validation

- `use_test.use_desugar_test` prints `live blocks = 0`; `use_pattern_test`
  passes.
- A lambda returned from a function (`fn make(s) { fn() { s } }`) runs after its
  defining function returned, without dangling or leaking.
- Nested captures read the right values.
- Constant-stack recursion holds (`count(1_000_000)`, mutual recursion).
- `gleam test` is green and `scripts/diff.sh` matches the official toolchain.
