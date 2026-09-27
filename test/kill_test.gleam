import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

// `kill` terminates a task; a non-trapping link propagates the exit.
const source = "import gleam/erlang/process
import gleam/io

fn long() -> Nil {
  time.timer(5000)
}

fn killer(target: Pid) -> Nil {
  let _ = process.link(target)
  time.timer(20)
}

pub fn main() {
  let victim = process.spawn(fn() { long() })
  process.kill(victim)
  time.timer(10)
  case process.is_alive(victim) {
    True -> io.println(\"kill alive\")
    False -> io.println(\"kill dead\")
  }

  let linked = process.spawn(fn() { long() })
  let _ = process.spawn(fn() { killer(linked) })
  time.timer(100)
  case process.is_alive(linked) {
    True -> io.println(\"link alive\")
    False -> io.println(\"link dead\")
  }
}
"

/// End-to-end: `kill` and non-trapping link propagation.
pub fn kill_and_propagation_test() {
  let _ = ffi.run("mkdir -p /tmp/gleamc-test")
  let entry = "/tmp/gleamc-test/kill.gleam"
  let assert Ok(_) = ffi.write_file(entry, source)
  let assert Ok(modules) = loader.load(entry)
  let assert Ok(ll) = pipeline.compile_modules_llvm(modules)
  let ll_path = "/tmp/gleamc-test/kill.ll"
  let bin_path = "/tmp/gleamc-test/kill"
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
  assert string.contains(output, "kill dead") as output
  assert string.contains(output, "link dead") as output
}
