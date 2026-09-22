import gleam/string
import gleamc/ffi
import gleamc/pipeline
import gleamc/toolchain
import gleeunit

const hello_source = "import gleam/io\n\npub fn main() {\n  io.println(\"Hello from gleamc!\")\n}\n"

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn run_echo_test() {
  let #(status, out) = ffi.run("echo hello")
  assert status == 0
  assert string.trim(out) == "hello"
}

pub fn which_clang_test() {
  case ffi.which("clang") {
    Ok(_) -> Nil
    Error(_) -> panic as "clang not found on PATH"
  }
}

pub fn build_command_flags_test() {
  let cmd =
    toolchain.build_command("clang", toolchain.Debug, ["a.c"], ["inc"], "out")
  assert string.contains(cmd, "clang")
  assert string.contains(cmd, "-O0")
  assert string.contains(cmd, "-Iinc")
  assert string.contains(cmd, "a.c")
  assert string.contains(cmd, "-o out")
}

pub fn build_command_release_test() {
  let cmd =
    toolchain.build_command("clang", toolchain.Release, ["a.c"], [], "out")
  assert string.contains(cmd, "-O3 -march=native")
}

/// End-to-end: source -> C -> compile -> run.
pub fn pipeline_end_to_end_test() {
  let assert Ok(c_code) = pipeline.compile_to_c(hello_source)
  assert string.contains(c_code, "Gleamc_main")

  let _ = ffi.run("mkdir -p /tmp/gleamc-test")
  let c_path = "/tmp/gleamc-test/hello.c"
  let bin_path = "/tmp/gleamc-test/hello"
  let assert Ok(_) = ffi.write_file(c_path, c_code)

  let cmd =
    toolchain.build_command(
      toolchain.default_cc(),
      toolchain.Debug,
      [c_path, "runtime/gleam_runtime.c"],
      ["runtime"],
      bin_path,
    )
  let #(compile_status, _compile_out) = toolchain.run_shell(cmd)
  assert compile_status == 0 as "generated C failed to compile"

  let #(run_status, out) = toolchain.run_shell(bin_path)
  assert run_status == 0
  assert string.trim(out) == "Hello from gleamc!"
}
