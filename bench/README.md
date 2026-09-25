# bench

Compares the same `gleamc` compiler in two execution substrates, compiling the
same input and (for small inputs) emitting byte-identical LLVM IR:

| label    | how the compiler is built                | runs as              |
|----------|------------------------------------------|----------------------|
| `native` | `src/selfhost` — gleamc compiled to C    | a native ELF binary  |
| `beam`   | `gleam run` — gleamc compiled by the official Gleam to Erlang | BEAM (OTP JIT) |

`--cc=/bin/true` makes the compiler stop after emitting the `.ll`, so the
measurement is the **compiler itself**, not clang/linking. The comparison is
therefore about the substrate (native vs BEAM), not the output target.

## Usage

```sh
bench/compare.sh                 # hello mixloop
bench/compare.sh hello mixloop compiler
bench/compare.sh compiler        # only the compiler source (slow: ~2 min native)
N=3 bench/compare.sh mixloop     # 3 runs per measurement
```

Inputs:

- `hello` — small program.
- `mixloop` — tail-recursive 200M-iteration loop (data-dependent branch, so the
  backend cannot fold it).
- `compiler` — `src/selfhost.gleam`, the compiler compiling itself. Slow; forces
  one run. The native and BEAM `.ll` are equivalent but their `%__frame_*`
  declaration order differs.

Requirements: `python3`, the official `gleam` toolchain (for `beam`), and a
prebuilt `src/selfhost` (the script builds it if absent). Outputs (`.ll`) land
next to the sources and are gitignored.
