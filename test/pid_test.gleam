import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

// `process.self`, `process.is_alive`, `process.spawn_unlinked` and `task.pid`.
const source = "import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/otp/task

fn work() -> Int {
  time.timer(1)
  5
}

pub fn main() {
  let me = process.self()
  case process.is_alive(me) {
    True -> io.println(\"alive\")
    False -> io.println(\"dead\")
  }

  let subject = process.new_subject()
  let _pid = process.spawn_unlinked(fn() { process.send(subject, 7) })
  case process.receive(from: subject, within: 200) {
    Ok(value) -> io.println(\"got \" <> int.to_string(value))
    Error(_) -> io.println(\"none\")
  }

  let t = task.async(fn() { work() })
  case process.is_alive(task.pid(t)) {
    True -> io.println(\"task alive\")
    False -> io.println(\"task dead\")
  }
  io.println(int.to_string(task.await_forever(t)))
  time.timer(20)
}
"

/// End-to-end: `self`/`is_alive`, `spawn_unlinked` and `task.pid`.
pub fn pid_test() {
  let _ = ffi.run("mkdir -p /tmp/gleamc-test")
  let entry = "/tmp/gleamc-test/pid.gleam"
  let assert Ok(_) = ffi.write_file(entry, source)
  let assert Ok(modules) = loader.load(entry)
  let assert Ok(ll) = pipeline.compile_modules_llvm(modules)
  let ll_path = "/tmp/gleamc-test/pid.ll"
  let bin_path = "/tmp/gleamc-test/pid"
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
  assert string.contains(output, "alive") as output
  assert string.contains(output, "got 7") as output
  assert string.contains(output, "task alive") as output
  assert string.contains(output, "5") as output
}
