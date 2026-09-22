import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

const dir = "/tmp/gleamc-ctor-scope"

const a_source = "pub type A {\n  Empty\n  AVal(value: Int)\n}\n\npub fn describe_a(x: A) -> Int {\n  case x {\n    Empty -> 0\n    AVal(n) -> n\n  }\n}\n"

const b_source = "pub type B {\n  Empty\n  BVal(value: Int)\n}\n\npub fn describe_b(x: B) -> Int {\n  case x {\n    Empty -> 100\n    BVal(n) -> n\n  }\n}\n"

const main_source = "import gleam/int\nimport gleam/io\nimport a\nimport b\n\nfn from_a(x: a.A) -> Int {\n  case x {\n    a.Empty -> 0\n    a.AVal(n) -> n\n  }\n}\n\npub fn main() {\n  io.println(int.to_string(from_a(a.Empty)))\n  io.println(int.to_string(b.describe_b(b.Empty)))\n  io.println(int.to_string(from_a(a.AVal(3))))\n}\n"

pub fn cross_module_constructors_test() {
  let _ = ffi.run("mkdir -p " <> dir)
  let assert Ok(_) = ffi.write_file(dir <> "/a.gleam", a_source)
  let assert Ok(_) = ffi.write_file(dir <> "/b.gleam", b_source)
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
  assert compile_status == 0 as "cross-module program failed to compile"

  let #(_status, output) =
    toolchain.run_shell("env GLEAMC_MEM_REPORT=1 " <> dir <> "/main")
  assert string.contains(output, "0")
  assert string.contains(output, "100")
  assert string.contains(output, "3")
  assert string.contains(output, "live blocks = 0")
}
