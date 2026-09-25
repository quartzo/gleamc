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

The result: self and same-signature mutual recursion run in constant stack at
any `-O`, including `-O0`.

## Async

`time.timer` / `uv.fs_*` start a `Future`; `await` **suspends and hands the
future back to the libuv loop**. A function containing an `ir.Suspend` is a heap
frame function (`frame.machine_functions`) and is emitted as a flat state
machine (`emit_machine_function`):

- the frame holds the locals plus a `state`, a pending `fut` and a `result`;
- the `_step(frame) -> i1` switches on `state`. At a suspension it stores the
  pending future and the resume state and returns "not done"; the resume block
  reads the awaited value (`Gleamc_uv_await_*`) and releases the future; at a
  return it stores the result and returns "done";
- the wrapper allocates the frame, stores the arguments, and drives the step
  through `gleamc_sched_run`, which waits on the future (the libuv loop) and
  re-enters the step. The wrapper owns the frame and releases it after reading
  the result — the step suppresses `OpDrop(frame)` so the frame outlives the
  machine.

The suspension is an `ir.Suspend(fut, dest, resume)` **terminator**: it ends
the block, so no `cps` pass is needed, and it defines `dest` in the resume
block. Locals live in the frame, so they survive the suspension. A tail call
*inside* a suspending function is emitted as a plain call (the machine cannot
keep the caller's frame across it).

The runtime (`runtime/gleam_runtime.[ch]`) carries the scheduler: `GleamcFuture`,
`gleamc_sched_run`, the task list (`gleamc_task_spawn` / `gleamc_tasks_drain`)
and the `gleamc_uv_*` wrappers. libuv is required; there is no synchronous
fallback.
