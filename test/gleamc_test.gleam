import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain
import gleeunit

const hello_source = "import gleam/io\n\npub fn main() {\n  io.println(\"Hello from gleamc!\")\n}\n"

const timer_source = "import gleam/io\n\npub fn main() {\n  io.println(\"inicio\")\n  let _ = time.timer(20)\n  io.println(\"fim\")\n}\n"

pub fn main() -> Nil {
  gleeunit.main()
}

/// End-to-end async base: `time.timer(ms)` is a real suspension driven by
/// the libuv loop (frame + step + `gleamc_sched_run`).
pub fn async_timer_test() {
  let _ = ffi.run("mkdir -p /tmp/gleamc-test")
  let entry = "/tmp/gleamc-test/async_timer.gleam"
  let assert Ok(_) = ffi.write_file(entry, timer_source)
  let assert Ok(modules) = loader.load(entry)
  let assert Ok(ll) = pipeline.compile_modules_llvm(modules)
  let ll_path = "/tmp/gleamc-test/async_timer.ll"
  let bin_path = "/tmp/gleamc-test/async_timer"
  let assert Ok(_) = ffi.write_file(ll_path, ll)
  let cmd =
    toolchain.build_command(
      toolchain.default_cc(),
      toolchain.Debug,
      [ll_path, "runtime/gleam_runtime.c"],
      ["runtime"],
      bin_path,
    )
  let #(compile_status, compile_out) = toolchain.run_shell(cmd)
  assert compile_status == 0 as compile_out
  let #(run_status, output) = toolchain.run_shell(bin_path)
  assert run_status == 0 as output
  assert string.contains(output, "inicio")
  assert string.contains(output, "fim")
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
    toolchain.build_command("clang", toolchain.Debug, ["a.ll"], ["inc"], "out")
  assert string.contains(cmd, "clang")
  assert string.contains(cmd, "-O0")
  assert string.contains(cmd, "-Iinc")
  assert string.contains(cmd, "a.ll")
  assert string.contains(cmd, "-o out")
}

pub fn build_command_release_test() {
  let cmd =
    toolchain.build_command("clang", toolchain.Release, ["a.ll"], [], "out")
  assert string.contains(cmd, "-O3 -march=native")
}

/// End-to-end: source -> C -> compile -> run.
pub fn pipeline_end_to_end_test() {
  let assert Ok(ll_code) = pipeline.compile_to_llvm(hello_source)
  assert string.contains(ll_code, "Gleamc_main")

  let _ = ffi.run("mkdir -p /tmp/gleamc-test")
  let ll_path = "/tmp/gleamc-test/hello.ll"
  let bin_path = "/tmp/gleamc-test/hello"
  let assert Ok(_) = ffi.write_file(ll_path, ll_code)

  let cmd =
    toolchain.build_command(
      toolchain.default_cc(),
      toolchain.Debug,
      [ll_path, "runtime/gleam_runtime.c"],
      ["runtime"],
      bin_path,
    )
  let #(compile_status, _compile_out) = toolchain.run_shell(cmd)
  assert compile_status == 0 as "generated C failed to compile"

  let #(run_status, out) = toolchain.run_shell(bin_path)
  assert run_status == 0
  assert string.trim(out) == "Hello from gleamc!"
}
