//// The compilation cascade: source(s) -> LLVM IR.
////
////   lower -> frame -> ownership -> llvm
////
//// `compile_to_ir` stops after the ownership pass (useful for dumps/tests).

import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import gleamc/aliases
import gleamc/ast.{type CustomType, type Module}
import gleamc/async
import gleamc/checker
import gleamc/consts
import gleamc/dce
import gleamc/ffi
import gleamc/frame
import gleamc/ir
import gleamc/llvm
import gleamc/lower
import gleamc/merge
import gleamc/mono
import gleamc/opacity
import gleamc/ownership
import gleamc/parser
import gleamc/qualify
import gleamc/spawn
import gleamc/ssa
import gleamc/tmono

/// Single-module convenience (entry module name "").
pub fn compile_to_llvm(source: String) -> Result(String, String) {
  use module <- result.try(map_err(parser.parse(source), parser.describe_error))
  compile_modules_llvm([#("", module)])
}

pub fn compile_to_ir(source: String) -> Result(ir.Module, String) {
  use module <- result.try(map_err(parser.parse(source), parser.describe_error))
  compile_ir_modules([#("", module)])
}

pub fn compile_modules_llvm(
  modules: List(#(String, Module)),
) -> Result(String, String) {
  use chunks <- result.try(compile_modules_llvm_chunks(modules))
  Ok(string.join(chunks, ""))
}

/// Like `compile_modules_llvm`, but returns the IR as ordered chunks so the
/// caller can stream it to a file without materialising the whole document.
pub fn compile_modules_llvm_chunks(
  modules: List(#(String, Module)),
) -> Result(List(String), String) {
  use #(_module, owned, ctors, custom_types) <- result.try(cascade(modules))
  let t = ffi.now_ms()
  let chunks = llvm.emit_chunks(owned, custom_types, ctors)
  let _ = mark("emit", t)
  Ok(chunks)
}

pub fn compile_ir_modules(
  modules: List(#(String, Module)),
) -> Result(ir.Module, String) {
  use #(_module, owned, _ctors, _custom_types) <- result.try(cascade(modules))
  Ok(owned)
}

/// Diagnostic: when `GLEAMC_PHASES` is set, print the milliseconds spent since
/// the previous mark. Returns the current timestamp to thread to the next mark.
pub fn mark(name: String, previous: Int) -> Int {
  let now = ffi.now_ms()
  case ffi.get_env("GLEAMC_PHASES") {
    Ok(_) -> io.println("## " <> name <> " " <> int.to_string(now - previous))
    Error(_) -> Nil
  }
  now
}

fn cascade(modules: List(#(String, Module))) {
  let t = ffi.now_ms()
  use _ <- result.try(opacity.check(modules))
  let t = mark("opacity", t)
  let modules = consts.expand_modules(modules)
  let t = mark("consts", t)
  use merged <- result.try(merge.merge(modules))
  let t = mark("merge", t)
  let merged = qualify.qualify_ctors(merged)
  let t = mark("qualify", t)
  // 0. expand type aliases before specialisation
  use merged <- result.try(aliases.expand(merged))
  let t = mark("aliases", t)
  // 1. monomorphise the generic program (validates via the HM checker) and
  // produce the typed monomorphic module
  use typed_module <- result.try(mono.monomorphize(merged))
  let t = mark("mono", t)
  let typed_module = dce.prune(typed_module)
  let t = mark("dce", t)
  // 2. the monomorphic backend reads the typed module produced by `mono`
  use checked <- result.try(map_err(
    checker.check(typed_module),
    checker.describe_error,
  ))
  let t = mark("checker", t)
  use ir_module <- result.try(map_err(
    lower.lower_module(checked.typed, checked.signatures, checked.ctors),
    lower.describe_error,
  ))
  let t = mark("lower", t)
  // Turn `process.spawn` / `task.async` into explicit task starts before the
  // async rewrite (which would otherwise rewrite the eta forwarder).
  use ir_module <- result.try(spawn.rewrite(ir_module))
  let t = mark("spawn", t)
  // Make suspension explicit at every async call: the caller starts the callee
  // as a task and suspends on its completion, so one driver owns the uv loop.
  let ir_module = async.normalize(ir_module)
  let t = mark("async", t)
  // Materialize each machine function's frame as an explicit IR value before
  // ownership, so ownership can schedule its release (see docs/frame-environment.md).
  let ir_module = frame.materialize(ir_module)
  let t = mark("frame", t)
  let owned = ownership.insert(ir_module, checked.ctors)
  let t = mark("ownership", t)
  // Promote single-definition locals to SSA values (no alloca/load/store).
  let owned = ssa.promote(owned, ownership.recursive_types(checked.ctors))
  let _ = mark("ssa", t)
  Ok(#(typed_module, owned, checked.ctors, custom_types_of(typed_module)))
}

fn custom_types_of(module: tmono.TModule) -> List(CustomType) {
  let tmono.TModule(definitions) = module
  list.filter_map(definitions, fn(definition) {
    case definition {
      tmono.TDCustomType(custom) -> Ok(custom)
      _ -> Error(Nil)
    }
  })
}

fn map_err(result, describe) {
  case result {
    Ok(value) -> Ok(value)
    Error(err) -> Error(describe(err))
  }
}
