# Inference once: a typed AST as the product of the type layer

Status: **largely landed.** Both type layers now produce a typed AST and their
consumers read it instead of re-deriving types:

- the **generic** stage (`infer.gleam`) elaborates to `texpr.TExpr`; the
  monomorphiser reads subexpression types from it, which removed the dominant
  cost of `mono` (42.7s → 5.6s on the selfhost self-compile);
- the **monomorphic** stage (`checker.gleam`) elaborates the monomorphic module
  into `tmono.TExpr`, and the backend (`lower.gleam`) consumes it, so `lower`
  no longer re-runs `checker.infer` (5.7s → 2.2s).

Types therefore have a single owner at each stage. What remains (optional,
smaller) is described below.

## Motivation

Type inference ran several times and each consumer re-inferred to recover the
per-expression types it needed. The most expensive symptom was
`mono.type_of`: for each subexpression the walk re-ran the whole inference,
which allocates `types.Ty` and refcounts them (the profile was dominated by
`Gleamc_rc_retain` / `Ty` drop / `Buffer` glue).

## What is landed

- `src/gleamc/texpr.gleam` — `TExpr`, the typed AST: every node carries its
  inferred `types.Ty`, plus `type_of`, `to_expr`, `subst_types`/`subst_ty`.
- `infer.infer_t` — the single inference recursion; it **elaborates** to
  `TExpr`. `infer` keeps its `Ty` interface by delegating to `infer_t`, so the
  inference logic is not duplicated.
- `mono` walks the surface `Expr` **paired** with its typed companion
  (`mono_expr_pair` / `mono_expr_ex_pair`). All source forms are covered
  (literals, var, binop, unop, field, tuple, labelled, bit array, block/`let`,
  call, constructor, case, lambda), so subexpression types are read from the
  annotation (`read_ty`) instead of re-inferred. `mono_arms` and `mono_arms_ex`
  stay distinct (with or without the case's expected result type).
- A **verification harness**: `read_ty` cross-checks the annotation against the
  re-inference under `GLEAMC_MONO_VERIFY=1`, logging divergences (compared up to
  alpha-equivalence) and falling back. Verified at zero real divergences for
  the migrated forms.
- `src/gleamc/tmono.gleam` — `TExpr`, the typed **monomorphic** AST: every node
  carries its `ast.Type`, plus `type_of` and `to_expr`.
- `checker.check` **elaborates** the monomorphic module into `tmono.TExpr`
  (`checker.infer_t`) and returns it as `Checked.typed`; `lower` consumes that
  typed AST and reads node types via `tmono.type_of`, so it no longer re-runs
  `checker.infer`.

`mono` drops from 42.7s to 5.6s and `lower` from 5.7s to 2.2s on the selfhost
self-compile. Validated by `gleam test`, `scripts/diff.sh`, an 8 MiB
self-compile, AddressSanitizer, and `GLEAMC_MEM_REPORT`.

## What remains (optional, smaller)

- **One `infer_t` per specialisation.** `specialise_fn_inner` still infers the
  specialised body once. The generic typed bodies are stashed in
  `infer.Program.typed`; specialising them by **substitution** (instantiate the
  scheme's quantifiers with the call's type arguments, `texpr.subst_types`)
  would remove this pass. It is blocked by the still-unpaired forms — mainly
  `EUpdate` (record-update desugaring re-infers) and synthesised nodes — which
  need the pre-inference substitution. Attempts break the selfhost.
- **`type_of` for synthesised expressions** in `mono` (eta-expansion,
  record-update desugaring): small; the paired fallback is rare.
- **Unify the two inferencers.** The generic stage (`infer.gleam`, HM with
  substitution) and the monomorphic stage (`checker.gleam`, no substitution)
  are separate implementations. They serve different stages, but the
  monomorphic one could in principle be a special case of the generic one.

## Cautions

- The selfhost self-compile is the acceptance gate at every step, together with
  `gleam test`, `scripts/diff.sh`, an 8 MiB stack self-compile, and ASan.
- Keep `mono_arms` and `mono_arms_ex` separate; conflating them breaks the
  selfhost.
