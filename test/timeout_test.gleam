import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

// `receive(from:, within:)` and `task.try_await(_, timeout)` race the message /
// task against a libuv timer.
const source = "import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/otp/task

fn slow() -> Int {
  time.timer(200)
  7
}

fn fast() -> Int {
  time.timer(1)
  9
}

pub fn main() {
  let subject = process.new_subject()
  process.send(subject, 5)
  case process.receive(from: subject, within: 100) {
    Ok(value) -> io.println(\"got \" <> int.to_string(value))
    Error(_) -> io.println(\"timeout\")
  }

  let empty = process.new_subject()
  case process.receive(from: empty, within: 20) {
    Ok(_) -> io.println(\"unexpected\")
    Error(_) -> io.println(\"timeout\")
  }

  let fast_task = task.async(fn() { fast() })
  case task.try_await(fast_task, 100) {
    Ok(value) -> io.println(\"await \" <> int.to_string(value))
    Error(_) -> io.println(\"await timeout\")
  }

  let slow_task = task.async(fn() { slow() })
  case task.try_await(slow_task, 20) {
    Ok(value) -> io.println(\"unexpected \" <> int.to_string(value))
    Error(_) -> io.println(\"await timeout\")
  }
  time.timer(300)
}
"

/// End-to-end: a queued message wins the race, an empty subject times out, and
/// `try_await` returns the value before the timeout or `Error(Timeout)`.
pub fn receive_and_await_timeout_test() {
  let _ = ffi.run("mkdir -p /tmp/gleamc-test")
  let entry = "/tmp/gleamc-test/timeout.gleam"
  let assert Ok(_) = ffi.write_file(entry, source)
  let assert Ok(modules) = loader.load(entry)
  let assert Ok(ll) = pipeline.compile_modules_llvm(modules)
  let ll_path = "/tmp/gleamc-test/timeout.ll"
  let bin_path = "/tmp/gleamc-test/timeout"
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
  assert string.contains(output, "got 5") as output
  assert string.contains(output, "timeout") as output
  assert string.contains(output, "await 9") as output
  assert string.contains(output, "await timeout") as output
}
