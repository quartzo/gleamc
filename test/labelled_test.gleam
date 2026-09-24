import gleam/string
import gleamc/ast.{
  Arm, DFunction, EBlock, ECase, Function, Module, PCtor, PLabelled, PVar, Stmt,
}
import gleamc/ffi
import gleamc/parser
import gleamc/pipeline
import gleamc/toolchain

pub fn parse_labelled_pattern_test() {
  let source =
    "type Wrapped(a) {\n  Wrapped(value: a)\n  Empty\n}\n\nfn get(w: Wrapped(Int)) -> Int {\n  case w {\n    Wrapped(value: v) -> v\n    Empty -> 0\n  }\n}\n"
  let assert Ok(Module([
    _,
    DFunction(Function(
      _,
      "get",
      _,
      _,
      EBlock([
        Stmt(ECase(
          _,
          [
            Arm(PCtor("Wrapped", [PLabelled("value", PVar("v"))]), _, _),
            Arm(PCtor("Empty", []), _, _),
          ],
        )),
      ]),
      _,
    )),
  ])) = parser.parse(source)
}

const dir = "/tmp/gleamc-labelled"

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

const labelled_source = "import gleam/io\n\ntype Wrapped(a) {\n  Wrapped(value: a)\n  Empty\n}\n\nfn unwrap(w: Wrapped(a), default: a) -> a {\n  case w {\n    Wrapped(value: v) -> v\n    Empty -> default\n  }\n}\n\npub fn main() {\n  io.println(unwrap(Wrapped(value: \"hi\"), \"none\"))\n  io.println(unwrap(Empty, \"fallback\"))\n}\n"

pub fn labelled_pattern_end_to_end_test() {
  let output = compile_and_run("labelled", labelled_source)
  assert string.contains(output, "hi")
  assert string.contains(output, "fallback")
  assert string.contains(output, "live blocks = 0")
}
