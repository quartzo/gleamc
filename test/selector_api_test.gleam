import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

// `map_selector`, `merge_selector`, `subject_owner`/`subject_name` and
// `send_exit`.
const source = "import gleam/erlang/process
import gleam/int
import gleam/io

fn trapper() -> Nil {
  process.trap_exits(True)
  let s =
    process.new_selector()
    |> process.select_trapped_exits(fn(m) {
      case m {
        ExitMessage(_, _) -> \"child exit\"
      }
    })
  io.println(process.selector_receive_forever(from: s))
}

pub fn main() {
  let s = process.new_subject()
  case process.subject_name(s) {
    Ok(_) -> io.println(\"unnamed bad\")
    Error(_) -> io.println(\"unnamed\")
  }

  let name = process.new_name(\"greeter\")
  let _ = process.register(process.self(), name)
  let ns = process.named_subject(name)
  case process.subject_name(ns) {
    Ok(_) -> io.println(\"named\")
    Error(_) -> io.println(\"named bad\")
  }
  case process.subject_owner(ns) {
    Ok(_) -> io.println(\"owner\")
    Error(_) -> io.println(\"owner bad\")
  }

  let a = process.new_subject()
  process.send(a, 21)
  let mapped =
    process.new_selector()
    |> process.select(for: a)
    |> process.map_selector(fn(x) { x * 2 })
  io.println(int.to_string(process.selector_receive_forever(from: mapped)))

  let b = process.new_subject()
  let c = process.new_subject()
  process.send(c, 7)
  let s1 = process.new_selector() |> process.select(for: b)
  let s2 = process.new_selector() |> process.select(for: c)
  let merged = process.merge_selector(s1, s2)
  io.println(int.to_string(process.selector_receive_forever(from: merged)))

  let pid = process.spawn(fn() { trapper() })
  process.sleep(10)
  process.send_exit(pid)
  process.sleep(50)
  io.println(\"done\")
}
"

/// End-to-end: selector mapping/merging, subject owner/name and `send_exit`.
pub fn selector_api_test() {
  let _ = ffi.run("mkdir -p /tmp/gleamc-test")
  let entry = "/tmp/gleamc-test/selector_api.gleam"
  let assert Ok(_) = ffi.write_file(entry, source)
  let assert Ok(modules) = loader.load(entry)
  let assert Ok(ll) = pipeline.compile_modules_llvm(modules)
  let ll_path = "/tmp/gleamc-test/selector_api.ll"
  let bin_path = "/tmp/gleamc-test/selector_api"
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
  assert string.contains(output, "unnamed") as output
  assert string.contains(output, "named") as output
  assert string.contains(output, "owner") as output
  assert string.contains(output, "42") as output
  assert string.contains(output, "7") as output
  assert string.contains(output, "child exit") as output
  assert string.contains(output, "done") as output
}
