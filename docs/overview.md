# gleamc — overview

`gleamc` is an independent compiler for a subset of the
[Gleam](https://gleam.run) language that targets **native code** instead of the
BEAM or JavaScript. It reads `.gleam` source, type-checks it, lowers it to a
small SSA-style IR, inserts explicit reference-count operations, and emits
**LLVM IR**. Every generated program links a small C runtime
(`runtime/gleam_runtime.[ch]`) that provides the refcount kernel, strings, bit
arrays, and a libuv-based asynchronous scheduler.

The project goals are:

- Deterministic memory management by reference counting — no tracing GC.
- Constant-stack tail calls, via a trampoline/state-machine lowering.
- A cooperative async runtime driven by libuv.
- Self-hosting: the compiler is written in the same Gleam subset it compiles
  (`src/gleamc/*.gleam`), and is meant to be buildable by either the official
  toolchain or by `gleamc` itself.

This document describes the shape of the project. For the pass order, each
layer's responsibility and its artifact see [cascade.md](cascade.md); for the
memory model see [memory.md](memory.md); for the tail-call and async machine see
[machine.md](machine.md); for the in-progress change that makes the function
frame the closure environment see [frame-environment.md](frame-environment.md);
for the current feature gaps see [known-limitations.md](known-limitations.md).

## The cascade

The pass order lives in `src/gleamc/pipeline.gleam`. Each pass consumes one
representation and produces the next; after the front end, the **IR** is the
only cross-pass currency. [cascade.md](cascade.md) defines each layer's
responsibility, artifact and invariants; this section is only a summary.

```
source
  -> lexer / parser      tokens -> AST
  -> opacity             check opaque-type usage across modules
  -> consts              expand compile-time constants
  -> merge               combine modules into one whole-program unit
  -> qualify             canonicalise constructor references
  -> aliases             expand type aliases (before specialisation)
  -> mono                monomorphise generics; lift lambdas
  -> dce                 prune functions unreachable from the entry point
  -> checker             type-check the monomorphic AST
  -> lower               AST -> IR (basic blocks, tail calls)
  -> ownership           infer borrow modes; insert retain/drop
  -> cps                 split blocks at suspension points
  -> backend             LLVM IR (llvm.gleam)
-> C / LLVM IR -> native binary
```

The stages that matter most for correctness are:

- **`mono`** (`mono.gleam`) removes all generics by instantiating each template
  at its concrete types, and lifts every lambda to a top-level function with an
  environment for its captured variables.
- **`lower`** (`lower.gleam`) walks the monomorphic AST and emits IR. Tail
  position is known here, so direct tail calls become `Tailcall` and calls
  through a function value in tail position become `TailcallIndirect`.
- **`ownership`** (`ownership.gleam` + `borrow.gleam`) is the memory-management
  pass. See [memory.md](memory.md).
- **`cps`** (`cps.gleam`) makes suspension explicit. See [machine.md](machine.md).
- **`plan`** (`plan.gleam`) is a pure, deterministic planner that turns the
  owned IR into the machine plan (frames, mutual groups, states). It does not
  change the IR.

## The IR

`src/gleamc/ir.gleam` defines a compact IR:

- `Module(functions)`.
- `Function(name, params, ret, blocks, locals)`.
- `Block(label, ops, term)`.
- `Op`: `OpConst`, `OpBinop`, `OpCall`, `OpBuiltin`, `OpCtor`, `OpField`,
  `OpTuple`, `OpCopy`, `OpClosure`, `OpEnvGet`, `OpCallIndirect`, `OpRetain`,
  `OpDrop`, `OpFrameNew`, `OpFrameGet`, `OpFrameSet`, `OpMachineStart`, …
- `Terminator`: `Jmp`, `Branch`, `Ret`, `Tailcall`, `TailcallIndirect`,
  `Suspend`, `TailMachine`, `Unreachable`.

Operands are either a local name (`Var`) or a literal (`Lit`). `OpRetain` and
`OpDrop` are inserted only by the ownership pass; after that pass the IR is a
complete, explicit description of every reference-count edge in the program.

## The backend

`src/gleamc/llvm.gleam` is the only backend: it emits textual **LLVM IR**,
including the tail-call dispatchers and the async state machines. It consumes
the owned IR and the `plan`; it only renders what the earlier layers produced.

## Repository layout

```
src/gleamc/     the compiler (Gleam)
src/gleamc.gleam, src/selfhost.gleam
                ecript entry points
std/            the standard library, written in Gleam, compiled by gleamc
runtime/        the C runtime kernel (refcount, strings, bit arrays, libuv)
diffs/          differential tests (see scripts/diff.sh)
samples/        small example programs
test/           the compiler's own test suite
docs/           this documentation
scripts/diff.sh differential harness
```

## Building and running

The project is a normal Gleam project, but building the emitted IR needs a C
toolchain and `mold` at runtime.

```sh
gleam run -- <file.gleam>            # compile to LLVM IR and build
gleam run -- <file.gleam> --ir       # dump the ownership-phase IR
gleam run -- <file.gleam> --run      # compile, build and run
gleam run -- <file.gleam> --release  # optimised build
gleam run -- smoke                   # end-to-end pipeline smoke test
gleam test                           # run the test suite
./scripts/diff.sh                    # differential test against the official toolchain
```

Building requires `clang` (or `gcc`) and `mold`; the runtime requires `libuv`,
`utf8proc`, and ICU.

Two environment variables control diagnostics:

- `GLEAMC_MEM_REPORT=1` prints the number of live allocations at exit; a correct
  program prints `gleamc: live blocks = 0`.
- `GLEAMC_RC_AUDIT=1` builds an instrumented binary that records every
  retain/release site and reports blocks whose refcount does not end at zero.

## Differential testing

`diffs/*.gleam` are programs that must print exactly the same stdout under
`gleamc` and under the official Gleam toolchain. `scripts/diff.sh` runs them all
and reports any mismatch. This is the main guard against semantic drift from the
reference implementation.
