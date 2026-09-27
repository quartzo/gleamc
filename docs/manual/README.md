# gleamc language manual

This manual documents the Gleam **subset** that `gleamc` parses, type-checks
and compiles to native code. It describes what the compiler accepts **today**,
not the full Gleam language.

- Target: native code (LLVM IR + a small C runtime, libuv for async), not
  BEAM and not JavaScript.
- Programs written inside this subset also compile under the official Gleam
  toolchain; the `diffs/` suite checks that differential behaviour.
- For the list of things that are **not** implemented, and any known bugs, see
  [../known-limitations.md](../known-limitations.md).
- For the plan that closes the remaining idiomatic gaps, see
  [../roadmap.md](../roadmap.md).

## Contents

1. [Syntax, modules, declarations and types](01-syntax.md)
2. [Expressions](02-expressions.md)
3. [Patterns and `case`](03-patterns.md)
4. [Standard library](04-stdlib.md)
5. [Concurrency and tasks](05-concurrency.md)
6. [Toolchain and testing](06-toolchain.md)

## Running a program

```
gleam run -- path/to/main.gleam --run     # compile and run
gleam run -- path/to/main.gleam --ir      # dump the ownership-phase IR
gleam run -- path/to/main.gleam --quiet   # only the program's stdout
```

The entry module is the file given on the command line; its imports are pulled
in from `std/` (the bundled standard library). See
[06-toolchain.md](06-toolchain.md) for flags and environment variables.

## A first program

```gleam
import gleam/io

pub fn main() {
  io.println("Hello, Joe!")
}
```
