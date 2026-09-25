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
- the return type is returned in registers (`can_musttail`). A large aggregate
  that the ABI lowers to an `sret` pointer aborts the backend under `musttail`.

Otherwise the call is a plain `call` + `ret`. In particular a
`TailcallIndirect` is always a plain call: a local closure owns the frame the
callee reads as its environment, so releasing it before the call (which
`musttail` forces) would free that frame early.

The result: self and same-signature mutual recursion run in constant stack at
any `-O`, including `-O0`.

## Async

`await` is currently lowered inline: `time.timer` / `uv.fs_*` start a `Future`
and `OpSuspend` drives the libuv loop synchronously with `gleamc_future_wait`.
The intended behaviour is to **suspend and hand the future back to the loop**
(the state machine of commit `80b62ff`), which the inline `4afd3d6` replaced.
That restoration is stage 2 of the musttail plan and is not implemented yet;
see [tco-musttail-plan.md](tco-musttail-plan.md).

The runtime (`runtime/gleam_runtime.[ch]`) already carries the pieces:
`GleamcFuture`, `gleamc_sched_run`, the task list (`gleamc_task_spawn` /
`gleamc_tasks_drain`) and the `gleamc_uv_*` wrappers. libuv is required; there
is no synchronous fallback.
