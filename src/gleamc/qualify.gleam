//// Constructor qualification: rewrites `module.Constructor` references
//// (parsed as field access/method call) into plain constructor expressions,
//// so the rest of the pipeline only sees global constructor names.
////
//// Runs after module merging (function names are already qualified) and
//// before type checking.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleamc/ast.{
  type Definition, type Expr, type Module, type Statement, Arm, CustomType,
  DCustomType, DFunction, EBinop, EBitArray, EBlock, EBool, ECall, ECase,
  EClosure, ECtor, EEnvGet, EField, EFloat, EInt, ELabelled, ELambda, ENil,
  EPanic, EString, ETuple, EUnop, EUpdate, EVar, Function, Let, Module, Stmt,
  Variant,
}

pub fn qualify_ctors(module: Module) -> Module {
  let Module(definitions) = module
  let ctors = collect_ctors(definitions)
  Module(
    list.map(definitions, fn(definition) {
      qualify_definition(definition, ctors)
    }),
  )
}

fn collect_ctors(definitions) -> Dict(String, Bool) {
  list.fold(definitions, dict.new(), fn(acc, definition) {
    case definition {
      DCustomType(custom) -> {
        let CustomType(_, _, _, variants) = custom
        list.fold(variants, acc, fn(acc, variant) {
          let Variant(name, _) = variant
          dict.insert(acc, name, True)
        })
      }
      _ -> acc
    }
  })
}

fn is_ctor(ctors, name) -> Bool {
  case dict.get(ctors, name) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn qualify_definition(definition, ctors) -> Definition {
  case definition {
    DFunction(function) ->
      DFunction(Function(
        function.is_pub,
        function.name,
        function.params,
        function.ret,
        qualify_expr(function.body, ctors),
      ))
    _ -> definition
  }
}

fn qualify_expr(expr, ctors) -> Expr {
  case expr {
    ECall(EField(EVar(module), name), args) ->
      case is_ctor(ctors, name) {
        True ->
          ECtor(name, list.map(args, fn(arg) { qualify_expr(arg, ctors) }))
        False ->
          ECall(
            qualify_expr(EField(EVar(module), name), ctors),
            list.map(args, fn(arg) { qualify_expr(arg, ctors) }),
          )
      }
    EField(EVar(_module), name) ->
      case is_ctor(ctors, name) {
        True -> ECtor(name, [])
        False -> expr
      }
    EInt(_) | EFloat(_) | EString(_) | EVar(_) | ENil | EEnvGet(_, _, _) -> expr
    EPanic(_, _) -> expr
    EBitArray(elements) ->
      EBitArray(
        list.map(elements, fn(element) { qualify_expr(element, ctors) }),
      )
    EUpdate(name, base, fields) ->
      EUpdate(
        name,
        qualify_expr(base, ctors),
        list.map(fields, fn(field) {
          let #(label, value) = field
          #(label, qualify_expr(value, ctors))
        }),
      )
    EBool(_) -> expr
    ETuple(elements) ->
      ETuple(list.map(elements, fn(e) { qualify_expr(e, ctors) }))
    ECtor(name, args) ->
      ECtor(name, list.map(args, fn(e) { qualify_expr(e, ctors) }))
    ECall(fun, args) ->
      ECall(
        qualify_expr(fun, ctors),
        list.map(args, fn(e) { qualify_expr(e, ctors) }),
      )
    EBinop(op, left, right) ->
      EBinop(op, qualify_expr(left, ctors), qualify_expr(right, ctors))
    EUnop(op, operand) -> EUnop(op, qualify_expr(operand, ctors))
    EBlock(statements) ->
      EBlock(list.map(statements, fn(s) { qualify_stmt(s, ctors) }))
    ECase(subject, arms) ->
      ECase(
        qualify_expr(subject, ctors),
        list.map(arms, fn(arm) {
          let Arm(pattern, guard, body) = arm
          Arm(
            pattern,
            case guard {
              Some(g) -> Some(qualify_expr(g, ctors))
              None -> None
            },
            qualify_expr(body, ctors),
          )
        }),
      )
    ELabelled(label, value) -> ELabelled(label, qualify_expr(value, ctors))
    ELambda(names, body) -> ELambda(names, qualify_expr(body, ctors))
    EClosure(code, captures, env_ty, fn_ty) ->
      EClosure(
        code,
        list.map(captures, fn(e) { qualify_expr(e, ctors) }),
        env_ty,
        fn_ty,
      )
    _ -> expr
  }
}

fn qualify_stmt(statement, ctors) -> Statement {
  case statement {
    Let(pattern, value) -> Let(pattern, qualify_expr(value, ctors))
    Stmt(expr) -> Stmt(qualify_expr(expr, ctors))
  }
}
