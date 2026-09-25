# Plan: drop the dispatchers, TCO with musttail, async explicit

Status: dispatchers removed and `musttail` TCO landed (tests/diffs green).
Async stage 2 and the 8 MiB self-host target remain.

## Context

The backend used to collapse mutual tail-call groups into per-group
"dispatchers" (`plan.Group`, `emit_group`) and carry non-tail member calls on a
heap return stack. Grouping by weakly-connected components made dispatchers
gigantic and their `-O0` spilled frames dominated the native stack. All of that
is now gone: functions are emitted one by one and tail calls use LLVM
`musttail`. `plan.gleam`, `cps.gleam` and the group machinery were deleted.

## What landed

- `plan.gleam`, `cps.gleam`, `pipeline.compile_to_plan`, `test/plan_test.gleam`
  deleted. `has_capture` moved to `frame.gleam` (`frame.machine_functions`).
- `ownership.gleam`: `plan.*` and `lower_indirect_tails` removed.
- One emitter per function: `emit_function` (no frame) or `emit_frame_function`
  (heap frame because a closure captures a local). No `emit_group`,
  dispatchers, return stack, `member_call_op`, `emit_rebind`,
  `emit_machine_call/return`, `emit_indirect_switch`.
- Direct tail calls: `%r = musttail call <ret> @Gleamc_<fun>(args)` then
  `ret <ret> %r` when allowed, else a plain `call` + `ret`.
- `OpDrop(frame)` now renders the frame teardown; the old inline drop at `Ret`
  was removed (avoids a double release).
- Tail-terminator operands are read **before** the trailing `OpDrop` run, so a
  `musttail` call is immediately followed by its `ret` and frame slots/`fval`
  are not read after release.

## musttail rules discovered

- **Calling convention.** `tailcc`/fastcc miscompiles `musttail` when arguments
  spill to the stack: a self-recursive `tailcc` function with 7 `i64` arguments
  loops forever (clang 22, x86-64). The default `ccc` handles stack arguments
  correctly. So generated functions stay `ccc`.
- **Prototypes.** Under `ccc`, `musttail` requires the caller and callee
  prototypes to match. That holds for self-recursion and same-signature mutual
  recursion, but not for the common wrapper→helper pattern (e.g. `reverse` has 1
  parameter, `reverse_helper` has 2). `musttail_ok` (in `llvm.gleam`) therefore
  checks `can_musttail(return)` **and** `prototype_matches(caller, callee)`;
  otherwise the call is plain.
- **Return type: explicit sret.** A large aggregate return would normally be
  lowered to an `sret` out pointer by the ABI, and `musttail` forbids that
  automatic conversion (LLVM aborts the backend). Instead, functions whose
  return needs sret are emitted with an **explicit** `ptr sret(%R) %__out`
  parameter: the out pointer is a plain argument that a tail call forwards
  unchanged, so self/same-signature recursion returning `Result` and friends is
  constant-stack. Calls without a matching prototype still fall back to `call`.
- **Indirect tail calls are plain calls.** A local closure owns the frame that
  the callee uses as its environment; releasing the closure before the call
  would free that frame early. `TailcallIndirect` is therefore emitted as
  `call` + drops + `ret`, keeping the closure alive through the call. (An owned
  environment ABI would allow indirect `musttail`; deferred.)

## Ownership change

A `Borrow` parameter passed to an `Owned` target (a tail call to an `__owned`
clone) is an ownership transfer with no reference to hand over, so it needs
`count` retains even on its last use — unlike an owned local, whose last use
already carries one reference and needs `count - 1`. `term_retains_owning` now
consults the caller's borrowed parameters (`borrowed_params` in
`ownership.gleam`).

## Async (stage 2, pending)

The intended behaviour is to suspend and hand the `Future` back to the libuv
loop (restore the `80b62ff` state machine, undone by `4afd3d6`). The plan is to
lower it in an IR->IR pass right after `frame`, with an `ir.Suspend(fut, dest,
resume)` **terminator** instead of the `OpSuspend` op, so `cps` is not needed
and the backend has no async knowledge. `musttail` is not used for suspending
functions: pausing to the loop is the expected behaviour.

## Remaining

- [ ] Async stage 2: `Suspend` terminator, `step` + wrapper in IR, delete
      `OpSuspend`.
- [ ] Full self-host under 8 MiB. The explicit-sret change took the full
      self-compile from >1 GiB to ~32 MiB, and a small file already compiles
      under 8 MiB. The gap left is the tail calls that still are not `musttail`:
      same-arity direct calls whose return type differs (impossible), different
      arity (wrapper→helper), and the indirect CPS continuations. Those need
      either a trampoline or prototype shims.
- [ ] Update `docs/machine.md` / `docs/cascade.md` / `docs/frame-environment.md`
      (they still describe dispatchers, `plan`/`cps` and inline async).

## Validation

- `gleam test`: 147/0 (the 6 removed `plan` tests aside).
- `scripts/diff.sh`: 61/61.
- Constant-stack: direct, mutual and same-signature recursion at 1e6
  iterations, including `Result`-returning functions (explicit sret);
  `live blocks = 0` on the closure/frame reproducers.
- Self-host: the first-generation compiler compiles a small file under
  `ulimit -s 8192` and the whole compiler under `ulimit -s 32768`; the
  second-generation binary compiles a small file under 8 MiB.
