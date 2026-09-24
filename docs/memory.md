# Memory: reference counting and ownership

`gleamc` manages memory with deterministic reference counting. There is no
tracing garbage collector and no cycle collector: acyclic data is reclaimed
exactly, while reference cycles leak by design. This document describes where
the reference-count operations come from, how they are inserted, and how the
runtime implements them.

## The ownership pass

The memory decisions are made by `src/gleamc/ownership.gleam` together with
`src/gleamc/borrow.gleam`. The pass runs on the IR, between `lower` and `cps`.

Every local that holds a *handle* (`String`, `BitArray`, a function value, or a
data type that contains one) owns exactly one reference. The pass walks the
control-flow graph and, for each use of a handle, emits one of:

- `OpDrop` — release the reference at the local's death.
- `OpRetain` — add a reference because the same value is still needed after an
  owning use that is not the last one.

After the pass, every ownership edge in the program is explicit in the IR.
`OpRetain`/`OpDrop` are never emitted by any other pass, and the backends only
render them.

### Parameters: `Borrow` vs `Owned`

A parameter is classified as one of two modes:

- **`Borrow`** — the callee only reads it. The caller keeps ownership and passes
  the reference untouched (no retain, no drop).
- **`Owned`** — the callee consumes it (returns it, stores it, captures it, or
  hands it to another owning position). The caller transfers the reference and
  the callee releases it at its last use.

The classification is a **monotone fixpoint** (`borrow.analyze`): it starts
optimistic (every parameter `Borrow`) and upgrades a parameter to `Owned` as
soon as some path in the body consumes it. Direct calls use the callee's modes;
calls whose callee is not statically known (indirect calls, and functions taken
as values) must assume the owned ABI, because the callee is not known at the call
site.

Runtime builtins have no body to analyse, so their modes are declared explicitly
in `src/gleamc/ffi_modes.gleam` (for example `io.println` is `Borrow`,
`string.uppercase` is `Owned`).

Because a function may be named by both ordinary calls (where borrowing is
cheaper) and by tail or indirect calls (which need the owned ABI), the compiler
can emit an all-`Owned` clone of it for the owned sites (`owned_clone.gleam`)
while the original keeps its natural modes for ordinary calls. This avoids
degrading every caller of a function just because its value is taken once.

### Which types need dropping

`ownership.needs_drop` decides whether a local participates at all. Scalars
(`Int`, `Float`, `Bool`, `Nil`) and type variables do not. `String`, `BitArray`,
function values, tuples/ADTs that contain a handle, and recursive types do.

## The runtime kernel

The kernel lives in `runtime/gleam_runtime.[ch]`.

- Every allocation carries a `GleamcHdr` (`{ size_t refcount }`) immediately
  before the payload. `gleamc_alloc` returns the payload pointer with the header
  refcount set to 1.
- `gleamc_retain` / `gleamc_release` are inline macros: `+1`, and `-1` that
  calls the cold path `gleamc_release_slow` only when the count reaches zero.
  Both are NULL-safe.
- String literals live in read-only memory with a sentinel refcount
  (`GLEAMC_RC_STATIC`); retain/release are no-ops on them.

The generic entry points `Gleamc_rc_retain` / `Gleamc_rc_release` operate on a
payload pointer and take a compile-time *site* tag used only by the audit build.

## Generated glue

The backends generate per-type retain/drop (and equality, comparison and
inspection) glue from the same owned IR. The names are capitalised so they cannot
clash with generated user function names:

- `Gleamc_Rc_retain_<type>` / `Gleamc_Rc_drop_<type>` — recursive release of a
  structured value: release each handle field, then free the cell.
- `Gleamc_Eq_<type>`, `Gleamc_Cmp_<type>`, `Gleamc_Inspect_<type>` — structural
  `==`, ordering, and `inspect`.

`String` and `BitArray` use their own runtime helpers
(`gleamc_string_retain`/`release`, `Gleamc_bit_array_retain`/`release`).

## Function values and closures

A function value is a struct:

```c
typedef struct {
    <ret> (*code)(void* frame, <params>);
    void* frame;
    void (*env_drop)(void*);
} GleamFn_<signature>;
```

A closure references the **frame** of its definition site, not a copy of its
captures; reading a captured variable reads a slot of that frame (see
[frame-environment.md](frame-environment.md)). `retain` on a function value
bumps the frame; `drop` runs the frame's teardown, which drops the frame-owned
fields (the variables the frame keeps alive) at refcount 1->0 and then frees the
cell. The frame is a reference-counted composite, and its teardown is the
`env_drop` slot of the function value.

## Copy-on-write and in-place updates

Gleam values are immutable, so the compiler never mutates a value that might be
observed elsewhere. The ownership modes turn that into an explicit optimization
boundary:

- `Borrow` guarantees the caller keeps the value; the callee must not mutate it.
- `Owned` grants the callee the right to consume the value, which includes
  reusing its storage in place when it is uniquely owned.

A runtime builtin declared `Owned` in `ffi_modes.gleam` is therefore free to
update a uniquely-owned buffer without copying — the "write" half of
copy-on-write — while a shared value is never touched. `string.uppercase` and
`string.lowercase` are declared `Owned` for exactly this reason. Immutable
containers (`List`, `Dict`, `Set`) implement the same idea at the data-structure
level: they are persistent structures compiled to Gleam, where an update returns
a new value and shares the untouched parts.

## Checking memory behaviour

Two environment variables expose the memory behaviour:

- `GLEAMC_MEM_REPORT=1` prints `gleamc: live blocks = N` at exit. A correct,
  acyclic program prints `gleamc: live blocks = 0`. The test suite asserts this
  for representative programs.
- `GLEAMC_RC_AUDIT=1` builds an instrumented binary that records every
  retain/release site, disables freeing, and reports at exit any block whose
  refcount ends up negative (over-release) or positive (leak), together with the
  last site that touched it.

Cycles are not collected. A program that builds a cyclic `String`- or ADT-based
structure will report live blocks at exit; this is expected.
