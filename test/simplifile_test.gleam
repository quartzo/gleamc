import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

const dir = "/tmp/gleamc-fs"

/// Compiles a program with its imports, runs it and returns stdout+stderr.
fn compile_and_run(name: String, source: String) -> String {
  let _ = ffi.run("mkdir -p " <> dir)
  let entry = dir <> "/" <> name <> ".gleam"
  let assert Ok(_) = ffi.write_file(entry, source)
  let assert Ok(modules) = loader.load(entry)
  let assert Ok(c_code) = pipeline.compile_modules(modules)
  let assert Ok(_) = ffi.write_file(dir <> "/" <> name <> ".c", c_code)
  let cmd =
    toolchain.build_command(
      toolchain.default_cc(),
      toolchain.Debug,
      [dir <> "/" <> name <> ".c", "runtime/gleam_runtime.c"],
      ["runtime"],
      dir <> "/" <> name,
    )
  let #(compile_status, compile_out) = toolchain.run_shell(cmd)
  let _ = compile_out
  assert compile_status == 0 as "generated C failed to compile"
  let #(run_status, output) = toolchain.run_shell(dir <> "/" <> name)
  assert run_status == 0 as output
  output
}

pub fn simplifile_roundtrip_test() {
  let source =
    "import gleam/io
import simplifile

pub fn main() {
  let path = \"/tmp/gleamc-fs/roundtrip.txt\"
  let assert Ok(Nil) = simplifile.write(to: path, contents: \"hello\")
  let assert Ok(True) = simplifile.is_file(path)
  let assert Ok(False) = simplifile.is_directory(path)
  let assert Ok(text) = simplifile.read(from: path)
  io.println(text)
  let assert Ok(Nil) = simplifile.append(to: path, contents: \" world\")
  let assert Ok(text2) = simplifile.read(from: path)
  io.println(text2)
  let assert Ok(Nil) = simplifile.delete(path)
  let assert Ok(False) = simplifile.exists(filepath: path, follow_links: True)
}
"
  let output = compile_and_run("roundtrip", source)
  assert string.contains(output, "hello\nhello world\n") as output
}

pub fn simplifile_missing_file_test() {
  let source =
    "import gleam/io
import simplifile

pub fn main() {
  case simplifile.read(from: \"/tmp/gleamc-fs/does-not-exist.txt\") {
    Ok(_) -> io.println(\"unexpected\")
    Error(simplifile.Enoent) -> io.println(\"enoent\")
    Error(_) -> io.println(\"other\")
  }
  case simplifile.create_directory(\"/tmp/gleamc-fs/no/such/dir\") {
    Ok(_) -> io.println(\"created\")
    Error(_) -> io.println(\"failed\")
  }
}
"
  let output = compile_and_run("missing", source)
  assert string.contains(output, "enoent\nfailed\n") as output
}

pub fn simplifile_directories_test() {
  let _ = ffi.run("rm -rf /tmp/gleamc-fs/tree")
  let source =
    "import gleam/io
import gleam/list
import gleam/string
import simplifile

pub fn main() {
  let dir = \"/tmp/gleamc-fs/tree\"
  let assert Ok(Nil) = simplifile.create_directory(dir)
  let assert Ok(Nil) = simplifile.write(to: dir <> \"/a.txt\", contents: \"a\")
  let assert Ok(Nil) = simplifile.create_directory(dir <> \"/sub\")
  let assert Ok(Nil) =
    simplifile.write(to: dir <> \"/sub/c.txt\", contents: \"c\")
  let assert Ok(names) = simplifile.read_directory(at: dir)
  io.debug(list.sort(names, string.compare))
  let assert Ok(files) = simplifile.get_files(in: dir)
  io.debug(list.sort(files, string.compare))
}
"
  let output = compile_and_run("dirtree", source)
  assert string.contains(output, "[\"a.txt\", \"sub\"]") as output
  assert string.contains(output, "sub/c.txt") as output
}

pub fn simplifile_file_info_test() {
  let source =
    "import gleam/io
import simplifile

pub fn main() {
  let path = \"/tmp/gleamc-fs/info.txt\"
  let assert Ok(Nil) = simplifile.write(to: path, contents: \"hello\")
  let assert Ok(info) = simplifile.file_info(path)
  io.debug(simplifile.file_info_type(info))
  io.debug(info.size)
  let assert Ok(dirinfo) = simplifile.file_info(\"/tmp/gleamc-fs\")
  io.debug(simplifile.file_info_type(dirinfo))
}
"
  let output = compile_and_run("info", source)
  assert string.contains(output, "File") as output
  assert string.contains(output, "Directory") as output
}

pub fn simplifile_directory_ops_test() {
  let source =
    "import gleam/io
import simplifile

pub fn main() {
  let base = \"/tmp/gleamc-fs/api\"
  let _ = simplifile.delete_all([base])
  let assert Ok(Nil) = simplifile.create_directory_all(base <> \"/a/b\")
  let assert Ok(Nil) =
    simplifile.write(to: base <> \"/a/b/f.txt\", contents: \"hello\")
  let assert Ok(Nil) =
    simplifile.copy_file(at: base <> \"/a/b/f.txt\", to: base <> \"/a/b/g.txt\")
  let assert Ok(Nil) =
    simplifile.rename(at: base <> \"/a/b/g.txt\", to: base <> \"/a/b/h.txt\")
  let assert Ok(True) = simplifile.is_file(base <> \"/a/b/h.txt\")
  let assert Ok(False) =
    simplifile.exists(filepath: base <> \"/a/b/g.txt\", follow_links: True)
  let assert Ok(contents) = simplifile.read(from: base <> \"/a/b/h.txt\")
  io.println(contents)
  let assert Ok(Nil) = simplifile.clear_directory(base <> \"/a\")
  let assert Ok([]) = simplifile.read_directory(at: base <> \"/a\")
  let assert Ok(Nil) = simplifile.delete(base)
  let assert Ok(False) =
    simplifile.exists(filepath: base, follow_links: True)
  io.println(\"done\")
}
"
  let output = compile_and_run("dir_ops", source)
  assert string.contains(output, "hello\ndone\n") as output
}

pub fn simplifile_copy_links_test() {
  let source =
    "import gleam/io
import simplifile

pub fn main() {
  let base = \"/tmp/gleamc-fs/cp\"
  let _ = simplifile.delete_all([base])
  let assert Ok(Nil) = simplifile.create_directory_all(base <> \"/src/sub\")
  let assert Ok(Nil) = simplifile.write(to: base <> \"/src/a.txt\", contents: \"A\")
  let assert Ok(Nil) =
    simplifile.write(to: base <> \"/src/sub/b.txt\", contents: \"B\")
  let assert Ok(Nil) =
    simplifile.copy(src: base <> \"/src\", dest: base <> \"/dst\")
  let assert Ok(\"A\") = simplifile.read(from: base <> \"/dst/a.txt\")
  let assert Ok(\"B\") = simplifile.read(from: base <> \"/dst/sub/b.txt\")
  let assert Ok(Nil) = simplifile.touch(at: base <> \"/touched.txt\")
  let assert Ok(True) = simplifile.is_file(base <> \"/touched.txt\")
  let assert Ok(Nil) =
    simplifile.create_symlink(to: \"a.txt\", from: base <> \"/dst/link.txt\")
  let assert Ok(True) = simplifile.is_symlink(base <> \"/dst/link.txt\")
  let assert Ok(True) =
    simplifile.exists(filepath: base <> \"/dst/link.txt\", follow_links: True)
  let assert Ok(abs) = simplifile.resolve(path: base <> \"/dst/a.txt\")
  io.println(abs)
}
"
  let output = compile_and_run("copy_links", source)
  assert string.contains(output, "/tmp/gleamc-fs/cp/dst/a.txt") as output
}

pub fn simplifile_permissions_test() {
  let source =
    "import gleam/io
import gleam/set
import simplifile

pub fn main() {
  let path = \"/tmp/gleamc-fs/perm.txt\"
  let assert Ok(Nil) = simplifile.write(to: path, contents: \"x\")
  let assert Ok(Nil) =
    simplifile.set_permissions_octal(for_file_at: path, to: 384)
  let assert Ok(info) = simplifile.file_info(path)
  let assert 384 = simplifile.file_info_permissions_octal(from: info)
  let perms = simplifile.file_info_permissions(from: info)
  let assert 384 = simplifile.file_permissions_to_octal(permissions: perms)
  let rw = set.from_list([simplifile.Read, simplifile.Write])
  let built = simplifile.FilePermissions(
    user: rw,
    group: rw,
    other: set.difference(rw, rw),
  )
  let assert 432 = simplifile.file_permissions_to_octal(permissions: built)
  let assert Ok(Nil) = simplifile.set_permissions(for_file_at: path, to: built)
  io.println(\"ok\")
}
"
  let output = compile_and_run("perm", source)
  assert string.contains(output, "ok") as output
}
