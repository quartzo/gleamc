//// Opaque type enforcement: constructors of `opaque_ctors type`s may only be used
//// in the module that declares them.
////
//// Runs before module merging, on the per-module ASTs, so it still knows which
//// module each function belongs to.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleamc/ast.{
  type Module, Arm, CustomType, DConst, DCustomType, DExternal, DFunction,
  DImport, DTypeAlias, EBinop, EBitArray, EBlock, ECall, ECase, EClosure, ECtor,
  EEnvGet,
  EField, ELabelled, ELambda, EPanic, ETuple, EUnop, EUpdate, EVar, Let, Module,
  PBitArray, PCtor, PLabelled, PTuple, Stmt, Variant,
}

pub fn check(modules: List(#(String, Module))) -> Result(Nil, String) {
  let opaque_ctors = collect_opaque(modules)
  use _ <- result.try(
    list.try_each(modules, fn(entry) {
      let #(alias, module) = entry
      check_module(module, alias, opaque_ctors)
    }),
  )
  Ok(Nil)
}

/// Constructor name -> the module alias that declares it as opaque_ctors.
fn collect_opaque(modules) -> Dict(String, String) {
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
                dict.insert(acc, name, alias)
              })
          }
        }
        _ -> acc
      }
    })
  })
}

fn check_module(module, alias, opaque_ctors) -> Result(Nil, String) {
  let Module(definitions) = module
  list.try_each(definitions, fn(definition) {
    case definition {
      DFunction(function) -> check_expr(function.body, alias, opaque_ctors)
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

fn use_ctor(ctor, alias, opaque_ctors) -> Result(Nil, String) {
  case dict.get(opaque_ctors, base_name(ctor)) {
    Ok(defining) ->
      case defining == alias {
        True -> Ok(Nil)
        False ->
          Error(
            "constructor `"
            <> base_name(ctor)
            <> "` of an opaque type is private",
          )
      }
    Error(_) -> Ok(Nil)
  }
}

fn check_expr(expr, alias, opaque_ctors) -> Result(Nil, String) {
  case expr {
    ECtor(name, args) -> {
      use _ <- result.try(use_ctor(name, alias, opaque_ctors))
      check_exprs(args, alias, opaque_ctors)
    }
    ECall(EField(EVar(_module), name), args) -> {
      use _ <- result.try(use_ctor(name, alias, opaque_ctors))
      check_exprs(args, alias, opaque_ctors)
    }
    EField(EVar(_module), name) -> use_ctor(name, alias, opaque_ctors)
    ECall(fun, args) -> {
      use _ <- result.try(check_expr(fun, alias, opaque_ctors))
      check_exprs(args, alias, opaque_ctors)
    }
    EField(obj, _) -> check_expr(obj, alias, opaque_ctors)
    EBitArray(elements) -> check_exprs(elements, alias, opaque_ctors)
    ETuple(elements) -> check_exprs(elements, alias, opaque_ctors)
    EUnop(_, operand) -> check_expr(operand, alias, opaque_ctors)
    EBinop(_, left, right) -> {
      use _ <- result.try(check_expr(left, alias, opaque_ctors))
      check_expr(right, alias, opaque_ctors)
    }
    EBlock(statements) -> check_statements(statements, alias, opaque_ctors)
    ECase(subject, arms) -> {
      use _ <- result.try(check_expr(subject, alias, opaque_ctors))
      list.try_each(arms, fn(arm) {
        let Arm(pattern, guard, body) = arm
        use _ <- result.try(check_pattern(pattern, alias, opaque_ctors))
        use _ <- result.try(case guard {
          Some(guard) -> check_expr(guard, alias, opaque_ctors)
          None -> Ok(Nil)
        })
        check_expr(body, alias, opaque_ctors)
      })
    }
    ELabelled(_, value) -> check_expr(value, alias, opaque_ctors)
    ELambda(_, body) -> check_expr(body, alias, opaque_ctors)
    EClosure(_, captures, _, _) -> check_exprs(captures, alias, opaque_ctors)
    EUpdate(name, base, fields) -> {
      use _ <- result.try(use_ctor(name, alias, opaque_ctors))
      use _ <- result.try(check_expr(base, alias, opaque_ctors))
      list.try_each(fields, fn(field) {
        let #(_, value) = field
        check_expr(value, alias, opaque_ctors)
      })
    }
    EPanic(_, _) | EEnvGet(_, _, _) -> Ok(Nil)
    _ -> Ok(Nil)
  }
}

fn check_exprs(exprs, alias, opaque_ctors) -> Result(Nil, String) {
  list.try_each(exprs, fn(expr) { check_expr(expr, alias, opaque_ctors) })
}

fn check_statements(statements, alias, opaque_ctors) -> Result(Nil, String) {
  list.try_each(statements, fn(statement) {
    case statement {
      Let(pattern, value) -> {
        use _ <- result.try(check_pattern(pattern, alias, opaque_ctors))
        check_expr(value, alias, opaque_ctors)
      }
      Stmt(expr) -> check_expr(expr, alias, opaque_ctors)
    }
  })
}

fn check_pattern(pattern, alias, opaque_ctors) -> Result(Nil, String) {
  case pattern {
    PCtor(name, args) -> {
      use _ <- result.try(use_ctor(name, alias, opaque_ctors))
      list.try_each(args, fn(arg) { check_pattern(arg, alias, opaque_ctors) })
    }
    PBitArray(patterns) | PTuple(patterns) ->
      list.try_each(patterns, fn(inner) {
        check_pattern(inner, alias, opaque_ctors)
      })
    PLabelled(_, inner) -> check_pattern(inner, alias, opaque_ctors)
    _ -> Ok(Nil)
  }
}
