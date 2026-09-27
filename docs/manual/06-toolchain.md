# 6. Toolchain and testing

## Requirements

- `clang` (or `gcc`) and `mold` (recommended; the default linker is used when
  `mold` is absent) for linking.
- `libuv` (`-luv`), `utf8proc` (`-lutf8proc`), ICU (`-licuuc`).
- The compiler itself is a Gleam project and is built with the **official**
  Gleam toolchain (that dependency is not self-hosted yet).

## Building and running

```bash
gleam build                       # build the gleamc compiler
gleam run -- file.gleam --run     # compile file.gleam and run it
gleam run -- file.gleam --ir      # print the ownership-phase IR
gleam run -- file.gleam --quiet   # only the program's own stdout
```

The entry module is the file passed on the command line; its imports are
resolved from `std/`. There is no multi-package build.

### CLI

```
gleamc <file.gleam> [--cc=clang|gcc] [--release] [--run]
gleamc <file.gleam>            # emit LLVM IR
gleamc <file.gleam> --ir       # dump ownership-phase IR
gleamc smoke                   # end-to-end pipeline smoke test
gleamc --version
```

- Development builds use `clang -O1 -fuse-ld=mold`; `--release` uses
  `-O3 -march=native`.
- The compiler never shells out to the official toolchain at compile time; it
  emits LLVM IR and then invokes the C compiler to produce a native binary.

## Environment variables

| Variable | Effect |
|---|---|
| `GLEAMC_MEM_REPORT=1` | At exit, print `gleamc: live blocks = N`. A correct program prints `0`. |
| `GLEAMC_RC_AUDIT=1` | Build the runtime with `-DGLEAMC_RC_AUDIT`: never free on `rc=0`, and report every block whose refcount ended `<0` or `>0` with its allocation/touch site. Used to find leaks and double-frees. |
| `GLEAMC_PHASES=1` | Print the milliseconds spent in each compiler phase. |
| `GLEAMC_MONO_VERIFY=1` | Extra checks while monomorphising. |
| `GLEAMC_CALL_DEPTH=<n>` | Abort when the native call depth reaches `n` (names the deepest function). |
| `GLEAMC_BIGDICT_STATS=1` | Print `big_dict` copy-on-write counters. |

## Tests

```bash
gleam test          # unit + end-to-end tests (each compiles and runs a program)
./scripts/diff.sh   # differential: every diffs/*.gleam under gleamc and official Gleam
```

- `gleam test` runs the compiler over embedded programs, checks their output,
  and includes refcount/leak checks.
- `diff.sh` compiles each `diffs/*.gleam` with both toolchains and compares
  stdout, so the subset's behaviour stays aligned with official Gleam.

## Diagnostics

Errors name the file and, for type errors, the enclosing function and its
declaration line, e.g.:

```
app.gleam: at line 12, in function `f`: unknown variable `x`
```

There are no column-accurate spans or carets yet; backend and monomorphisation
errors carry less context than front-end ones.

## Self-host status

The compiler is written in the same subset it compiles, with the goal of being
buildable by `gleamc` itself. `src/gleamc/ffi.gleam` already uses `simplifile`
and the `host.*` builtins (backed by `src/gleamc_ffi.erl` on the BEAM and the C
runtime's `Gleamc_host_*` under gleamc), so the remaining work is to keep
`std/simplifile.gleam` covering every call the compiler makes and to add a
self-host CI target. See [../known-limitations.md](../known-limitations.md) and
[../roadmap.md](../roadmap.md).
