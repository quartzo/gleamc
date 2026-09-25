# The compilation cascade

This document defines the compiler's pass order, what each layer is responsible
for, the artifact it produces, and what it must **not** do. The point is that
each layer has an owner and a product: a change belongs to exactly one layer, and
can be diagnosed from that layer's artifact.

## Order

```
source
  lexer / parser      source           -> AST
  opacity             AST              -> AST          (cross-module opaque checks)
  consts              AST              -> AST          (expand constants)
  merge               AST              -> AST          (one whole-program unit)
  qualify             AST              -> AST          (canonicalise constructors)
  aliases             AST              -> AST          (expand type aliases)
  mono                AST              -> AST          (monomorphise; lift lambdas)
  dce                 AST              -> AST          (prune unreachable)
  checker             AST              -> AST          (type-check; signatures, ctors)
  lower               AST              -> IR           (basic blocks; tail calls)
  ownership           IR               -> IR           (borrow modes; retain/drop)
  cps                 IR               -> IR           (split at suspensions and non-tail member calls)
  plan                IR               -> Plan         (frames, groups, states)
  backend             IR + Plan        -> LLVM IR
```

`src/gleamc/pipeline.gleam` is the single place that fixes this order. Everything
after `lower` speaks IR; IR is the only cross-layer currency.

## Layers, responsibilities, artifacts

| Layer | Files | Input | Output | Responsibility | Must not |
|---|---|---|---|---|---|
| `lexer`/`parser` | `lexer.gleam`, `token.gleam`, `parser.gleam` | source | `ast.Module` | text to AST | know types |
| `opacity` | `opacity.gleam` | AST | AST | cross-module opaque-type checks | change semantics |
| `consts` | `consts.gleam` | AST | AST | expand compile-time constants | lower lambdas |
| `merge` | `merge.gleam` | AST | AST | combine modules into one unit | resolve names |
| `qualify` | `qualify.gleam` | AST | AST | canonicalise constructor names | specialise types |
| `aliases` | `aliases.gleam` | AST | AST | expand type aliases before specialisation | drop bindings |
| `mono` | `mono.gleam` | AST | AST | instantiate generics; **lift every lambda** | own memory |
| `dce` | `dce.gleam` | AST | AST | remove functions unreachable from the entry | type-check |
| `checker` | `checker.gleam`, `infer.gleam` | AST | AST + signatures + ctors | type-check; produce signatures/ctor info | insert runtime ops |
| `lower` | `lower.gleam` | AST | `ir.Module` | emit blocks/ops; decide **tail position** (`Tailcall`, `TailcallIndirect`) | insert retain/drop |
| `ownership` | `ownership.gleam`, `borrow.gleam`, `ffi_modes.gleam`, `owned_clone.gleam` | IR | IR | classify parameters (`Borrow`/`Owned`); insert **all** `OpRetain`/`OpDrop` | create tail calls; know the backend |
| `cps` | `cps.gleam` | IR | IR | split blocks at `OpSuspend` **and at non-tail calls between dispatcher members**, so control flow (suspend and member return) is explicit | insert retain/drop |
| `plan` | `plan.gleam` | IR | `plan.Plan` | compute tail-call edges, mutual groups, frames, states | mutate the IR |
| `llvm` | `llvm.gleam` | IR + Plan | LLVM IR text | render IR, dispatchers, state machines | invent retain/release or tail calls |

## The contract (invariants)

1. **Tail position is decided in `lower`.** No layer after `lower` creates a
   `Tailcall`/`TailcallIndirect`; `cps` only splits, `plan` only plans, the
   backends only render.
2. **`ownership` is the sole producer of `OpRetain`/`OpDrop`.** The backends
   render them; they never synthesise a retain/release or a teardown. If a value
   needs a reference-count operation, it must be visible to `ownership`.
3. **`plan` is pure and deterministic.** It reads the IR and an explicit
   environment, changes no IR, and its output depends only on its input.
4. **`mono` is the only layer that lifts lambdas.** Later layers see lifted
   functions, never `ELambda`.
5. **Machine membership is a planning decision.** Which functions become state
   machines / dispatchers belongs to `plan`; the backend consumes that decision.

## Artifacts and how to inspect them

| Artifact | How |
|---|---|
| AST (per layer) | not dumped |
| IR after `ownership` | `gleam run -- <file> --ir` (writes `<file>.ir`) |
| `plan.Plan` | `pipeline.compile_to_plan` / `plan.to_text` |
| LLVM IR | `gleam run -- <file>` (writes `<file>.ll`) |
| Behaviour vs the reference | `scripts/diff.sh` over `diffs/*.gleam` |

Each artifact is the evidence for a diagnosis: an ownership problem is read off
the `--ir` dump; a machine/grouping problem off the plan; a rendering problem off
the `.ll`.

## Known deviations (to fix)

These are cases where the current code does not respect the contract above. They
are listed so a change can move toward the contract instead of doubling down.

- **Group eligibility still carries backend constraints.** State-machine
  membership is now computed by `plan` (`plan.machines`) and consumed by the
  backend. Mutual tail-call *groups* are also planned, but the backend still
  filters them by emission constraints (matching return types, `group_ok`).
  Those constraints should move into `plan` as well.
- **Frame lifecycle is placed by the backend.** The frame is materialized in the
  IR (`OpFrameNew`) and `ownership` schedules its reference counts and frame
  claim; the backend emits the allocation and the frame drop at the machine
  boundary (wrapper or dispatcher return). This is deliberate: the result
  crosses the step/wrapper split inside the frame. See
  [frame-environment.md](frame-environment.md).
- **Non-tail calls between dispatcher members are still native calls.** `cps`
  already splits the block at each such call (giving a resume label) and the
  intended frame push/pop + heap return stack is specified in
  [machine.md](machine.md). The backend still emits `call`/`ret` through the
  member wrapper, so a call *into* the planned function from a member uses the
  native stack; landing the heap return stack removes that.
