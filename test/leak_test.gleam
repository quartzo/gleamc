import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

const dir = "/tmp/gleamc-leak"

/// Regression: a borrow-only field extracted from a parameter in a nested
/// pattern (`[first, second, ..rest]`) must be a view (no retain/drop), and its
/// container must stay alive while the view is used. This used to leak a node.
const source = "import gleam/int\nimport gleam/io\nimport gleam/list\n\nfn count_pairs(xs: List(Int)) -> Int {\n  list.length(list.window_by_2(xs))\n}\n\npub fn main() {\n  io.println(int.to_string(count_pairs([1, 2, 3, 4])))\n}\n"

pub fn leak_window_by_2_test() {
  let _ = ffi.run("mkdir -p " <> dir)
  let assert Ok(_) = ffi.write_file(dir <> "/main.gleam", source)
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
  assert compile_status == 0 as "program failed to compile"

  let #(_status, output) =
    toolchain.run_shell("env GLEAMC_MEM_REPORT=1 " <> dir <> "/main")
  assert string.contains(output, "3")
  assert string.contains(output, "live blocks = 0")
}
