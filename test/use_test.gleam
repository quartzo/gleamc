import gleam/string
import gleamc/ffi
import gleamc/pipeline
import gleamc/toolchain

const dir = "/tmp/gleamc-use"

const source = "import gleam/io\nimport gleam/int\n\nfn with_value(x: Int, f: fn(Int) -> Int) -> Int {\n  f(x)\n}\n\npub fn main() {\n  let sum = {\n    use a <- with_value(10)\n    use b <- with_value(20)\n    a + b\n  }\n  io.println(int.to_string(sum))\n}\n"

const pattern_source = "import gleam/io\nimport gleam/int\n\nfn pair(f: fn(#(Int, Int)) -> Int) -> Int {\n  f(#(3, 4))\n}\n\npub fn main() {\n  let r = {\n    use #(a, b) <- pair\n    a + b\n  }\n  io.println(int.to_string(r))\n}\n"

pub fn use_pattern_test() {
  let _ = ffi.run("mkdir -p " <> dir)
  let assert Ok(c_code) = pipeline.compile_to_c(pattern_source)
  let assert Ok(_) = ffi.write_file(dir <> "/pattern.c", c_code)
  let cmd =
    toolchain.build_command(
      toolchain.default_cc(),
      toolchain.Debug,
      [dir <> "/pattern.c", "runtime/gleam_runtime.c"],
      ["runtime"],
      dir <> "/pattern",
    )
  let #(compile_status, _out) = toolchain.run_shell(cmd)
  assert compile_status == 0 as "use pattern program failed to compile"
  let #(_status, output) =
    toolchain.run_shell("env GLEAMC_MEM_REPORT=1 " <> dir <> "/pattern")
  assert string.contains(output, "7")
  assert string.contains(output, "live blocks = 0")
}

pub fn use_desugar_test() {
  let _ = ffi.run("mkdir -p " <> dir)
  let assert Ok(c_code) = pipeline.compile_to_c(source)
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
  assert compile_status == 0 as "use program failed to compile"
  let #(_status, output) =
    toolchain.run_shell("env GLEAMC_MEM_REPORT=1 " <> dir <> "/main")
  assert string.contains(output, "30")
  assert string.contains(output, "live blocks = 0")
}
