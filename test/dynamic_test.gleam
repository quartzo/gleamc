import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

// `gleam/dynamic` (`from`/`classify`/`int`/`string`/`bool`) and an
// `ExitReason.Abnormal(Dynamic)` carried through `send_abnormal_exit`.
const source = "import gleam/dynamic
import gleam/erlang/process
import gleam/int
import gleam/io

fn trapper() -> Nil {
  process.trap_exits(True)
  let s =
    process.new_selector()
    |> process.select_trapped_exits(fn(m) {
      case m {
        ExitMessage(_, reason) ->
          case reason {
            Normal -> \"normal\"
            Killed -> \"killed\"
            Abnormal(r) ->
              case dynamic.string(r) {
                Ok(text) -> \"abnormal:\" <> text
                Error(_) -> \"abnormal:?\"
              }
          }
      }
    })
  io.println(process.selector_receive_forever(from: s))
}

pub fn main() {
  io.println(int.to_string(dynamic.classify(dynamic.from(1))))
  case dynamic.int(dynamic.from(7)) {
    Ok(v) -> io.println(int.to_string(v))
    Error(_) -> io.println(\"bad int\")
  }
  case dynamic.string(dynamic.from(\"hi\")) {
    Ok(v) -> io.println(v)
    Error(_) -> io.println(\"bad string\")
  }
  case dynamic.bool(dynamic.from(False)) {
    Ok(v) -> io.println(bool.to_string(v))
    Error(_) -> io.println(\"bad bool\")
  }
  case dynamic.int(dynamic.from(\"x\")) {
    Ok(_) -> io.println(\"bad type\")
    Error(_) -> io.println(\"type error ok\")
  }

  let t = process.spawn(fn() { trapper() })
  process.sleep(10)
  process.send_abnormal_exit(t, \"boom\")
  process.sleep(50)
  io.println(\"done\")
}
"

/// End-to-end: dynamic construction/classification and an abnormal exit reason.
pub fn dynamic_test() {
  let _ = ffi.run("mkdir -p /tmp/gleamc-test")
  let entry = "/tmp/gleamc-test/dynamic.gleam"
  let assert Ok(_) = ffi.write_file(entry, source)
  let assert Ok(modules) = loader.load(entry)
  let assert Ok(ll) = pipeline.compile_modules_llvm(modules)
  let ll_path = "/tmp/gleamc-test/dynamic.ll"
  let bin_path = "/tmp/gleamc-test/dynamic"
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
  assert string.contains(output, "0") as output
  assert string.contains(output, "7") as output
  assert string.contains(output, "hi") as output
  assert string.contains(output, "False") as output
  assert string.contains(output, "type error ok") as output
  assert string.contains(output, "abnormal:boom") as output
  assert string.contains(output, "done") as output
}
