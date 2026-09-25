//// The compilation cascade: source(s) -> LLVM IR.
////
////   lower -> frame -> ownership -> cps -> llvm
////
//// `compile_to_ir` stops after the ownership pass (useful for dumps/tests).

import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleamc/aliases
import gleamc/ffi
import gleamc/ast.{type CustomType, type Module, DCustomType, Module}
import gleamc/checker
import gleamc/consts
import gleamc/cps
import gleamc/dce
import gleamc/frame
import gleamc/ir
import gleamc/llvm
import gleamc/lower
import gleamc/merge
import gleamc/mono
import gleamc/opacity
import gleamc/ownership
import gleamc/parser
import gleamc/plan
import gleamc/qualify

/// Single-module convenience (entry module name "").
pub fn compile_to_llvm(source: String) -> Result(String, String) {
  use module <- result.try(map_err(parser.parse(source), parser.describe_error))
  compile_modules_llvm([#("", module)])
}

pub fn compile_to_plan(source: String) -> Result(plan.Plan, String) {
  use module <- result.try(map_err(parser.parse(source), parser.describe_error))
  use #(_module, owned, _ctors, _custom_types) <- result.try(
    cascade([
      #("", module),
    ]),
  )
  Ok(plan.plan(owned))
}

pub fn compile_to_ir(source: String) -> Result(ir.Module, String) {
  use module <- result.try(map_err(parser.parse(source), parser.describe_error))
  compile_ir_modules([#("", module)])
}

pub fn compile_modules_llvm(
  modules: List(#(String, Module)),
) -> Result(String, String) {
  use #(_module, owned, ctors, custom_types) <- result.try(cascade(modules))
  let t = ffi.now_ms()
  let output = llvm.emit(owned, custom_types, ctors)
  let _ = mark("emit", t)
  Ok(output)
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
  // 1. monomorphise the generic program (validates via the HM checker)
  use mono_module <- result.try(mono.monomorphize(merged))
  let t = mark("mono", t)
  let mono_module = dce.prune(mono_module)
  let t = mark("dce", t)
  // 2. the monomorphic backend runs on the specialised AST
  use checked <- result.try(map_err(
    checker.check(mono_module),
    checker.describe_error,
  ))
  let t = mark("checker", t)
  use ir_module <- result.try(map_err(
    lower.lower_module(checked.module, checked.signatures, checked.ctors),
    lower.describe_error,
  ))
  let t = mark("lower", t)
  // Materialize each machine function's frame as an explicit IR value before
  // ownership, so ownership can schedule its release (see docs/frame-environment.md).
  let ir_module = frame.materialize(ir_module)
  let t = mark("frame", t)
  let owned = ownership.insert(ir_module, checked.ctors)
  let t = mark("ownership", t)
  let owned = cps.normalize(owned)
  let _ = mark("cps", t)
  Ok(#(checked.module, owned, checked.ctors, custom_types_of(checked.module)))
}

fn custom_types_of(module: Module) -> List(CustomType) {
  let Module(definitions) = module
  list.filter_map(definitions, fn(definition) {
    case definition {
      DCustomType(custom) -> Ok(custom)
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
