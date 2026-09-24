# gleamc

[![Package Version](https://img.shields.io/hexpm/v/gleamc)](https://hex.pm/packages/gleamc)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://gleamc.hexdocs.pm/)

```sh
gleam add gleamc@1
```
```gleam
import gleamc

pub fn main() -> Nil {
  // TODO: An example of the project in use
}
```

Further documentation can be found at <https://gleamc.hexdocs.pm/>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```

Start with [docs/overview.md](docs/overview.md) for what the project is and how
the compiler is organised, then [docs/memory.md](docs/memory.md) for the
refcount/ownership model and [docs/machine.md](docs/machine.md) for the
tail-call and async machine. See
[docs/known-limitations.md](docs/known-limitations.md) for the current status,
unsupported features, and how differential testing works.
