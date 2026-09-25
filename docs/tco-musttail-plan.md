# Plan: drop the dispatchers, TCO with musttail

Status: proposed. Execute in a dedicated session.

## Context

The backend currently collapses mutual tail-call groups into per-group
"dispatchers" (`plan.Group`, `emit_group`) and carries non-tail member calls on a
heap return stack (`%__ret`, `emit_machine_call`/`emit_machine_return`). Grouping
by weakly-connected components made dispatchers gigantic, and at `-O0` their
spilled frames (hundreds of KB) dominate the native stack, so the self-hosted
compiler still needs more than 8 MiB. The complexity is not paying off.

This plan removes all of that and does TCO between plain functions with LLVM
`musttail`. Async does not change: a `Future` is a value awaited through the
libuv loop (inline), not a machine state.

Baseline: commit `a238e25` (green: `gleam test` 153/0, `scripts/diff.sh` 61/61).
Discard the uncommitted `plan.gleam` change (all-calls-as-edges).

## Goal

- No function planning, no dispatchers, no groups, no weak components.
- Each function is emitted on its own.
- `Tailcall` / `TailcallIndirect` become `musttail` calls (direct and indirect),
  so tail recursion runs in constant native stack at any `-O`.
- Async unchanged (`Future` value + inline await).
- Keep `frame` (heap frame for captures) and `owned_clone` (owned ABI for
  tail/indirect calls).

## Target architecture

- `emit_function` (no frame) or `emit_frame_function` (heap frame, captures
  only). No `emit_group`.
- Tail call, direct:
  `%r = musttail call <ret> @Gleamc_<fun>(args)` then `ret <ret> %r`.
- Tail call, indirect:
  `%r = musttail call <ret> <code>(<env>, args)` then `ret <ret> %r`.
- No instruction may sit between the call and the `ret`. All cleanup (drops,
  frame release) is emitted as ops before the terminator.

## What to delete

- `src/gleamc/plan.gleam`: everything (`Group`, `Edge`, `Plan`, `mutual_groups`,
  `tail_edges`, `callback_edges`, `dispatched_members`, `number_states`,
  `to_text`). Move only the capture predicate (`has_capture`) into
  `frame.gleam` so `frame.machine_functions` is self-contained.
- `src/gleamc/cps.gleam` (after the async change it only does `split_calls`) and
  its call in `pipeline.gleam`.
- `src/gleamc/llvm.gleam`: `emit_group`, `wrapper_for_group`,
  `group_type_decls`, `emit_machine_call`, `emit_machine_return`,
  `emit_machine_return_val`, `emit_rebind`, `emit_indirect_switch`,
  `emit_indirect_rebind`, `emit_group_frame_release`, `plan_machines`,
  `eligible_groups`; `Ctx` fields `group`, `group_frames`, `ret_head`,
  `members`, `resume_labels`, `resume_index`, `ret_ty_name`, `ret_val`; simplify
  `local_addr`/`frame_base` (the frame pointer is the fixed `%__fr`).
- `src/gleamc/ownership.gleam`: `plan.*` usage and `lower_indirect_tails` (the
  indirect tail call stays and is TCO'd).
- `pipeline.compile_to_plan`; `test/plan_test.gleam`; adjust
  `test/frame_test.gleam`.

## What to implement

`emit_term`:

- `ir.Tailcall(fun, args)` ->
  `%r = musttail call <ret_s> @Gleamc_<fun>(<args>)` + `ret <ret_s> %r`.
  No `emit_rebind`, including self-recursion.
- `ir.TailcallIndirect(fval, args)` -> extract `code`/`env` from the function
  value and `%r = musttail call <ret_s> <code>(<env>, <args>)` +
  `ret <ret_s> %r`.

`musttail` requirements to honour:

- the callee's return type equals the caller's (true for a genuine tail call);
- the call is immediately followed by `ret` of its result;
- same calling convention (all our functions use the default);
- the indirect `%code` operand has the exact function-pointer type.

## Ownership / frame interaction

- `ownership.add_frame_lifecycle` already appends `OpDrop(frame)` as an op at
  every exit, including `Tailcall`/`TailcallIndirect`, so the frame is released
  *before* the tail call. Verify there is exactly one release (no double drop)
  and none emitted after the call.
- A tail call moves its arguments (owned ABI). If a captured frame is passed as
  a closure argument, ownership retains it for the closure, so releasing the
  activation's frame reference before the call is correct.

## owned_clone (keep)

A tail/indirect call moves its arguments into the callee, so the callee must
take ownership of every handle parameter. Instead of forcing every such target's
parameters to `Owned` (which would add retains to its ordinary direct calls),
`owned_clone` emits an all-`Owned` clone `f__owned` used only by tail/indirect
calls. It is orthogonal to the dispatchers and is still required with `musttail`.

## Incremental steps

1. Baseline: discard the uncommitted `plan.gleam` change (HEAD `a238e25`).
2. Remove the dispatchers and switch tail calls to `musttail` (`llvm.gleam`).
   The tree is expected to break.
3. Delete `cps.gleam` and its `pipeline` call.
4. Move the capture predicate to `frame.gleam`; delete `plan.gleam`,
   `compile_to_plan`, `test/plan_test.gleam`.
5. `ownership.gleam`: remove `plan.*` and `lower_indirect_tails`.
6. Get isolated tests green, in this order:
   1. direct self tail recursion, constant stack;
   2. mutual tail recursion (`/tmp/opencode/mutual.gleam`);
   3. tail call inside a capture function (frame released before the call);
   4. indirect tail call (closure) without capture;
   5. indirect tail call with capture;
   6. std loops: `list.sort`, `string.join`, `list.map` (`scripts/diff.sh`);
   7. `gleam test` (153) and `scripts/diff.sh` (61);
   8. self-host compiling itself under an 8 MiB stack.
7. Update `docs/machine.md` (drop dispatchers/return stack) and
   `docs/cascade.md` (drop `plan`/`cps`).

## Risks / open questions

- The earlier `musttail` attempt broke 11 tests; find and fix each in step 6,
  isolated. Most likely causes: mismatched return types, or cleanup emitted
  after the call.
- Indirect `musttail` requires the `%code` pointer type to match exactly.
- Frame + tail call: release before the call, not too early when a captured
  closure is an argument.

## Validation checklist

- [ ] `gleam test` green (153/0).
- [ ] `scripts/diff.sh` 61/61.
- [ ] Leak checks: `live blocks = 0` on the frame/closure reproducers.
- [ ] Tail recursion constant stack (direct, mutual, indirect).
- [ ] Self-hosted compiler compiles itself and the 2nd-gen binary works, under
      8 MiB (`ulimit -s 8192`).
