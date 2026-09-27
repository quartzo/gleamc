# Gleamc — the Gleam compiler

An ahead-of-time compiler for a subset of [Gleam](https://gleam.run) that
targets **native code**: it emits LLVM IR and links a small C runtime (libuv
for async). It is not a BEAM or JavaScript backend.

## Documentation

- [docs/overview.md](docs/overview.md) — what the project is and how the
  compiler is organised.
- [docs/manual/](docs/manual/README.md) — the implemented language and APIs.
- [docs/memory.md](docs/memory.md) — the refcount/ownership model.
- [docs/machine.md](docs/machine.md) — the tail-call and async machine.
- [docs/known-limitations.md](docs/known-limitations.md) — current status and
  unsupported features.
- [docs/roadmap.md](docs/roadmap.md) — the plan to close the remaining gaps.

## Development

```sh
gleam run   # run the compiler
gleam test  # run the tests
```

Differential testing runs every `diffs/*.gleam` under both Gleamc and the
official Gleam toolchain and compares stdout:

```sh
./scripts/diff.sh
```
