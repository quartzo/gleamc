import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

const dir = "/tmp/gleamc-std"

const source = "import gleam/int\nimport gleam/io\nimport gleam/list\n\nfn double(x: Int) -> Int {\n  x * 2\n}\n\npub fn main() {\n  let xs = [1, 2, 3]\n  io.println(int.to_string(list.length(xs)))\n  io.println(int.to_string(list.sum(xs)))\n  io.println(int.to_string(list.sum(list.reverse(xs))))\n  io.println(int.to_string(list.sum(list.map(xs, double))))\n  io.println(int.to_string(list.sum(list.map(xs, fn(x) { x * 2 }))))\n  io.println(int.to_string(list.sum(list.filter(xs, fn(x) { x > 1 }))))\n}\n"

pub fn std_list_test() {
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
  assert compile_status == 0 as "stdlib program failed to compile"

  let #(_status, output) =
    toolchain.run_shell("env GLEAMC_MEM_REPORT=1 " <> dir <> "/main")
  assert string.contains(output, "3")
  assert string.contains(output, "6")
  assert string.contains(output, "12")
  assert string.contains(output, "5")
  assert string.contains(output, "live blocks = 0")
}
