import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

const dir = "/tmp/gleamc-option"

const source = "import gleam/io\nimport gleam/int\nimport gleam/option\nimport gleam/result\n\npub fn main() {\n  let mapped = option.map(Some(1), fn(x) { x + 1 })\n  io.println(int.to_string(option.unwrap_or(mapped, 0)))\n  io.println(int.to_string(option.unwrap_or(None, 42)))\n  let doubled = result.map(Ok(20), fn(x) { x * 2 })\n  io.println(int.to_string(result.unwrap_or(doubled, 0)))\n}\n"

pub fn option_result_test() {
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
  assert compile_status == 0 as "option/result program failed to compile"
  let #(_status, output) =
    toolchain.run_shell("env GLEAMC_MEM_REPORT=1 " <> dir <> "/main")
  assert string.contains(output, "2")
  assert string.contains(output, "42")
  assert string.contains(output, "40")
  assert string.contains(output, "live blocks = 0")
}
