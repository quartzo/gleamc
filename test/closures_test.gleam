import gleam/string
import gleamc/ffi
import gleamc/pipeline
import gleamc/toolchain

const dir = "/tmp/gleamc-closures"

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
  let #(compile_status, _compile_out) = toolchain.run_shell(cmd)
  assert compile_status == 0 as "generated C failed to compile"
  let #(_status, output) =
    toolchain.run_shell("env GLEAMC_MEM_REPORT=1 " <> dir <> "/" <> name)
  output
}

const source = "import gleam/io\nimport gleam/int\n\nfn make_adder(n: Int) -> fn(Int) -> Int {\n  fn(x) { x + n }\n}\n\nfn apply(f: fn(Int) -> Int, x: Int) -> Int {\n  f(x)\n}\n\npub fn main() {\n  let add5 = make_adder(5)\n  io.println(int.to_string(add5(10)))\n  io.println(int.to_string(apply(make_adder(100), 1)))\n}\n"

pub fn capturing_closure_test() {
  let output = compile_and_run("closure", source)
  assert string.contains(output, "15")
  assert string.contains(output, "101")
  assert string.contains(output, "live blocks = 0")
}
