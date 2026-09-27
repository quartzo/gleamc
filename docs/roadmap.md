# Roadmap: idiomatic Gleam and concurrency

This document plans the remaining gaps between `gleamc` and **idiomatic
Gleam**. It complements [known-limitations.md](known-limitations.md) (what is
missing today) and [manual/](manual/README.md) (what is implemented).

## Guiding principle

The idiomatic Gleam API is **Subject/Selector-oriented**: you send to a
`Subject`, receive `from` a `Subject`, and wait on a `Selector` over several
subjects. The single per-process mailbox, raw terms and atoms are **BEAM
implementation details**; the portable Gleam semantics (also used by the
JavaScript target) are per-subject.

Consequence: matching the *typed* API does **not** require a unified process
mailbox. The unified mailbox is only needed for the **Erlang-interop** corners
(raw tuples, atoms, "any message in the process inbox").

## Status (done)

Multitasking and inter-task communication are implemented and verified for the
typed model:

- processes/tasks, timeouts, `kill`, links/monitors/`trap_exits`, names;
- subjects, selectors (`select`, `select_map`, `map_selector`,
  `merge_selector`, `select_other`, `deselect(_specific_monitor)`), `call`/
  `call_forever`, `flush_messages`, `send_after`/`cancel_timer`;
- refcounted `Subject`, `SelectorHandle`, `Task`, `Dynamic`; per-message drop;
  shutdown cleanup of pending tasks and timers;
- `gleam test` and `./scripts/diff.sh` green; ASan-clean on the concurrency
  examples.

## Priorities

| # | Phase | Value | Effort | Risk | Depends on |
|---|---|---|---|---|---|
| 1 | Erlang-interop message corners | medium | high | high | — |
| 2 | OTP actor + supervision | high | medium | medium | 1 (optional) |
| 3 | `Dynamic` reification + `decode` | low | high | medium | — |
| 4 | Language breadth | high | medium | medium | — |
| 5 | Stdlib breadth | high | high | low | 4 |
| 6 | Self-host | high | medium | low | 4, 5 |
| 7 | Toolchain | medium | medium | low | — |

---

## Phase 1 — Erlang-interop message corners

**Goal.** Faithful `select_other`, `select_record`, `flush_messages`, global
inbox ordering, and mailbox-wide selective receive.

**Why.** These are the only places the process mailbox (rather than a subject
channel) leaks into the Gleam API, and they exist for interop with raw BEAM
terms. Without a BEAM to interoperate with they have no input today, so this is
lower priority than it looks — but it is the "correct" model.

**Scope (unified inbox).**

1. `Subject` becomes `{owner, tag}` (not a mailbox pointer); `Name` likewise.
   Runtime: replace the per-subject `GleamcMailbox` with one inbox per task
   holding `{tag, box}` entries; keep the per-subject *view* for `receive`.
