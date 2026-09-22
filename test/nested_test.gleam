import gleam/string
import gleamc/ffi
import gleamc/pipeline
import gleamc/toolchain

const dir = "/tmp/gleamc-nested"

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
  assert compile_status == 0 as "nested pattern program failed to compile"
  let #(_status, output) = toolchain.run_shell(dir <> "/" <> name)
  output
}

const nested_source = "import gleam/io\n\ntype MaybeInt {\n  Just(value: Int)\n  Nothing\n}\n\ntype Wrapper {\n  Wrap(value: MaybeInt)\n}\n\nfn get(w: Wrapper) -> Int {\n  case w {\n    Wrap(Just(v)) -> v\n    Wrap(Nothing) -> -1\n  }\n}\n\npub fn main() {\n  io.println(int.to_string(get(Wrap(Just(7)))))\n  io.println(int.to_string(get(Wrap(Nothing))))\n}\n"

pub fn nested_constructor_test() {
  let output = compile_and_run("nested", nested_source)
  assert string.contains(output, "7")
  assert string.contains(output, "-1")
}

const tuple_in_ctor_source = "import gleam/io\n\ntype Pair {\n  Pair(value: #(Int, Int))\n}\n\nfn sum(p: Pair) -> Int {\n  case p {\n    Pair(#(a, b)) -> a + b\n  }\n}\n\npub fn main() {\n  io.println(int.to_string(sum(Pair(#(20, 22)))))\n}\n"

pub fn tuple_nested_in_constructor_test() {
  let output = compile_and_run("tuple_in_ctor", tuple_in_ctor_source)
  assert string.contains(output, "42")
}

const multi_field_source = "import gleam/io\n\ntype Rect {\n  Rect(width: Int, height: Int)\n}\n\nfn area(r: Rect) -> Int {\n  case r {\n    Rect(w, h) -> w * h\n  }\n}\n\npub fn main() {\n  io.println(int.to_string(area(Rect(6, 7))))\n}\n"

pub fn multi_field_constructor_test() {
  let output = compile_and_run("multi_field", multi_field_source)
  assert string.contains(output, "42")
}

const literal_in_ctor_source = "import gleam/io\n\ntype MaybeInt {\n  Just(value: Int)\n  Nothing\n}\n\nfn label(m: MaybeInt) -> Int {\n  case m {\n    Just(0) -> 100\n    Just(v) -> v\n    Nothing -> -1\n  }\n}\n\npub fn main() {\n  io.println(int.to_string(label(Just(0))))\n  io.println(int.to_string(label(Just(5))))\n  io.println(int.to_string(label(Nothing)))\n}\n"

pub fn literal_nested_in_constructor_test() {
  let output = compile_and_run("literal_in_ctor", literal_in_ctor_source)
  assert string.contains(output, "100")
  assert string.contains(output, "5")
  assert string.contains(output, "-1")
}

const guard_source = "import gleam/io\n\nfn classify(n: Int) -> Int {\n  case n {\n    x when x > 0 -> 1\n    0 -> 0\n    _ -> -1\n  }\n}\n\npub fn main() {\n  io.println(int.to_string(classify(5)))\n  io.println(int.to_string(classify(0)))\n  io.println(int.to_string(classify(-3)))\n}\n"

pub fn guard_test() {
  let output = compile_and_run("guard", guard_source)
  assert string.contains(output, "1")
  assert string.contains(output, "0")
  assert string.contains(output, "-1")
}

const guard_fallthrough_source = "import gleam/io\n\nfn f(n: Int) -> Int {\n  case n {\n    x when x > 10 -> 100\n    x -> x\n  }\n}\n\npub fn main() {\n  io.println(int.to_string(f(20)))\n  io.println(int.to_string(f(5)))\n}\n"

pub fn guard_fallthrough_test() {
  let output = compile_and_run("guard_fallthrough", guard_fallthrough_source)
  assert string.contains(output, "100")
  assert string.contains(output, "5")
}

const guard_in_ctor_source = "import gleam/io\n\ntype MaybeInt {\n  Just(value: Int)\n  Nothing\n}\n\nfn sign(m: MaybeInt) -> Int {\n  case m {\n    Just(v) when v > 0 -> 1\n    Just(_) -> 0\n    Nothing -> -1\n  }\n}\n\npub fn main() {\n  io.println(int.to_string(sign(Just(9))))\n  io.println(int.to_string(sign(Just(-2))))\n  io.println(int.to_string(sign(Nothing)))\n}\n"

pub fn guard_with_constructor_test() {
  let output = compile_and_run("guard_in_ctor", guard_in_ctor_source)
  assert string.contains(output, "1")
  assert string.contains(output, "0")
  assert string.contains(output, "-1")
}
