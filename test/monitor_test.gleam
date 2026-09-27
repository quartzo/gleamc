import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

// Monitors deliver a `Down` to the monitoring process's inbox; trapped exits
// deliver an `ExitMessage` for a linked process. The runtime builds the typed
// values via backend-emitted constructor helpers.
const source = "import gleam/erlang/process
import gleam/io

fn short() -> Nil {
  time.timer(20)
}

fn handle_down(down: Down) -> Nil {
  case down {
    ProcessDown(_, _, _) -> io.println(\"down\")
  }
}

fn handle_exit(message: ExitMessage) -> Nil {
  case message {
    ExitMessage(_, _) -> io.println(\"exit\")
  }
}

pub fn main() {
  let pid = process.spawn(fn() { short() })
  let _monitor = process.monitor(pid)
  let down_selector =
    process.new_selector() |> process.select_monitors(mapping: handle_down)
  process.selector_receive_forever(from: down_selector)

  process.trap_exits(True)
  let linked = process.spawn(fn() { short() })
  let _ = process.link(linked)
  let exit_selector =
    process.new_selector() |> process.select_trapped_exits(handler: handle_exit)
  process.selector_receive_forever(from: exit_selector)

  let specific_pid = process.spawn(fn() { short() })
  let specific_monitor = process.monitor(specific_pid)
  let specific_selector =
    process.new_selector()
    |> process.select_specific_monitor(specific_monitor, fn(down) {
      case down {
        ProcessDown(_, _, _) -> \"specific\"
      }
    })
  io.println(process.selector_receive_forever(from: specific_selector))

  io.println(\"done\")
}
"

/// End-to-end: `monitor`/`select_monitors` and `link`/`trap_exits`/
/// `select_trapped_exits`.
pub fn monitor_and_link_test() {
  let _ = ffi.run("mkdir -p /tmp/gleamc-test")
  let entry = "/tmp/gleamc-test/monitor.gleam"
  let assert Ok(_) = ffi.write_file(entry, source)
  let assert Ok(modules) = loader.load(entry)
  let assert Ok(ll) = pipeline.compile_modules_llvm(modules)
  let ll_path = "/tmp/gleamc-test/monitor.ll"
  let bin_path = "/tmp/gleamc-test/monitor"
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
  assert string.contains(output, "down") as output
  assert string.contains(output, "exit") as output
  assert string.contains(output, "specific") as output
  assert string.contains(output, "done") as output
}