2. `send(s, m)` enqueues `{tag, box}` into the **owner's** inbox; `receive(from:
   s)` scans the owner's inbox for `tag` (with the deferred/set-aside queue).
3. Resolve cross-owner subjects and names; `subject_owner`/`subject_name` map to
   the tag/owner.
4. Selectors operate on tag sets over the owner's inbox; `selector_wait` wakes
   on any selected tag.
5. `select_other` = any entry; `flush_messages` = drain the owner's inbox;
   `select_record` = match a `{tag, fields...}` tuple by tag/arity (needs a raw
   term representation and atoms).
6. Migrate monitors/links (`Down`/`ExitMessage`) to reserved tags in the same
   inbox.

**Deliverables.** Runtime core rewrite (`runtime/gleam_runtime.c`), compiler
handle/RC adjustments (`Subject`/`Name`/`Selector`), std `process.gleam`.

**Risk.** High: it rewrites the messaging core. Mitigation: the 170 tests,
`diff.sh`, and the ASan/refcount audit are a strong net; migrate behind
incremental commits.

**Tests.** Extend `selector_test`, `monitor_test`, `names_test`; add a
`select_record`/global-order test; run the audit and ASan.

---

## Phase 2 — OTP: actor and supervision

**Goal.** A `gleam/otp/actor` module (`start`, `send`, `call`, `new`/`start_spec`)
and supervision trees, idiomatic on top of the existing primitives.

**Why.** This is the main higher-level Gleam concurrency surface users expect.

**Scope.**

1. `gleam/otp/actor`: an actor loop built from `receive` + `Selector`; an initial
   message; `Message` dispatchers; `actor.send`/`actor.call`/`actor.call_forever`;
   `actor.new`/`actor.start_spec` returning an `Actor` handle and a `StartResult`.
2. Optional supervision: specs, restart strategies (one-for-one, rest-for-one,
   one-for-all), and a supervisor process that monitors children and restarts.
3. `gleam/otp/static_supervisor` if desired.

**Depends on.** Phase 1 only if `select_record`/raw messages are needed; the
typed actor API works without it.

**Tests.** Actor echo/server e2e; crash/restart; supervision restart counts.

---

## Phase 3 — `Dynamic` reification and `decode`

**Goal.** Complete `gleam/dynamic` and add a usable `gleam/dynamic/decode`.

**Why.** Needed only for genuinely untyped data; currently there is no source of
untyped data in the runtime, so this is low value unless an interop path is
added.

**Scope.**

1. Reification: store a compiler-emitted type descriptor/reifier in the
   `Dynamic` so `dynamic.list`, `dynamic.tuple2`..`tuple8` can rebuild
   `List(Dynamic)`/tuples. Requires emitting walkers per list/tuple type
   (`emit_box_glue`-style) and collecting the types (`collect_box_drop_types`).
2. `gleam/dynamic/decode`: the subset that needs no object indexing — `run`,
   `success`, `failure`, `map`, `map_errors`, `then`, `one_of`, `optional`,
   `list`, `int`/`float`/`string`/`bool`/`bit_array`/`dynamic`,
   `new_primitive_decoder`, `recursive`, `collapse_errors`.
   `field`/`at`/`subfield`/`dict` stay out (they index objects/maps, which the
   boxed `Dynamic` does not represent).

**Tests.** Decode round-trips for primitives, lists, options and `one_of`.

---

## Phase 4 — Language breadth

**Goal.** Close the parser/type-system gaps that most affect real code.

**Scope.**

1. Labelled parameters (`label name: T`) and full call-site label semantics.
2. `let`/`fn` parameter type annotations (`let x: T`).
3. Correct positional-field support in declarations (already parsed) and
   consistent construction/matching.
4. `@external` resolution rules (target ignored today; document or validate).
5. Optional: `const` in more positions; `use` sugar completeness.
6. Diagnostics: spans/columns and better backend error context.

**Tests.** Parser/checker unit tests; `diffs/` cases that the official toolchain
also accepts.

---

## Phase 5 — Stdlib breadth

**Goal.** Fill the remaining std gaps, in rough priority order.

**Scope.**

1. Randomness (`gleam/int.random`, `float.random`, `list.sample`/`shuffle`) on a
   seeded PRNG.
2. `bit_array`: `slice`, `base64`, sizes/units, bit-level ops, `:utf8` string
   segments in `<<...>>`.
3. `dict`/`set`: remaining functions and (optionally) balanced-tree
   representations.
4. `result`/`option`/`list`/`string` leftovers; `gleam/function` beyond
   `identity`.
5. Continue growing `simplifile` to cover the compiler's own usage.

---

## Phase 6 — Self-host

**Goal.** `gleamc` builds itself with `gleamc`.

**Scope.** `src/gleamc/ffi.gleam` already uses `simplifile` and the `host.*`
builtins instead of `@external(erlang, ...)`, so the remaining work is to:

1. Split "compiler-only" builtins from the target-program subset so the
   compiler's own source stays inside the supported language.
2. Grow `std/simplifile.gleam` (and any other module the compiler uses) until it
   covers every call.
3. Add a self-host CI target that builds gleamc with gleamc.

---

## Phase 7 — Toolchain

**Goal.** A friendlier build.

**Scope.**

1. Multi-module / multi-package builds (today: a single entry module plus
   imports).
2. Package-manager integration and dependency resolution from `gleam.toml`.
3. Formatter and language server.
4. Column-accurate diagnostics and carets.
