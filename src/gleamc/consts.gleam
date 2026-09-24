//// Expands `const name = value` by inlining the value at each use and
//// removing the declarations. Consts may reference other consts of the same
//// module (by bare name) or of another module (qualified, `module.name`),
//// resolved recursively.

import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleamc/ast.{
  type Expr, type Module, Arm, DConst, DFunction, EBinop, EBitArray, EBlock,
  EBool, ECall, ECase, EClosure, ECtor, EEnvGet, EField, EFloat, EInt, ELabelled,
  ELambda, ENil, EPanic, EString, ETuple, EUnop, EUpdate, EVar, Function, Let,
  Module, Stmt,
}

pub fn expand_modules(
  modules: List(#(String, Module)),
) -> List(#(String, Module)) {
  // Every module's consts, keyed by the alias used to reference them from
  // another module (`module.name`, the module's last path segment).
  let globals =
    list.fold(modules, dict.new(), fn(acc, pair) {
      let #(module_name, Module(definitions)) = pair
      let alias = last_segment(module_name)
      list.fold(definitions, acc, fn(acc, def) {
        case def {
          DConst(name, value) -> dict.insert(acc, alias <> "." <> name, value)
          _ -> acc
        }
      })
    })
  list.map(modules, fn(pair) {
    let #(name, module) = pair
    #(name, expand_module(module, globals))
  })
}

fn expand_module(module: Module, globals) -> Module {
  let Module(definitions) = module
  // The module's own consts shadow nothing: bare names never collide with the
  // qualified (`module.name`) global keys.
  let table =
    list.fold(definitions, globals, fn(acc, def) {
      case def {
        DConst(name, value) -> dict.insert(acc, name, value)
        _ -> acc
      }
    })
  let definitions =
    list.filter(definitions, fn(def) {
      case def {
        DConst(_, _) -> False
        _ -> True
      }
    })
  Module(list.map(definitions, fn(def) { resolve_definition(def, table) }))
}

fn last_segment(name: String) -> String {
  case list.reverse(string.split(name, "/")) {
    [last, ..] -> last
    [] -> name
  }
}

fn resolve_definition(def, table) {
  case def {
    DFunction(function) -> {
      let Function(is_pub, name, params, ret, body, line) = function
      DFunction(Function(
        is_pub,
        name,
        params,
        ret,
        resolve(body, table, []),
        line,
      ))
    }
    _ -> def
  }
}

fn resolve(expr: Expr, table, stack: List(String)) -> Expr {
  case expr {
    EVar(name) ->
      case dict.get(table, name) {
        Error(_) -> expr
        Ok(value) ->
          case list.contains(stack, name) {
            True -> expr
            False -> resolve(value, table, [name, ..stack])
          }
      }
    // A qualified reference to another module's const (`frame.frame_local`).
    EField(EVar(module), name) -> {
      let qualified = module <> "." <> name
      case dict.get(table, qualified) {
        Ok(value) ->
          case list.contains(stack, qualified) {
            True -> expr
            False -> resolve(value, table, [qualified, ..stack])
          }
        Error(_) -> EField(EVar(module), name)
      }
    }
    EField(obj, name) -> EField(resolve(obj, table, stack), name)
    ECtor(name, args) -> ECtor(name, resolve_all(args, table, stack))
    ECall(fun, args) ->
      ECall(resolve(fun, table, stack), resolve_all(args, table, stack))
    EBinop(op, left, right) ->
      EBinop(op, resolve(left, table, stack), resolve(right, table, stack))
    EUnop(op, operand) -> EUnop(op, resolve(operand, table, stack))
    EBlock(statements) ->
      EBlock(
        list.map(statements, fn(statement) {
          resolve_statement(statement, table, stack)
        }),
      )
    ECase(subject, arms) ->
      ECase(
        resolve(subject, table, stack),
        list.map(arms, fn(arm) {
          let Arm(pattern, guard, body) = arm
          Arm(
            pattern,
            resolve_opt(guard, table, stack),
            resolve(body, table, stack),
          )
        }),
      )
    ETuple(elements) -> ETuple(resolve_all(elements, table, stack))
    ELabelled(name, value) -> ELabelled(name, resolve(value, table, stack))
    ELambda(params, body) -> ELambda(params, resolve(body, table, stack))
    EClosure(code, captures, env_ty, fn_ty) ->
      EClosure(code, resolve_all(captures, table, stack), env_ty, fn_ty)
    EUpdate(name, base, fields) ->
      EUpdate(
        name,
        resolve(base, table, stack),
        list.map(fields, fn(field) {
          let #(field_name, value) = field
          #(field_name, resolve(value, table, stack))
        }),
      )
    EBitArray(elements) -> EBitArray(resolve_all(elements, table, stack))
    EInt(_)
    | EFloat(_)
    | EString(_)
    | EBool(_)
    | ENil
    | EEnvGet(_, _, _)
    | EPanic(_, _) -> expr
  }
}

fn resolve_all(exprs, table, stack) -> List(Expr) {
  list.map(exprs, fn(expr) { resolve(expr, table, stack) })
}

fn resolve_statement(statement, table, stack) {
  case statement {
    Let(pattern, value) -> Let(pattern, resolve(value, table, stack))
    Stmt(expr) -> Stmt(resolve(expr, table, stack))
  }
}

fn resolve_opt(opt: Option(Expr), table, stack) -> Option(Expr) {
  case opt {
    None -> None
    Some(expr) -> Some(resolve(expr, table, stack))
  }
}
