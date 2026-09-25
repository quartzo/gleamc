# Frame as environment (design)

**Status: implemented.** The closure environment (`__env`) is gone: the function
**frame** is the environment. This document records the design and the
responsibilities/artifacts of each layer.

## The frame

A frame is a **composite, reference-counted heap cell** for a function. It holds
the variables that must survive a point where the native stack cannot be trusted:

> a variable belongs in the frame **if and only if** it is **captured by a
> closure**, **live across a suspension** (`ir.Suspend`), or a **parameter of a
> machine** (the wrapper / `OpMachineStart` place the arguments in the frame).

Async is a flat state machine (see [machine.md](machine.md)): a suspension
returns control to the driver, so the native stack is not trusted across it and
every variable live at a suspension lives in the frame. A machine frame also
owns its parameters, because the wrapper stores them into the frame and the
teardown releases them.

Other parameters and temporaries of a non-async function stay plain IR locals.
A capture-only frame function uses the same rule (captures only).

## Layers

- `frame.materialize` (between `lower` and `ownership`) determines membership
  (`frame.machine_functions`: a capturing closure, a suspension, or an async
  tail call), adds `OpFrameNew` at the entry of every such function, and marks
  every capturing closure as a frame capture (`env_ty` names the defining
  frame).
- `ownership` sees the frame value as a handle: a capturing closure retains it
  (`OpClosure`), and the machine releases its own reference at every exit
  (`OpDrop(frame)`, emitted at `Ret` and at async tail calls).
- The backend renders field get/set as GEP/load/store and `OpDrop(frame)` as a
  call to the generated `@__frame_<fn>_drop` teardown. `OpFrameNew` itself is a
  no-op: the cell is allocated by the machine wrapper / `OpMachineStart`.
- There is no dispatcher and no mutual tail-call group. A synchronous tail call
  is a `musttail` call ([tco-musttail-plan.md](tco-musttail-plan.md)); a capture
  function that tail-calls releases its frame before the call. An **async** tail
  call is a `TailMachine` terminator that delegates the running task to the
  callee ([machine.md](machine.md)).
- A machine's frame is owned by its driver task, which runs the teardown when
  the machine finishes or delegates. `copy_result` retains the result for the
  caller and the teardown releases the frame's own reference to it.

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
- `leak_test.leak_get_files_frame_test` reports `live blocks = 0` for a recursive
  async walk, and `gleam test` is green (`scripts/diff.sh` matches the official
  toolchain; the compiler self-compiles under an 8 MiB stack).
