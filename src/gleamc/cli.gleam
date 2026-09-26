//// gleamc command-line interface.

import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleamc/ffi
import gleamc/ir
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

const version = "gleamc 0.1.0"

const runtime_dir = "runtime"

const work_dir = "/tmp/gleamc"

const smoke_source = "import gleam/io\n\npub fn main() {\n  io.println(\"Hello from gleamc!\")\n}\n"

pub type Options {
  Options(
    cc: Option(String),
    mode: toolchain.Mode,
    run: Bool,
    quiet: Bool,
    ir: Bool,
  )
}

type Command {
  Help
  Version
  Smoke(Options)
  Build(source: String, options: Options)
}

fn default_options() -> Options {
  Options(
    cc: None,
    mode: toolchain.Debug,
    run: False,
    quiet: False,
    ir: False,
  )
}

pub fn main() -> Nil {
  case parse_command(ffi.argv()) {
    Help -> usage()
    Version -> io.println(version)
    Smoke(options) -> smoke(options)
    Build(source, options) -> compile_file(source, options)
  }
}

fn parse_command(args: List(String)) -> Command {
  parse(args, default_options(), None)
}

fn parse(
  args: List(String),
  options: Options,
  source: Option(String),
) -> Command {
  case args {
    [] ->
      case source {
        None -> Smoke(options)
        Some(path) -> Build(path, options)
      }
    [arg, ..rest] ->
      case arg {
        "--help" | "-h" -> Help
        "--version" -> Version
        "--release" ->
          parse(rest, Options(..options, mode: toolchain.Release), source)
        "--debug" ->
          parse(rest, Options(..options, mode: toolchain.Debug), source)
        "--run" -> parse(rest, Options(..options, run: True), source)
        "--quiet" -> parse(rest, Options(..options, quiet: True), source)
        "--ir" -> parse(rest, Options(..options, ir: True), source)
        "smoke" -> parse(rest, options, source)
        _ ->
          case string.split(arg, "=") {
            ["--cc", cc] ->
              parse(rest, Options(..options, cc: Some(cc)), source)
            _ ->
              case string.starts_with(arg, "--") {
                True -> parse(rest, options, source)
                False -> parse(rest, options, Some(arg))
              }
          }
      }
  }
}

fn resolve_cc(options: Options) -> String {
  case options.cc {
    Some(cc) -> cc
    None -> toolchain.default_cc()
  }
}

fn usage() -> Nil {
  io.println(version)
  io.println("")
  io.println(
    "usage: gleamc <file.gleam> [--cc=clang|gcc] [--release] [--run]",
  )
  io.println("       gleamc <file.gleam>            # emit LLVM IR")
  io.println("       gleamc <file.gleam> --ir       # dump ownership-phase IR")
  io.println("       gleamc smoke        # end-to-end pipeline smoke test")
  io.println("       gleamc --version")
}

// ---------------------------------------------------------------------------
// compilation
// ---------------------------------------------------------------------------

fn compile_file(source: String, options: Options) -> Nil {
  let t = ffi.now_ms()
  case loader.load(source) {
    Error(err) -> io.println(source <> ": " <> err)
    Ok(modules) -> {
      let _ = pipeline.mark("loader", t)
      compile_modules(modules, strip_gleam(source), options)
    }
  }
}

fn compile_modules(modules, base: String, options: Options) -> Nil {
  case options.ir {
    True -> compile_ir_dump(modules, base)
    False -> compile_llvm(modules, base, options)
  }
}

/// Ownership-phase IR dump: a text artifact, nothing to link.
fn compile_ir_dump(modules, base: String) -> Nil {
  case ownership_ir(modules) {
    Error(err) -> io.println(base <> ".gleam: " <> err)
    Ok(output) -> case ffi.write_file(base <> ".ir", output) {
      Error(err) -> io.println("error writing " <> base <> ".ir: " <> err)
      Ok(_) -> Nil
    }
  }
}

fn compile_llvm(modules, base: String, options: Options) -> Nil {
  case pipeline.compile_modules_llvm_chunks(modules) {
    Error(err) -> io.println(base <> ".gleam: " <> err)
    Ok(chunks) -> {
      let audit = case ffi.get_env("GLEAMC_RC_AUDIT") {
        Ok(_) -> True
        Error(_) -> False
      }
      // Audit builds carry extra refcount site strings, so they get their
      // own files (`_debug`) and never clobber the normal artifacts.
      let ll_path = case audit {
        True -> base <> "_debug.ll"
        False -> base <> ".ll"
      }
      let bin_path = case audit {
        True -> base <> "_debug"
        False -> base
      }
      // Stream the chunks to the file instead of building one huge string.
      case ffi.write_chunks(ll_path, chunks) {
        Error(err) -> io.println("error writing " <> ll_path <> ": " <> err)
        Ok(_) -> build(ll_path, bin_path, options)
      }
    }
  }
}

fn ownership_ir(modules) -> Result(String, String) {
  use owned <- result.try(pipeline.compile_ir_modules(modules))
  Ok(ir.to_text(owned))
}

fn build(ll_path: String, bin_path: String, options: Options) -> Nil {
  let cc = resolve_cc(options)
  let cmd =
    toolchain.build_command(
      cc,
      options.mode,
      [ll_path, runtime_dir <> "/gleam_runtime.c"],
      [runtime_dir],
      bin_path,
    )
  case options.quiet {
    False -> io.println("$ " <> cmd)
    True -> Nil
  }
  case toolchain.run_shell(cmd) {
    #(0, _) ->
      case options.run {
        True -> run_binary(bin_path)
        False ->
          case options.quiet {
            True -> Nil
            False -> io.println("compiled " <> bin_path)
          }
      }
    #(status, output) -> {
      io.println("compilation failed (exit " <> int.to_string(status) <> ")")
      io.println(output)
    }
  }
}

fn run_binary(bin_path: String) -> Nil {
  case toolchain.run_shell(bin_path) {
    #(0, output) -> io.print(output)
    #(status, output) -> {
      io.println("run failed (exit " <> int.to_string(status) <> ")")
      io.println(output)
    }
  }
}

fn smoke(options: Options) -> Nil {
  let _ = toolchain.run_shell("mkdir -p " <> work_dir)
  let source_path = work_dir <> "/smoke.gleam"
  case ffi.write_file(source_path, smoke_source) {
    Error(err) -> io.println("error writing " <> source_path <> ": " <> err)
    Ok(_) -> compile_file(source_path, Options(..options, run: True))
  }
}

fn strip_gleam(path: String) -> String {
  case string.ends_with(path, ".gleam") {
    True -> string.slice(path, 0, string.length(path) - 6)
    False -> path
  }
}
