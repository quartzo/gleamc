import gleam/int
import gleam/string
import gleamc/ffi
import gleamc/pipeline
import gleamc/toolchain

const dir = "/tmp/gleamc-mem"

/// Compiles a program, runs it with leak reporting and returns the output.
fn compile_and_run(name: String, source: String) -> String {
  let _ = ffi.run("mkdir -p " <> dir)
  let assert Ok(c_code) = pipeline.compile_to_c(source)
  let assert Ok(_) = ffi.write_file(dir <> "/" <> name <> ".c", c_code)
  let cmd =
    toolchain.build_command(
      toolchain.default_cc(),
      toolchain.Debug,
      [dir <> "/" <> name <> ".c", "runtime/gleam_runtime.c"],
      ["runtime"],
      dir <> "/" <> name,
    )
  let #(compile_status, compile_out) = toolchain.run_shell(cmd)
  assert compile_status == 0 as "generated C failed to compile"
  let #(_run_status, output) =
    toolchain.run_shell("env GLEAMC_MEM_REPORT=1 " <> dir <> "/" <> name)
  // keep the compiler quiet about the unused variable in the failure message
  let _ = compile_out
  output
}

fn live_blocks(output: String) -> Int {
  // reads the integer at the end of "gleamc: live blocks = N"
  let line = case
    list_find(string.split(output, "\n"), fn(line) {
      string.contains(line, "live blocks =")
    })
  {
    Ok(found) -> found
    Error(_) -> ""
  }
  let digits =
    line
    |> string.split("=")
    |> list_last
    |> string.trim
  case int.parse(digits) {
    Ok(value) -> value
    Error(_) -> -1
  }
}

fn list_find(items, predicate) {
  case items {
    [] -> Error(Nil)
    [item, ..rest] ->
      case predicate(item) {
        True -> Ok(item)
        False -> list_find(rest, predicate)
      }
  }
}

fn list_last(items) {
  case items {
    [] -> ""
    [only] -> only
    [_, ..rest] -> list_last(rest)
  }
}

pub fn memory_string_concat_test() {
  let source =
    "import gleam/io\n\npub fn main() {\n  let a = \"hello\"\n  let b = \" world\"\n  io.println(a <> b)\n}\n"
  let output = compile_and_run("concat", source)
  assert string.contains(output, "hello world")
  assert live_blocks(output) == 0
}

pub fn memory_extract_field_test() {
  let source =
    "import gleam/io\n\ntype Box {\n  Box(value: String)\n}\n\nfn unbox(b: Box) -> String {\n  case b {\n    Box(v) -> v\n  }\n}\n\npub fn main() {\n  io.println(unbox(Box(\"hi\")))\n}\n"
  let output = compile_and_run("unbox", source)
  assert string.contains(output, "hi")
  assert live_blocks(output) == 0
}

pub fn memory_retain_shared_test() {
  let source =
    "import gleam/io\n\nfn dup(s: String) -> #(String, String) {\n  #(s, s)\n}\n\npub fn main() {\n  let pair = dup(\"x\")\n  let #(x, y) = pair\n  io.println(x)\n  io.println(y)\n}\n"
  let output = compile_and_run("dup", source)
  assert live_blocks(output) == 0
}
