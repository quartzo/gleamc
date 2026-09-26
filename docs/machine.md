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

## Processes and tasks

A second, non-suspending start mode makes the driver useful for concurrency
rather than only for awaiting callees. `process.spawn(fn() -> Nil)` starts the
closure's machine on the driver and **returns immediately** (a `Pid`);
`task.async(fn() -> a)` is the same but returns a `Task(a)` whose completion
future carries the closure's boxed result, read back by `task.await`.

The public surface is `std/gleam/erlang/process.gleam` and
`std/gleam/otp/task.gleam`, written in Gleam on top of the `process_ffi.*` /
`task_ffi.*` builtins. `process.spawn` and `task.async` themselves stay builtins
under their public names so the compiler can start the closure at the call
site; the rest (`new_subject`, `send`, `receive`, `receive_forever`, `sleep`,
`await`, `try_await`, ...) are Gleam wrappers, which is what lets labelled
arguments (`receive(from:, within:)`) work.

The `spawn` pass (`spawn.gleam`) runs between `lower` and `async`. It reads the
single `fn() -> ...` argument's `OpClosure`: a bare named function
(`__gv_<name>`) becomes `ir.OpTaskStart` with no arguments, while a lifted
lambda (`Gleamc___lambda_N`, possibly capturing) becomes
`ir.OpTaskStartClosure`. The backend allocates the callee frame exactly as
`OpMachineStart` does, adopts the closure's environment as the frame's `__env`
(a retained reference, released by the frame drop), and calls
`gleamc_task_spawn` (fire-and-forget) or `gleamc_task_async` (result into a
box). A lambda that does not suspend is still emitted as a machine
(`frame.task_targets` forces it). A spawned task is *detached*: the driver owns
its completion future and releases it when the task finishes.

Mailboxes are the communication primitive. `process.new_subject()` returns a
`Subject(a)` handle to a runtime `GleamcMailbox`; `process.send(subject,
message)` is a plain synchronous call that hands the box to the oldest waiting
`receive`, completing its future, or enqueues it. `receive_forever(from:)`
returns an already-done future when a box is queued and otherwise registers a
waiter, so it never blocks the driver on a non-empty mailbox. Because `send`
runs inside a task's `step`, the driver's `progressed` flag guarantees the
woken receiver is re-stepped.

### Timeouts

`receive(from:, within:)` and `task.try_await(t, timeout)` need to race a
message/task against a timer. `process_ffi.wait_any` registers a *notifier* on
the mailbox (alongside the `receive` waiters): the box stays queued and the
notifier's future is completed with `value_i = 1`, so the following `receive`
claims it; on timeout a libuv timer removes the notifier and completes the
future with `value_i = 0`. `task_ffi.await_timeout` sets itself as the task
completion future's single `notify` observer: the driver completes it with
`value_i = 1` when the task finishes, or the timer completes it with `0`. Both
wait futures are held by their timer (`gleamc_wait_timer_new` retains them), so
whichever side loses still closes cleanly.

### Boxed values

`Subject(a)` and `Task(a)` are phantom handle types (`llvm_ty` maps them to
`i64`/`i8*`), so the payload type is carried entirely by the type checker. At
the boundary the concrete value is **boxed**: `send` allocates a refcounted
cell of the message's size and moves the value into it (`Owned` mode), and the
resume moves it out and frees the cell without dropping the payload. The same
box carries a `task.async` result. `ir.Suspend`'s mode distinguishes the three
resume shapes: `Host` reads a host future, `Machine` releases a started
machine's completion future, and `Boxed` moves a box out (`Gleamc_uv_await_box`
+ `emit_await_box`). Any representation works — `Int`, `String`, records, and
lists all round-trip.

`process.new_subject()` is polymorphic; `let s = process.new_subject()` keeps a
free type variable that later `send`/`receive` calls unify, thanks to the
**value restriction** on `let` generalisation (only syntactic values are
generalised, matching Gleam), so no annotation is needed.

`process.spawn` is fire-and-forget: draining a mailbox does **not** join the
senders. Detached tasks still running at exit are not cleaned up (their frames
leak), and a `Subject` handle is not refcount-dropped (one leak per subject),
so a program that wants a clean leak report should let tasks settle and is
expected to show the subjects.
