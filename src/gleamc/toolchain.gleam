//// C toolchain driver: compiler selection, flags and invocation.
////
//// Design decision: `clang -O0` in the dev loop (with `mold` for linking),
//// `clang/gcc -O3 -march=native` on release. `tcc` stays as an option
//// (`--cc=tcc`) for ultra-fast compilation.

import gleam/list
import gleam/string
import gleamc/ffi

pub type Mode {
  Debug
  Release
}

pub fn default_cc() -> String {
  case ffi.which("clang") {
    Ok(_) -> "clang"
    Error(_) ->
      case ffi.which("gcc") {
        Ok(_) -> "gcc"
        Error(_) -> "tcc"
      }
  }
}

fn opt_flag(mode: Mode) -> String {
  case mode {
    Debug -> "-O0"
    Release -> "-O3 -march=native"
  }
}

fn link_flag(cc: String) -> String {
  case cc {
    "tcc" -> ""
    _ -> " -fuse-ld=mold"
  }
}

fn include_flags(include_dirs: List(String)) -> String {
  include_dirs
  |> list.map(fn(dir) { "-I" <> dir })
  |> string.join(" ")
}

/// Builds the command that compiles/links an executable.
pub fn build_command(
  cc: String,
  mode: Mode,
  c_files: List(String),
  include_dirs: List(String),
  out: String,
) -> String {
  cc
  <> " -std=c11 "
  <> opt_flag(mode)
  <> " -w"
  <> link_flag(cc)
  <> " "
  <> include_flags(include_dirs)
  <> " "
  <> string.join(c_files, " ")
  <> " -lm"
  <> " -o "
  <> out
}

/// Runs a command in the shell → `#(exit_status, output)`.
pub fn run_shell(command: String) -> #(Int, String) {
  ffi.run(command)
}
