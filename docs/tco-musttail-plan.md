# Plan: drop the dispatchers, TCO with musttail, async explicit

Status: dispatchers removed, `musttail` TCO landed, async is a state machine
again, and the self-host runs under an 8 MiB stack (tests/diffs green).

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
## Async (stage 2, done)

`await` suspends and hands the `Future` back to the driver: a function that
reaches a host `ir.Suspend(fut, dest, resume, machine)` terminator is a heap
frame function (a *machine*) and is emitted as a `_step` + wrapper state machine
(`emit_machine_function`). An async call becomes `OpMachineStart` + `Suspend`;
one global driver (`gleamc_run_until`) runs every task on the libuv loop and is
reentrant across synchronous calls into async closures. `lower` emits the
terminator, so no `cps` pass is needed. The task owns the frame and runs its
teardown when the machine finishes or delegates. See
[machine.md](machine.md#async).

An async tail call is an `ir.TailMachine` delegation: the running task is
retargeted to the callee, so async tail recursion is constant-task.
`musttail` is reserved for the fully-synchronous interior.

## The `-O0` frame problem and the `-O1` baseline

`musttail` keeps *tail recursion* in constant stack, but the native stack was
once dominated by codegen: the backend emitted one `alloca` per local, and `-O0`
runs neither `mem2reg` nor register allocation, so every local stayed in memory
and a huge function such as `llvm.emit_op` (688 source lines) reserved ~100 KB
of spill slots per activation.

That is fixed at the source now. The `ssa` pass (between `ownership` and the
backend) emits SSA directly: a single-definition local whose definition dominates
its uses becomes a register, and a `case` result joined from several arms becomes
a `phi`. Only locals that genuinely need an address stay in a slot — an `sret`
call result, `buffer.take`, and every local of a machine/frame function, which
lives in its heap frame. On the self-compile this took the `alloca` count from
~44k to ~4k.

`clang -O1` remains the dev default (`toolchain.gleam`) for code quality: SROA,
instcombine and the register allocator still improve the output. But the
`mem2reg` dependency that made `-O0` unusable is gone, so `-O0` is now viable and
is no longer deliberately avoided.

## Remaining

- [ ] Split the giant `case` functions (`llvm.emit_op`, `frame.rewrite_op`,
      `ir.op_text`, `checker.infer_builtin`, `mono.specialise_type`,
      `mono.mono_pattern`) so each has few live values. The `-O1` register
      allocator hides their size, but it does **not** hide their cost: on the
      self-compile the codegen time is dominated by instruction selection and
      register allocation on `llvm.emit_op` (116k lines of IR in one function).

## Validation

- `gleam test`: 165/165.
- `scripts/diff.sh`: 62/62.
- Constant-stack: direct, mutual and same-signature recursion at 1e6
  iterations, including `Result`-returning functions (explicit sret);
  `live blocks = 0` on the closure/frame reproducers.
- Self-host: the compiler compiles itself under `ulimit -s 8192`, and the
  second-generation binary compiles a small file under 8 MiB.
