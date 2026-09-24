import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

const dir = "/tmp/gleamc-equality"

const source = "import gleam/bool\nimport gleam/io\n\ntype Point {\n  Point(x: Int, y: Int)\n}\n\npub fn main() {\n  io.println(bool.to_string(Point(1, 2) == Point(1, 2)))\n  io.println(bool.to_string(Point(1, 2) == Point(1, 3)))\n  io.println(bool.to_string([1, 2, 3] == [1, 2, 3]))\n  io.println(bool.to_string([1, 2, 3] == [1, 2, 4]))\n  io.println(bool.to_string(#(1, 2) == #(1, 2)))\n}\n"

pub fn equality_end_to_end_test() {
  let _ = ffi.run("mkdir -p " <> dir)
  let assert Ok(_) = ffi.write_file(dir <> "/main.gleam", source)
  let assert Ok(modules) = loader.load(dir <> "/main.gleam")
  let assert Ok(ll_code) = pipeline.compile_modules_llvm(modules)
  let assert Ok(_) = ffi.write_file(dir <> "/main.ll", ll_code)

  let cmd =
    toolchain.build_command(
      toolchain.default_cc(),
      toolchain.Debug,
      [dir <> "/main.ll", "runtime/gleam_runtime.c"],
      ["runtime"],
      dir <> "/main",
    )
  let #(compile_status, _compile_out) = toolchain.run_shell(cmd)
  assert compile_status == 0 as "generated C failed to compile"

  let #(_status, output) =
    toolchain.run_shell("env GLEAMC_MEM_REPORT=1 " <> dir <> "/main")
  assert string.contains(output, "True")
  assert string.contains(output, "False")
  assert string.contains(output, "live blocks = 0")
}
