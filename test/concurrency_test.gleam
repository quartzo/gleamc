import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

// Uses the exact `gleam/erlang/process` and `gleam/otp/task` surface:
// `new_subject`, `send`, `receive_forever(from:)`, the labelled
// `receive(from:, within:)`, `spawn(fn() {...})` and `task.async`/`await`.
const source = "import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/otp/task

fn worker(out: Subject(Int), id: Int) -> Nil {
  time.timer(1)
  process.send(out, id * 10)
}

fn start(out: Subject(Int), from: Int, to: Int) -> Nil {
  case from < to {
    True -> {
      let _ = process.spawn(fn() { worker(out, from) })
      start(out, from + 1, to)
    }
    False -> Nil
  }
}

fn collect(out: Subject(Int), n: Int, acc: Int) -> Int {
  case n {
    0 -> acc
    _ -> {
      let value = process.receive_forever(from: out)
      collect(out, n - 1, acc + value)
    }
  }
}

fn square(x: Int) -> Int {
  time.timer(1)
  x * x
}

pub fn main() {
  let out = process.new_subject()
  start(out, 0, 32)
  io.println(int.to_string(collect(out, 32, 0)))

  let awaited = task.async(fn() { square(7) })
  io.println(int.to_string(task.await_forever(awaited)))

  process.send(out, 5)
  case process.receive(from: out, within: 100) {
    Ok(value) -> io.println(int.to_string(value))
    Error(_) -> io.println(\"timeout\")
  }
  time.timer(20)
}
"

/// End-to-end cooperative concurrency with the exact Gleam API: 32 spawned
/// tasks interleave on the libuv driver, results are awaited and messages are
/// boxed through subjects.
pub fn concurrency_mailbox_test() {
  let _ = ffi.run("mkdir -p /tmp/gleamc-test")
  let entry = "/tmp/gleamc-test/concurrency.gleam"
  let assert Ok(_) = ffi.write_file(entry, source)
  let assert Ok(modules) = loader.load(entry)
  let assert Ok(ll) = pipeline.compile_modules_llvm(modules)
  let ll_path = "/tmp/gleamc-test/concurrency.ll"
  let bin_path = "/tmp/gleamc-test/concurrency"
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
  // Sum of `id * 10` for id in 0..31.
  assert string.contains(output, "4960") as output
  // 7 * 7 from the awaited task.
  assert string.contains(output, "49") as output
  // The last message through the labelled `receive`.
  assert string.contains(output, "5") as output
}
