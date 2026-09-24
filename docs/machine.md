# The CPS machine: tail calls and async

Recursive Gleam code that ends in a call (for example a loop written with `use`)
must run in constant stack, and asynchronous code must be able to suspend and
resume. `gleamc` implements both with one idea: some functions are compiled not
as ordinary C-style functions but as **states of a machine**, driven either by a
dispatcher (tail calls) or by the scheduler (suspension). This document describes
how those machines are planned and emitted.

## Where tail calls come from

Tail position is known during lowering, so `lower` produces the terminators:

- a call to a known function in tail position becomes `Tailcall(fun, args)`;
- a call through a function value in tail position becomes
  `TailcallIndirect(fval, args)`.

A normal call (whose result is still needed) stays an `OpCall`/`OpCallIndirect`.

## Planning the machines

`src/gleamc/plan.gleam` is a pure, deterministic planner over the owned IR. It
computes:

- **tail-call edges**: `caller -> callee` for every `Tailcall`; and for a
  `TailcallIndirect` whose function value is a statically known closure, an edge
  to the underlying function;
- **callback edges**: when a function `h` tail-calls one of its function-typed
  parameters and a call site of `h` passes a closure whose code is statically
  known, `h` may transfer control to that closure's code. This links a CPS
  combinator such as `result.try` back to the continuation its caller supplied,
  closing the tail-call cycle so it can be collapsed into direct branches;
- **mutual groups**: the strongly connected components of the tail-call graph.
  A group is a set of functions that call each other in tail position.

The planner also records each function's frame (its parameters and locals) and a
global numbering of basic-block states. It changes no IR.

## The tail-call dispatcher

`llvm.gleam` turns each mutual group into a single function — the **dispatcher**
(`emit_group`). The dispatcher:

- allocates the locals of **all** members of the group as one compound frame
  (one `alloca` per local, prefixed per member);
- switches on a member index (`%__fn`) to the selected member's prologue, which
  copies the incoming argument block into that member's slots;
- for a member-to-member tail call, stores the arguments into the callee member's
  slots and branches to its entry (`emit_rebind`) — no call, no stack growth;
- for an indirect tail call inside the dispatcher, compares the closure's code
  pointer against each member (`emit_indirect_switch`) and, on a match, rebinds
  the closure's environment and the arguments into that member's slots and
  branches there (`emit_indirect_rebind`). Anything else falls back to a plain
  indirect call.

Each member also keeps a thin wrapper with its original signature that packs its
arguments, calls the dispatcher, and unpacks the result, so ordinary callers
outside the group see a normal function (`wrapper_for_group`).

The effect is that an arbitrarily long tail-call chain in a mutual group runs as
branches inside one dispatcher frame, in constant stack.

## Suspension: the CPS split

`src/gleamc/cps.gleam` makes suspension control flow explicit. It walks each
function and **splits a block at every `OpSuspend`**, so each segment becomes its
own block with a resume label; the preceding segment ends in a `Jmp` to the next.
`OpSuspend(dest, fut, resume)` is the only op that can yield; after this pass,
each yielded segment is a state the backend can re-enter.

`OpSuspend` is produced by `lower` for `await` (the `uv.*` and timer builtins).
A block without suspension is left unchanged, so only functions that actually
suspend become state machines.

## The state-machine function

A function that suspends is emitted as a **step machine**
(`emit_machine_function` in `llvm.gleam`):

- a frame type `%__frame_<fn>` holds all locals plus the machine fields: a
  `state` index, a `fut` slot for the pending future, and (when the function
  returns a value) a `result` slot;
- `Gleamc_<fn>_step(frame) -> i1` reads the state index and switches to the
  corresponding block. Returning `true` means the machine finished (the result,
  if any, is in the frame); returning `false` means it suspended and the `fut`
  slot points at the pending future;
- the wrapper with the original signature allocates the frame, stores the
  arguments, and drives the machine through `gleamc_sched_run`, then returns the
  result. Locals live in the frame, so they survive a suspension.

At a suspension point the step stores the future pointer in the frame and
returns `false`; on resume, the block head reads the completed future's value
into `dest` and releases the future (`emit_wake`).

## Scheduler and futures

The scheduler and futures live in `runtime/gleam_runtime.[ch]`.

- `GleamcFuture` carries `deadline`, `done`, an error code, a scalar wake value
  (`value_i`), a pointer wake value (`value_p`), and whether it is armed on the
  libuv loop (`uv_armed`).
- `gleamc_sched_run(step, frame, fut_slot)` repeatedly calls `step`; when a step
  suspends it waits for the future — running the libuv loop for armed futures,
  or sleeping until the deadline for timer futures — and then re-enters the step.
- `gleamc_task_spawn` / `gleamc_tasks_drain` hold a small task table so spawned
  machines are stepped cooperatively.

libuv is required: every generated binary links `-luv`, and there is no
synchronous fallback.

## The async builtins

The asynchronous surface is a small set of builtins, declared in
`src/gleamc/ffi_modes.gleam`, whose `Future` is internal to the lowering:

- `time.timer(ms)` and `time.timer_count(ms)` — a one-shot timer; `await` on the
  returned future drives the loop until it fires.
- `uv.fs_open`, `uv.fs_read`, `uv.fs_write`, `uv.fs_close`, `uv.fs_stat`,
  `uv.fs_realpath`, `uv.fs_readdir`, `uv.fs_mkdir`, `uv.fs_rmdir`,
  `uv.fs_rename`, `uv.fs_symlink`, `uv.fs_link`, `uv.fs_chmod`, `uv.fs_unlink`,
  `uv.fs_cwd` — the file-system surface, all asynchronous.

An `await` lowers to: create the future, `OpSuspend` it, and on resume read the
value with the matching accessor (`Gleamc_uv_result` for scalars,
`Gleamc_uv_await_bytes` for bit arrays, `Gleamc_uv_value_int` for value-carrying
futures). The standard library (`std/simplifile.gleam`) is written against this
surface, so no blocking disk call is used.
