import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

// `task.try_await` returns `Error(Exit(reason))` when the task was killed.
const source = "import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/otp/task

fn long() -> Int {
  time.timer(5000)
  1
}

pub fn main() {
  let t = task.async(fn() { long() })
  process.kill(task.pid(t))
  process.sleep(10)
  case task.try_await(t, 100) {
    Ok(_) -> io.println(\"await ok\")
    Error(task.Timeout) -> io.println(\"await timeout\")
    Error(task.Exit(_)) -> io.println(\"await exit\")
  }

  let u = task.async(fn() { 9 })
  process.sleep(10)
  case task.try_await(u, 100) {
    Ok(v) -> io.println(\"await value \" <> int.to_string(v))
    Error(task.Timeout) -> io.println(\"await timeout\")
    Error(task.Exit(_)) -> io.println(\"await exit\")
  }
  io.println(\"done\")
}
"

/// End-to-end: awaiting a killed task yields `AwaitError.Exit`.
pub fn await_exit_test() {
  let _ = ffi.run("mkdir -p /tmp/gleamc-test")
  let entry = "/tmp/gleamc-test/await_exit.gleam"
  let assert Ok(_) = ffi.write_file(entry, source)
  let assert Ok(modules) = loader.load(entry)
  let assert Ok(ll) = pipeline.compile_modules_llvm(modules)
  let ll_path = "/tmp/gleamc-test/await_exit.ll"
  let bin_path = "/tmp/gleamc-test/await_exit"
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
  assert string.contains(output, "await exit") as output
  assert string.contains(output, "await value 9") as output
  assert string.contains(output, "done") as output
}
