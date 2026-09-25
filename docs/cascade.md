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
  frame               IR               -> IR           (materialize heap frames)
  ownership           IR               -> IR           (borrow modes; retain/drop)
  backend             IR               -> LLVM IR
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
| `frame` | `frame.gleam` | IR | IR | materialize the heap frame of capture/suspend functions | insert retain/drop |
| `ownership` | `ownership.gleam`, `borrow.gleam`, `ffi_modes.gleam`, `owned_clone.gleam` | IR | IR | classify parameters (`Borrow`/`Owned`); insert **all** `OpRetain`/`OpDrop` | create tail calls; know the backend |
| `llvm` | `llvm.gleam` | IR | LLVM IR text | render IR, `musttail` tail calls, frames | invent retain/release or tail calls |

## The contract (invariants)

1. **Tail position is decided in `lower`.** No layer after `lower` creates a
   `Tailcall`/`TailcallIndirect`; `frame` only materializes frames, the backend
   only renders. `musttail` is an emission choice, not a new tail call.
2. **`ownership` is the sole producer of `OpRetain`/`OpDrop`.** The backends
   render them; they never synthesise a retain/release or a teardown. If a value
   needs a reference-count operation, it must be visible to `ownership`.
3. **`mono` is the only layer that lifts lambdas.** Later layers see lifted
   functions, never `ELambda`.
4. **Frame membership is a single rule.** `frame.machine_functions` names the
   functions whose locals must live on the heap (a closure captures one of
   them, or — when async is restored — one is live across a suspension). The
   backend consumes that list. `plan.gleam`, the mutual tail-call dispatchers
   and the heap return stack were removed; tail calls are `musttail` calls
   (`tco-musttail-plan.md`).

## Artifacts and how to inspect them

| Artifact | How |
|---|---|
| AST (per layer) | not dumped |
| IR after `ownership` | `gleam run -- <file> --ir` (writes `<file>.ir`) |
| LLVM IR | `gleam run -- <file>` (writes `<file>.ll`) |
| Behaviour vs the reference | `scripts/diff.sh` over `diffs/*.gleam` |

Each artifact is the evidence for a diagnosis: an ownership problem is read off
the `--ir` dump; a rendering problem off the `.ll`.

## Known deviations (to fix)

- **Async is lowered inline.** `await` drives the libuv loop synchronously with
  `gleamc_future_wait` instead of suspending and handing the `Future` back to
  the loop. Restoring the state machine is stage 2 of the musttail plan, and is
  the intended home of `suspend_live_vars` in the frame.
- **Frame lifecycle placement.** `OpFrameNew`/`OpDrop(frame)` are visible to
  `ownership`; the backend still emits the allocation (`gleamc_alloc0`) and the
  frame teardown symbol. See [frame-environment.md](frame-environment.md).
