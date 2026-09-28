import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

// A named async function used as a first-class value: `let f = wait_and` then
// `f(41)`. The call is devirtualised to a direct call to `wait_and`, so the
// asyncness fixpoint sees it and the caller becomes async too.
const source = "import gleam/int
import gleam/io
import gleam/result

fn wait_and(v: Int) -> Int {
  time.timer(1)
  v
}

pub fn main() {
  let f = wait_and
  io.println(int.to_string(f(41)))

  let doubled = {
    use x <- result.try(Ok(21))
    Ok(wait_and(x) * 2)
  }
  case doubled {
    Ok(v) -> io.println(int.to_string(v))
    Error(_) -> io.println(\"error\")
  }

  let base = 40
  let summed = {
    use x <- result.try(Ok(2))
    Ok(wait_and(base) + x + 1)
  }
  case summed {
    Ok(v) -> io.println(int.to_string(v))
    Error(_) -> io.println(\"error\")
  }

  time.timer(1)
}
"

/// End-to-end: a first-class named async function called through a local.
pub fn first_class_async_test() {
  let _ = ffi.run("mkdir -p /tmp/gleamc-test")
  let entry = "/tmp/gleamc-test/first_class_async.gleam"
  let assert Ok(_) = ffi.write_file(entry, source)
  let assert Ok(modules) = loader.load(entry)
  let assert Ok(ll) = pipeline.compile_modules_llvm(modules)
  let ll_path = "/tmp/gleamc-test/first_class_async.ll"
  let bin_path = "/tmp/gleamc-test/first_class_async"
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
  assert string.contains(output, "41") as output
  assert string.contains(output, "42") as output
  assert string.contains(output, "43") as output
}
