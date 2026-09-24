import gleam/string
import gleamc/ffi
import gleamc/pipeline
import gleamc/toolchain

const dir = "/tmp/gleamc-generic"

fn compile_and_run(name: String, source: String) -> String {
  let _ = ffi.run("mkdir -p " <> dir)
  let assert Ok(ll_code) = pipeline.compile_to_llvm(source)
  let assert Ok(_) = ffi.write_file(dir <> "/" <> name <> ".ll", ll_code)
  let cmd =
    toolchain.build_command(
      toolchain.default_cc(),
      toolchain.Debug,
      [dir <> "/" <> name <> ".ll", "runtime/gleam_runtime.c"],
      ["runtime"],
      dir <> "/" <> name,
    )
  let #(compile_status, compile_out) = toolchain.run_shell(cmd)
  assert compile_status == 0 as "generated C failed to compile"
  let _ = compile_out
  let #(_status, output) =
    toolchain.run_shell("env GLEAMC_MEM_REPORT=1 " <> dir <> "/" <> name)
  output
}

const generic_source = "import gleam/io\n\ntype Wrapped(a) {\n  Wrapped(value: a)\n  Empty\n}\n\nfn unwrap(w: Wrapped(a), default: a) -> a {\n  case w {\n    Wrapped(v) -> v\n    Empty -> default\n  }\n}\n\npub fn main() {\n  io.println(unwrap(Wrapped(\"hi\"), \"none\"))\n  io.println(int.to_string(unwrap(Wrapped(7), 0)))\n  io.println(unwrap(Empty, \"fallback\"))\n}\n"

pub fn generic_end_to_end_test() {
  let output = compile_and_run("generic", generic_source)
  assert string.contains(output, "hi")
  assert string.contains(output, "7")
  assert string.contains(output, "fallback")
  assert string.contains(output, "live blocks = 0")
}
