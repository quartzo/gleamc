import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/parser
import gleamc/pipeline
import gleamc/toolchain

const dir = "/tmp/gleamc-mod"

const math_source = "pub fn add(a: Int, b: Int) -> Int {\n  a + b\n}\n"

const main_source = "import math\nimport gleam/io\n\npub fn main() {\n  io.println(int.to_string(math.add(20, 22)))\n}\n"

pub fn module_merge_test() {
  let assert Ok(math_module) = parser.parse(math_source)
  let assert Ok(main_module) = parser.parse(main_source)
  let assert Ok(c_code) =
    pipeline.compile_modules([#("", main_module), #("math", math_module)])
  assert string.contains(c_code, "Gleamc_math_add")
  assert string.contains(c_code, "Gleamc_main")
}

pub fn module_end_to_end_test() {
  let _ = ffi.run("mkdir -p " <> dir)
  let assert Ok(_) = ffi.write_file(dir <> "/math.gleam", math_source)
  let assert Ok(_) = ffi.write_file(dir <> "/main.gleam", main_source)

  let assert Ok(modules) = loader.load(dir <> "/main.gleam")
  let assert Ok(c_code) = pipeline.compile_modules(modules)
  let assert Ok(_) = ffi.write_file(dir <> "/main.c", c_code)

  let cmd =
    toolchain.build_command(
      toolchain.default_cc(),
      toolchain.Debug,
      [dir <> "/main.c", "runtime/gleam_runtime.c"],
      ["runtime"],
      dir <> "/main",
    )
  let #(compile_status, _compile_out) = toolchain.run_shell(cmd)
  assert compile_status == 0 as "module program failed to compile"

  let #(run_status, output) = toolchain.run_shell(dir <> "/main")
  assert run_status == 0
  assert string.trim(output) == "42"
}
