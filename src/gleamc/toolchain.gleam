//// C toolchain driver: compiler selection, flags and invocation.
////
//// Design decision: `clang -O1` in the dev loop (with `mold` for linking),
//// `clang/gcc -O3 -march=native` on release. The `ssa` pass already emits SSA
//// registers and `phi`s for the promotable locals, so the frontend no longer
//// relies on the optimizer's `mem2reg`; `-O1` is kept for code quality (SROA,
//// instcombine, the register allocator) and not as a correctness requirement.
//// `-O0` is now viable — only the locals that genuinely need an address stay in
//// a slot (an `sret` result, `buffer.take`, frame/machine locals) — but it is
//// not the default.

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
        Error(_) -> "cc"
      }
  }
}

fn opt_flag(mode: Mode) -> String {
  case mode {
    Debug -> "-O1"
    Release -> "-O3 -march=native"
  }
}

/// `GLEAMC_RC_AUDIT=1` builds the runtime so it never frees on refcount 0 and
/// reports every block whose refcount ended <0 or >0.
fn audit_flag() -> String {
  case ffi.get_env("GLEAMC_RC_AUDIT") {
    Ok(_) -> " -DGLEAMC_RC_AUDIT"
    Error(_) -> ""
  }
}

fn link_flag(_cc: String) -> String {
  " -fuse-ld=mold"
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
  <> audit_flag()
  <> link_flag(cc)
  <> " "
  <> include_flags(include_dirs)
  <> " "
  <> string.join(c_files, " ")
  <> " -lm -lutf8proc -licuuc -luv"
  <> " -o "
  <> out
}

/// Runs a command in the shell → `#(exit_status, output)`.
pub fn run_shell(command: String) -> #(Int, String) {
  ffi.run(command)
}
