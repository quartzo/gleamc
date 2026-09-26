# Inference once: a typed AST as the product of the type layer

Status: **in progress, foundation landed; the `mono` migration is a dedicated
effort** (see "Blockers"). This document records the design, what is already
in place, and exactly why the remaining step is a structural refactor rather
than a mechanical migration.

## Motivation

Type inference runs several times and each consumer re-infers to recover
per-expression types it needs:

1. `mono.monomorphize` → `infer.check_resolved` (`mono.gleam`): full HM over
   the generic module, once.
2. `mono.specialise_fn_inner` → `infer.infer_t` (`mono.gleam:320`): HM **per
   specialisation**.
3. `mono.type_of` → `infer.infer` (`mono.gleam:1971`, ~11 call sites):
   re-infers a **subexpression** during the walk, in the current state.
4. `checker.check` (`pipeline.gleam`): re-infers the monomorphic module, purely
   as a safety net (`signatures`/`ctors` come from `collect`).
5. `lower` → `checker.infer` (`lower.gleam`, 13 sites).

The goal is a **single inference** that produces a typed AST
(`texpr.TExpr`), after which `mono` specialises by substitution and `lower`
reads types, so (2), (3), (5) and the inference half of (4) disappear.

## What is landed

- `src/gleamc/texpr.gleam` — `TExpr`, the typed AST: every node carries its
  inferred `types.Ty`; plus `type_of`, `to_expr`, `subst_types`, `subst_ty`.
- `infer.infer_t` — the single inference recursion; it **elaborates** to
  `TExpr`. `infer` keeps its `Ty` interface by delegating to `infer_t`, so no
  inference logic is duplicated. The bodies elaborated by `check_resolved` are
  stashed in `infer.Program.typed` (generic, zonked with the final subst).
- `mono` reads from the elaboration in a **paired walk** (`mono_expr_pair` /
  `mono_expr_ex_pair`), threading the surface `Expr` together with its typed
  companion. Migrated so far: binop and block/`let`.
- A **verification harness**: `read_ty` (`mono.gleam:672`) reads the
  annotation; under `GLEAMC_MONO_VERIFY=1` it cross-checks against `type_of`,
  logs divergences and falls back. The migrated forms show **zero**
  divergences on the selfhost self-compile.

Commits: the `texpr`/`infer_t` foundation, the paired binop/block slice, and
the harness.

## Blockers (discovered, decisive)

Attempts to extend the paired walk to calls/constructors/cases and to
specialise by substitution both fail on the selfhost (`infer_collect_type`,
`cannot unify Nil with Int`, `… with ?`). Root causes:

1. **`type_of` is not a type read.** It re-infers a subexpression *in the
   current state*, which **allocates fresh variables, unifies and advances
   `counter`/`subst`**. `mono`'s state threading **depends** on those side
   effects. A complete annotation cannot reproduce them.
2. **The annotation is more resolved than `type_of`.** Re-inference often
   returns a *fresh variable* (`z2289`) that `mono` resolves later by
   unification, whereas the single-inference annotation is already concrete.
   So the annotation is semantically better but **incompatible** with the
   current unification flow — mixing the two schemes breaks (the `?`/`Nil`).
3. **Structural pitfalls.** e.g. `mono_expr`'s `ECase` must not be routed
   through `mono_expr_ex`: `mono_arms` (no expected type) and `mono_arms_ex`
   (with the case's result expected) are different functions. The harness
   surfaces these.

The harness comparison itself is currently naïve: `types.describe` compares
**variable names**, so many "divergences" are alpha-equivalent. It must be
made alpha-aware before it can guide the migration.

## The correct end state

```
front-end (Expr) → types (Expr → TExpr, once) → mono (TExpr → monomorphic TExpr)
                 → dce (TExpr) → lower (TExpr → IR)
```

- The type layer emits a fully typed AST; `mono` is a **pure transformer** that
  specialises by **substitution** and does **not** depend on re-inference side
  effects.
- `type_of` is removed; `checker` becomes validation (or a gated pass);
  `lower` reads annotations.

## Plan for the dedicated effort

1. **Harden the harness**: compare up to alpha-equivalence (ignore variable
   names/ids), and report only real divergences. Make it cheap enough to run
   over the whole selfhost.
2. **Decouple `mono`'s typing state from `type_of`**: make each migrated read
   pure (no fresh variables/counter/subst side effects), introducing the
   substitution/unification it needs explicitly. Do this form by form, keeping
   the harness green and the selfhost compiling.
3. **Specialise by substitution**: `specialise_fn_inner` applies the
   instantiation substitution to the generic typed body instead of calling
   `infer.infer_t`; ensure per-use instantiation is represented so annotations
   are exactly what the (former) re-inference used to yield.
4. **Retire the extra passes**: remove `type_of`; reduce `checker.check` to
   validation (gate behind `GLEAMC_VERIFY`); make `lower` read `TExpr`
   annotations.
5. Update `docs/cascade.md` and `docs/memory.md` accordingly.

## Non-goals / cautions

- Do **not** migrate "by slices" while keeping `type_of` as a fallback: the two
  typing schemes are inconsistent and will break (this was tried).
- The selfhost self-compile is the acceptance gate at every step, together with
  `gleam test`, `scripts/diff.sh`, an 8 MiB stack self-compile, and ASan.
