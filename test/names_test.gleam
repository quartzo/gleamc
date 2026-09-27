import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

// Names: `new_name`, `register`, `named_subject`, `named`, `unregister`.
const source = "import gleam/erlang/process
import gleam/io

fn server(inbox: Subject(String)) -> Nil {
  let message = process.receive_forever(from: inbox)
  io.println(message)
}

pub fn main() {
  let name = process.new_name(\"server\")
  let pid = process.spawn(fn() { server(process.named_subject(name)) })
  case process.register(pid, name) {
    Ok(_) -> io.println(\"registered\")
    Error(_) -> io.println(\"register failed\")
  }
  case process.named(name) {
    Ok(_) -> io.println(\"named ok\")
    Error(_) -> io.println(\"named err\")
  }
  process.send(process.named_subject(name), \"hi\")
  time.timer(20)
  case process.unregister(name) {
    Ok(_) -> io.println(\"unregistered\")
    Error(_) -> io.println(\"unregister failed\")
  }
}
"

/// End-to-end: create a name, register a process, look it up, send through its
/// named subject and un-register.
pub fn names_test() {
  let _ = ffi.run("mkdir -p /tmp/gleamc-test")
  let entry = "/tmp/gleamc-test/names.gleam"
  let assert Ok(_) = ffi.write_file(entry, source)
  let assert Ok(modules) = loader.load(entry)
  let assert Ok(ll) = pipeline.compile_modules_llvm(modules)
  let ll_path = "/tmp/gleamc-test/names.ll"
  let bin_path = "/tmp/gleamc-test/names"
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
  assert string.contains(output, "registered") as output
  assert string.contains(output, "named ok") as output
  assert string.contains(output, "hi") as output
  assert string.contains(output, "unregistered") as output
}
