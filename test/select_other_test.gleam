import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

// `select_other` is a catch-all: it receives a message from any subject the
// process owns, even one the selector did not explicitly select.
const source = "import gleam/dynamic
import gleam/erlang/process
import gleam/int
import gleam/io

pub fn main() {
  let a = process.new_subject()
  let b = process.new_subject()
  process.send(b, \"hello\")
  process.send(a, 10)
  let selector =
    process.new_selector()
    |> process.select_map(for: a, mapping: fn(x) { int.to_string(x) })
    |> process.select_other(fn(d) { dynamic.unsafe_coerce(d) })
  io.println(process.selector_receive_forever(from: selector))
  io.println(process.selector_receive_forever(from: selector))
  io.println(\"done\")
}
"

/// End-to-end: `select_other` catches a message on an unselected subject.
pub fn select_other_test() {
  let _ = ffi.run("mkdir -p /tmp/gleamc-test")
  let entry = "/tmp/gleamc-test/select_other.gleam"
  let assert Ok(_) = ffi.write_file(entry, source)
  let assert Ok(modules) = loader.load(entry)
  let assert Ok(ll) = pipeline.compile_modules_llvm(modules)
  let ll_path = "/tmp/gleamc-test/select_other.ll"
  let bin_path = "/tmp/gleamc-test/select_other"
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
  assert string.contains(output, "10") as output
  assert string.contains(output, "hello") as output
  assert string.contains(output, "done") as output
}
