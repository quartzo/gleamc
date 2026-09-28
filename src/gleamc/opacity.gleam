//// Opaque type enforcement: constructors of `opaque` types may only be used in
//// the module that declares them.
////
//// Runs before module merging, on the per-module ASTs, so it still knows which
//// module each function belongs to.
////
//// Constructors are module-scoped, so a constructor name may be reused across
//// modules. The check is therefore scoped by import: an unqualified use is only
//// a violation when the module that declares the opaque constructor is
//// imported by this module, and a qualified `mod.Ctor` use is a violation when
//// that constructor is opaque in `mod`.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleamc/ast.{
  type Module, Arm, CustomType, DConst, DCustomType, DExternal, DFunction,
  DImport, DTypeAlias, EBinop, EBitArray, EBlock, ECall, ECase, EClosure, ECtor,
  EEnvGet, EField, ELabelled, ELambda, EPanic, ETuple, EUnop, EUpdate, EVar,
  Import, Let, Module, PBitArray, PCtor, PLabelled, PTuple, Stmt, Variant,
}

pub fn check(modules: List(#(String, Module))) -> Result(Nil, String) {
  let opaque_ctors = collect_opaque(modules)
  use _ <- result.try(
    list.try_each(modules, fn(entry) {
      let #(alias, module) = entry
      check_module(module, alias, module_imports(module), opaque_ctors)
    }),
  )
  Ok(Nil)
}

/// The aliases (last path segments) of the modules imported by `module`.
fn module_imports(module) -> List(String) {
  let Module(definitions) = module
  list.filter_map(definitions, fn(definition) {
    case definition {
      DImport(Import(path, _)) ->
        case list.last(path) {
          Ok(alias) -> Ok(alias)
          Error(_) -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}

/// Constructor name -> every module alias that declares it as opaque. A name
/// may be reused across modules, so a list is kept per name.
fn collect_opaque(modules) -> Dict(String, List(String)) {
  list.fold(modules, dict.new(), fn(acc, entry) {
    let #(alias, module) = entry
    let Module(definitions) = module
    list.fold(definitions, acc, fn(acc, definition) {
      case definition {
        DCustomType(custom) -> {
          let CustomType(_, _, _, variants, is_opaque) = custom
          case is_opaque {
            False -> acc
            True ->
              list.fold(variants, acc, fn(acc, variant) {
                let Variant(name, _) = variant
                let existing = case dict.get(acc, name) {
                  Ok(aliases) -> aliases
                  Error(_) -> []
                }
                case list.contains(existing, alias) {
                  True -> acc
                  False -> dict.insert(acc, name, [alias, ..existing])
                }
              })
          }
        }
        _ -> acc
      }
    })
  })
}

fn check_module(module, alias, imports, opaque_ctors) -> Result(Nil, String) {
  let Module(definitions) = module
  list.try_each(definitions, fn(definition) {
    case definition {
      DFunction(function) ->
        check_expr(function.body, alias, imports, opaque_ctors)
      DExternal(_) -> Ok(Nil)
      DCustomType(_) -> Ok(Nil)
      DTypeAlias(_, _, _, _) -> Ok(Nil)
      DConst(_, _) -> Ok(Nil)
      DImport(_) -> Ok(Nil)
    }
  })
}

fn base_name(name) -> String {
  case list.last(string.split(name, ".")) {
    Ok(last) -> last
    Error(_) -> name
  }
}

fn private_error(name) -> String {
  "constructor `" <> name <> "` of an opaque type is private"
}

/// An unqualified constructor use is a violation when the constructor is opaque
/// in a *different* module that this one imports.
fn use_ctor_unqualified(
  ctor,
  alias,
  imports,
  opaque_ctors,
) -> Result(Nil, String) {
  case dict.get(opaque_ctors, base_name(ctor)) {
    Ok(defining) ->
      // This module may declare its own opaque constructor with the same name.
      case list.contains(defining, alias) {
        True -> Ok(Nil)
        False ->
          case
            list.any(defining, fn(module) { list.contains(imports, module) })
          {
            True -> Error(private_error(base_name(ctor)))
            False -> Ok(Nil)
          }
      }
    Error(_) -> Ok(Nil)
  }
}

/// A qualified `module.Ctor` use is a violation when the constructor is opaque
/// in `module` (and `module` is not this one).
fn use_ctor_qualified(
  module,
  ctor,
  alias,
  opaque_ctors,
) -> Result(Nil, String) {
  case dict.get(opaque_ctors, ctor) {
    Ok(defining) ->
      case list.contains(defining, module) {
        True ->
          case module == alias {
            True -> Ok(Nil)
            False -> Error(private_error(ctor))
          }
        False -> Ok(Nil)
      }
    Error(_) -> Ok(Nil)
  }
}

fn check_expr(expr, alias, imports, opaque_ctors) -> Result(Nil, String) {
  case expr {
    ECtor(name, args) -> {
      use _ <- result.try(use_ctor_unqualified(
        name,
        alias,
        imports,
        opaque_ctors,
      ))
      check_exprs(args, alias, imports, opaque_ctors)
    }
    ECall(EField(EVar(module), name), args) -> {
      use _ <- result.try(use_ctor_qualified(module, name, alias, opaque_ctors))
      check_exprs(args, alias, imports, opaque_ctors)
    }
    EField(EVar(module), name) ->
      use_ctor_qualified(module, name, alias, opaque_ctors)
    ECall(fun, args) -> {
      use _ <- result.try(check_expr(fun, alias, imports, opaque_ctors))
      check_exprs(args, alias, imports, opaque_ctors)
    }
    EField(obj, _) -> check_expr(obj, alias, imports, opaque_ctors)
    EBitArray(elements) -> check_exprs(elements, alias, imports, opaque_ctors)
    ETuple(elements) -> check_exprs(elements, alias, imports, opaque_ctors)
    EUnop(_, operand) -> check_expr(operand, alias, imports, opaque_ctors)
    EBinop(_, left, right) -> {
      use _ <- result.try(check_expr(left, alias, imports, opaque_ctors))
      check_expr(right, alias, imports, opaque_ctors)
    }
    EBlock(statements) ->
      check_statements(statements, alias, imports, opaque_ctors)
    ECase(subject, arms) -> {
      use _ <- result.try(check_expr(subject, alias, imports, opaque_ctors))
      list.try_each(arms, fn(arm) {
        let Arm(pattern, guard, body) = arm
        use _ <- result.try(check_pattern(pattern, alias, imports, opaque_ctors))
        use _ <- result.try(case guard {
          Some(guard) -> check_expr(guard, alias, imports, opaque_ctors)
          None -> Ok(Nil)
        })
        check_expr(body, alias, imports, opaque_ctors)
      })
    }
    ELabelled(_, value) -> check_expr(value, alias, imports, opaque_ctors)
    ELambda(_, body) -> check_expr(body, alias, imports, opaque_ctors)
    EClosure(_, captures, _, _) ->
      check_exprs(captures, alias, imports, opaque_ctors)
    EUpdate(name, base, fields) -> {
      use _ <- result.try(use_ctor_unqualified(
        name,
        alias,
        imports,
        opaque_ctors,
      ))
      use _ <- result.try(check_expr(base, alias, imports, opaque_ctors))
      list.try_each(fields, fn(field) {
        let #(_, value) = field
        check_expr(value, alias, imports, opaque_ctors)
      })
    }
    EPanic(_, _) | EEnvGet(_, _, _) -> Ok(Nil)
    _ -> Ok(Nil)
  }
}

fn check_exprs(exprs, alias, imports, opaque_ctors) -> Result(Nil, String) {
  list.try_each(exprs, fn(expr) {
    check_expr(expr, alias, imports, opaque_ctors)
  })
}

fn check_statements(
  statements,
  alias,
  imports,
  opaque_ctors,
) -> Result(Nil, String) {
  list.try_each(statements, fn(statement) {
    case statement {
      Let(pattern, value) -> {
        use _ <- result.try(check_pattern(pattern, alias, imports, opaque_ctors))
        check_expr(value, alias, imports, opaque_ctors)
      }
      Stmt(expr) -> check_expr(expr, alias, imports, opaque_ctors)
    }
  })
}

fn check_pattern(pattern, alias, imports, opaque_ctors) -> Result(Nil, String) {
  case pattern {
    PCtor(name, args) -> {
      use _ <- result.try(use_ctor_unqualified(
        name,
        alias,
        imports,
        opaque_ctors,
      ))
      list.try_each(args, fn(arg) {
        check_pattern(arg, alias, imports, opaque_ctors)
      })
    }
    PBitArray(patterns) | PTuple(patterns) ->
      list.try_each(patterns, fn(inner) {
        check_pattern(inner, alias, imports, opaque_ctors)
      })
    PLabelled(_, inner) -> check_pattern(inner, alias, imports, opaque_ctors)
    _ -> Ok(Nil)
  }
}
