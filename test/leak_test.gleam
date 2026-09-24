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
  assert compile_status == 0 as "program failed to compile"

  let #(_status, output) =
    toolchain.run_shell("env GLEAMC_MEM_REPORT=1 " <> dir <> "/main")
  assert string.contains(output, "3")
  assert string.contains(output, "live blocks = 0")
}

/// Regression: walking a directory tree (`simplifile.get_files`) suspends and
/// recurses through closures, so the frame is captured and its fields read
/// back. The closure owns the frame (which owns the fields); owning the
/// captures as well, or retaining every frame-field read, used to leak six
/// blocks.
const walk_source = "import gleam/io
import gleam/list
import gleam/string
import simplifile

pub fn main() {
  let dir = \"/tmp/gleamc-leak/tree\"
  let _ = simplifile.delete_all([dir])
  let assert Ok(Nil) = simplifile.create_directory(dir)
  let assert Ok(Nil) = simplifile.write(to: dir <> \"/a.txt\", contents: \"a\")
  let assert Ok(Nil) = simplifile.create_directory(dir <> \"/sub\")
  let assert Ok(Nil) = simplifile.write(to: dir <> \"/sub/c.txt\", contents: \"c\")
  let assert Ok(files) = simplifile.get_files(in: dir)
  io.debug(list.sort(files, string.compare))
}
"

pub fn leak_get_files_frame_test() {
  let _ = ffi.run("mkdir -p " <> dir)
  let assert Ok(_) = ffi.write_file(dir <> "/walk.gleam", walk_source)
  let assert Ok(modules) = loader.load(dir <> "/walk.gleam")
  let assert Ok(ll_code) = pipeline.compile_modules_llvm(modules)
  let assert Ok(_) = ffi.write_file(dir <> "/walk.ll", ll_code)

  let cmd =
    toolchain.build_command(
      toolchain.default_cc(),
      toolchain.Debug,
      [dir <> "/walk.ll", "runtime/gleam_runtime.c"],
      ["runtime"],
      dir <> "/walk",
    )
  let #(compile_status, _compile_out) = toolchain.run_shell(cmd)
  assert compile_status == 0 as "program failed to compile"

  let #(_status, output) =
    toolchain.run_shell("env GLEAMC_MEM_REPORT=1 " <> dir <> "/walk")
  assert string.contains(output, "a.txt")
  assert string.contains(output, "live blocks = 0")
}

/// Regression: `list.map2` over lists of unequal length extracts the tails only
/// on the branch that consumes them; at the critical-edge join the ownership
/// drops used to land in the unreachable block, leaking both empty tails.
const map2_source = "import gleam/io
import gleam/list

pub fn main() {
  io.debug(list.map2([1, 2, 3], [10, 20], fn(a, b) { a + b }))
}
"

pub fn leak_map2_partial_ownership_test() {
  let _ = ffi.run("mkdir -p " <> dir)
  let assert Ok(_) = ffi.write_file(dir <> "/map2.gleam", map2_source)
  let assert Ok(modules) = loader.load(dir <> "/map2.gleam")
  let assert Ok(ll_code) = pipeline.compile_modules_llvm(modules)
  let assert Ok(_) = ffi.write_file(dir <> "/map2.ll", ll_code)

  let cmd =
    toolchain.build_command(
      toolchain.default_cc(),
      toolchain.Debug,
      [dir <> "/map2.ll", "runtime/gleam_runtime.c"],
      ["runtime"],
      dir <> "/map2",
    )
  let #(compile_status, _compile_out) = toolchain.run_shell(cmd)
  assert compile_status == 0 as "program failed to compile"

  let #(_status, output) =
    toolchain.run_shell("env GLEAMC_MEM_REPORT=1 " <> dir <> "/map2")
  assert string.contains(output, "live blocks = 0")
}
