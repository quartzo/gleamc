//// Self-host entry point: compiles the compiler with itself.
////
//// Kept separate from `gleamc.gleam` so the generated C path
//// (`src/selfhost.c`) does not collide with the `gleamc/` directory.

import gleamc/cli

pub fn main() -> Nil {
  cli.main()
}
