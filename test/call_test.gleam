import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

// `call`/`call_forever`, `deselect_specific_monitor` and `flush_messages`.
const source = "import gleam/erlang/process
import gleam/int
import gleam/io

pub type Msg {
  Ping(reply: Subject(Int))
}

fn server(ready: Subject(Subject(Msg))) -> Nil {
  let inbox = process.new_subject()
  process.send(ready, inbox)
  case process.receive_forever(from: inbox) {
    Ping(reply) -> process.send(reply, 42)
  }
}

pub fn main() {
  let ready = process.new_subject()
  let _ = process.spawn(fn() { server(ready) })
  let inbox = process.receive_forever(from: ready)
  let result =
    process.call(inbox, waiting: 1000, sending: fn(reply) { Ping(reply) })
  io.println(\"call \" <> int.to_string(result))

  let s = process.new_subject()
  process.send(s, 1)
  process.send(s, 2)
  process.flush_messages()
  case process.receive(from: s, within: 10) {
    Ok(_) -> io.println(\"unexpected\")
    Error(_) -> io.println(\"flushed\")
  }

  let pid = process.spawn(fn() { time.timer(20) })
  let mon = process.monitor(pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(mon, fn(_) { \"specific\" })
    |> process.deselect_specific_monitor(mon)
    |> process.select_monitors(fn(_) { \"any\" })
  io.println(process.selector_receive_forever(from: selector))
  io.println(\"done\")
}
"

/// End-to-end: request/reply via `call`, `flush_messages`, and
/// `deselect_specific_monitor`.
pub fn call_and_message_helpers_test() {
  let _ = ffi.run("mkdir -p /tmp/gleamc-test")
  let entry = "/tmp/gleamc-test/call.gleam"
  let assert Ok(_) = ffi.write_file(entry, source)
  let assert Ok(modules) = loader.load(entry)
  let assert Ok(ll) = pipeline.compile_modules_llvm(modules)
  let ll_path = "/tmp/gleamc-test/call.ll"
  let bin_path = "/tmp/gleamc-test/call"
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
  assert string.contains(output, "call 42") as output
  assert string.contains(output, "flushed") as output
  assert string.contains(output, "any") as output
  assert string.contains(output, "done") as output
}
