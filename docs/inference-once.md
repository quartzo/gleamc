# Inference once: a typed AST as the product of the type layer

Status: **partly landed.** Inference is now materialised as a typed AST
(`texpr.TExpr`), and the monomorphiser reads subexpression types from it
instead of re-inferring, which removed the dominant cost of `mono`
(42.7s → 5.6s on the selfhost self-compile). The remaining consumers
(`checker`, `lower`, and one `infer_t` per specialisation) still compute types
themselves; the path to retire them is described below.

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

`mono` drops from 42.7s to 5.6s and the whole compiler from ~78s to ~43s on the
selfhost self-compile. Validated by `gleam test`, `scripts/diff.sh`, an 8 MiB
self-compile, AddressSanitizer, and `GLEAMC_MEM_REPORT`.

## What remains (optional, further gains)

- **`type_of` for synthesised expressions.** Eta-expansion, record-update
  desugaring and lambda lifting build new expressions with no typed companion,
  so they still call `type_of`. Small in practice (the fallback is rare).
- **One `infer_t` per specialisation.** `specialise_fn_inner` still infers the
  specialised body once. The generic typed bodies are already stashed in
  `infer.Program.typed`; specialising them by **substitution** (instantiate the
  scheme's quantifiers with the call's type arguments, `texpr.subst_types`)
  would remove this pass. Note the earlier finding: `type_of` returned
  deliberately *partial* types (fresh variables resolved later), whereas the
  annotation is complete; specialisation by substitution must therefore be
  paired with a mono typing flow that does not rely on re-inference side
  effects.
- **`checker` and `lower`.** `checker.check` still re-infers the monomorphic
  module as a safety net (`signatures`/`ctors` come from `collect`), and
  `lower` calls `checker.infer` at ~13 sites. To read annotations there, `mono`
  must emit typed nodes (`TExpr`) and `dce`/`lower` consume them.

## Cautions

- The selfhost self-compile is the acceptance gate at every step, together with
  `gleam test`, `scripts/diff.sh`, an 8 MiB stack self-compile, and ASan.
- Keep `mono_arms` and `mono_arms_ex` separate; conflating them breaks the
  selfhost.
