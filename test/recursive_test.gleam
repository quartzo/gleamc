import gleam/string
import gleamc/ffi
import gleamc/pipeline
import gleamc/toolchain

const dir = "/tmp/gleamc-recursive"

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
  let #(compile_status, _compile_out) = toolchain.run_shell(cmd)
  assert compile_status == 0 as "generated C failed to compile"
  let #(_status, output) =
    toolchain.run_shell("env GLEAMC_MEM_REPORT=1 " <> dir <> "/" <> name)
  output
}

const nat_source = "import gleam/int\nimport gleam/io\n\ntype Nat {\n  Suc(pred: Nat)\n  Zero\n}\n\nfn to_int(n: Nat) -> Int {\n  case n {\n    Suc(p) -> 1 + to_int(p)\n    Zero -> 0\n  }\n}\n\npub fn main() {\n  io.println(int.to_string(to_int(Suc(Suc(Suc(Zero))))))\n}\n"

pub fn recursive_nat_test() {
  let output = compile_and_run("nat", nat_source)
  assert string.contains(output, "3")
  assert string.contains(output, "live blocks = 0")
}

const generic_recursive_source = "import gleam/int\nimport gleam/io\n\ntype Chain(a) {\n  Link(value: a, next: Chain(a))\n  End\n}\n\nfn sum(c: Chain(Int)) -> Int {\n  case c {\n    Link(v, rest) -> v + sum(rest)\n    End -> 0\n  }\n}\n\npub fn main() {\n  io.println(int.to_string(sum(Link(1, Link(2, Link(3, End))))))\n}\n"

pub fn recursive_generic_test() {
  let output = compile_and_run("chain", generic_recursive_source)
  assert string.contains(output, "6")
  assert string.contains(output, "live blocks = 0")
}

const recursive_string_source = "import gleam/io\n\ntype Chain(a) {\n  Link(value: a, next: Chain(a))\n  End\n}\n\nfn first(c: Chain(a), default: a) -> a {\n  case c {\n    Link(v, _) -> v\n    End -> default\n  }\n}\n\npub fn main() {\n  let chain = Link(\"hello\", Link(\"world\", End))\n  io.println(first(chain, \"none\"))\n}\n"

pub fn recursive_string_test() {
  let output = compile_and_run("chain_str", recursive_string_source)
  assert string.contains(output, "hello")
  assert string.contains(output, "live blocks = 0")
}
