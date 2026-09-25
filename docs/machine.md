# Tail calls and async

`gleamc` runs recursive Gleam code in constant native stack. Tail position is
decided during lowering (see [cascade.md](cascade.md)): a call in tail position
becomes an `ir.Tailcall` (known function) or `ir.TailcallIndirect` (function
value). Everything else stays an `OpCall`/`OpCallIndirect`.

## Tail calls: `musttail`

There are no dispatchers, mutual groups or heap return stack. Each function is
emitted on its own and a direct tail call becomes a `musttail` call followed by
its `ret` (`llvm.gleam`, `emit_exit_term`/`emit_tail_call`):

```llvm
%r = musttail call <ret> @Gleamc_<fun>(args)
ret <ret> %r
```

No instruction may sit between the call and the `ret`, so all cleanup — the
trailing `OpDrop`s, including the frame release of a capture-only function — is
emitted before the call, after the call's operands are loaded. In a
capture-only function (`emit_frame_function`) the locals live in a heap frame
that a closure may capture; the frame is released as an `OpDrop(__frame)` and
the `musttail` call is the last thing the activation does.

`musttail` is only used when it is safe:

- the caller and callee use the default C calling convention and their
  prototypes match (`prototype_matches`). This covers self-recursion and
  same-signature mutual recursion. The `tailcc` convention allows mismatched
  prototypes but miscompiles a call whose arguments spill to the stack (a
  self-recursive `tailcc` function with seven `i64` arguments loops forever on
  x86-64), so it is not used;
- a large aggregate return is emitted with an **explicit** `sret` out pointer
  (`ptr sret(%R) %__out`) instead of the automatic ABI conversion. `musttail`
  forbids the automatic form but forwards the explicit pointer unchanged, so
  `Result`-returning recursion is constant-stack too (`ret_needs_sret`).

Otherwise the call is a plain `call` + `ret`. In particular a
`TailcallIndirect` is always a plain call: a local closure owns the frame the
callee reads as its environment, so releasing it before the call (which
`musttail` forces) would free that frame early.

An **async** tail call is never a `musttail` call: the callee is a machine on a
separate heap frame, so it becomes an `ir.TailMachine` delegation (see Async
below). `musttail` is reserved for the fully-synchronous interior.

The result: self and same-signature mutual recursion run in constant stack at
any `-O`, including `-O0`.

## Async

`time.timer` / `uv.fs_*` start a `Future`; `await` **suspends and hands the
future back to the driver**. A function is async if it reaches a host `Suspend`
transitively (the `async` pass computes the fixpoint), so any function that calls
an async function becomes async too. An async call is rewritten to start the
callee as a task and suspend on its completion future:

- `OpMachineStart(fut, callee, args, dest)` launches the callee's machine on the
  cooperative driver and yields a completion future;
- the terminator `ir.Suspend(fut, dest, resume, machine)` stores the future and
  the resume state and returns "not done"; the resume block reads the awaited
  value (`Gleamc_uv_await_*`) and releases the future.

An **async tail call** becomes an `ir.TailMachine(fun, args)` terminator instead:
it delegates the *running* task to the callee, so a tail-call chain keeps a
constant number of tasks and C-stack frames.

A machine is a flat state machine (`emit_machine_function`):

- the frame holds the locals plus a `state`, a pending `fut` and a `result`;
- the `_step(frame) -> i1` switches on `state`. At a suspension it stores the
  pending future and the resume state and returns "not done"; at a `Ret` it
  stores the result and returns "done"; at a `TailMachine` it releases this
  frame, builds the callee frame and calls `gleamc_task_tail`;
- the wrapper allocates the frame, stores the arguments, starts a task and calls
  `gleamc_run_until(done)`. The driver owns the frame and runs its teardown
  (`__frame_<fn>_drop`) when the task finishes or delegates; the step suppresses
  `OpDrop(frame)`.

A function that is async only by a tail call has no `_step` of its own body but
is still emitted as a machine so it can be started as a task and can delegate.

One global driver (`gleamc_run_until`) runs every task on the libuv loop. It is
**reentrant**: a synchronous call into an async closure (e.g. the continuation
passed to `result.try`) drives only up to its own completion future, skips the
task already running on the C stack, and does not compact the task table while
nested.

The runtime (`runtime/gleam_runtime.[ch]`) carries `GleamcFuture`,
`gleamc_task_start` / `gleamc_task_tail` / `gleamc_run_until` and the
`gleamc_uv_*` wrappers. libuv is required; there is no synchronous fallback.
