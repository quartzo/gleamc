import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

// Selectors (`new_selector`/`select`/`selector_receive*`) and scheduled sends
// (`send_after`/`cancel_timer`).
const source = "import gleam/erlang/process
import gleam/int
import gleam/io

pub fn main() {
  let a = process.new_subject()
  let b = process.new_subject()
  process.send(b, 10)
  process.send(a, 20)
  let selector =
    process.new_selector()
    |> process.select(for: a)
    |> process.select(for: b)
  io.println(int.to_string(process.selector_receive_forever(from: selector)))

  let c = process.new_subject()
  let empty = process.new_selector() |> process.select(for: c)
  case process.selector_receive(from: empty, within: 20) {
    Ok(_) -> io.println(\"unexpected\")
    Error(_) -> io.println(\"timeout\")
  }

  let d = process.new_subject()
  let _timer = process.send_after(d, 20, 99)
  io.println(int.to_string(process.receive_forever(from: d)))

  let e = process.new_subject()
  let timer = process.send_after(e, 1000, 1)
  case process.cancel_timer(timer) {
    Cancelled(_) -> io.println(\"cancelled\")
    TimerNotFound -> io.println(\"not found\")
  }
  case process.receive(from: e, within: 30) {
    Ok(_) -> io.println(\"unexpected\")
    Error(_) -> io.println(\"nothing\")
  }
}
"

/// End-to-end: a selector picks the queued subject (scan order) or times out,
/// `send_after` delivers later, and `cancel_timer` stops a pending send.
pub fn selector_and_timer_test() {
  let _ = ffi.run("mkdir -p /tmp/gleamc-test")
  let entry = "/tmp/gleamc-test/selector.gleam"
  let assert Ok(_) = ffi.write_file(entry, source)
  let assert Ok(modules) = loader.load(entry)
  let assert Ok(ll) = pipeline.compile_modules_llvm(modules)
  let ll_path = "/tmp/gleamc-test/selector.ll"
  let bin_path = "/tmp/gleamc-test/selector"
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
  assert string.contains(output, "20") as output
  assert string.contains(output, "timeout") as output
  assert string.contains(output, "99") as output
  assert string.contains(output, "cancelled") as output
  assert string.contains(output, "nothing") as output
}
