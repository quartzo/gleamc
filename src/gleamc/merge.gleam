//// Module merge (M8): qualifies function names per module and inlines
//// every loaded module into a single AST, so the rest of the pipeline
//// stays single-module.
////
//// Naming: the entry module has name "" (no prefix); other modules use
//// their import alias (last path segment). Local calls become qualified
//// (`mod_fn`); cross-module calls `mod.fn(...)` become `mod_fn(...)`.
//// Custom type names are global and must be unique across modules.

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleamc/ast.{
  type Definition, type Expr, type Module, type Statement, Arm, DFunction,
  DImport, EBinop, EBitArray, EBlock, EBool, ECall, ECase, EClosure, ECtor,
  EEnvGet, EField, EFloat, EInt, ELabelled, ELambda, ENil, EPanic, EString,
  ETuple, EUnop, EUpdate, EVar, Function, Let, Module, Stmt,
}

pub fn merge(modules: List(#(String, Module))) -> Module {
  // alias -> the function names that module actually defines; used to decide
  // whether `mod.fn(...)` is a real module call or a builtin.
  let exports =
    list.fold(modules, dict.new(), fn(acc, entry) {
      let #(name, module) = entry
      let Module(defs) = module
      let fns =
        list_filter_map(defs, fn(definition) {
          case definition {
            DFunction(function) -> Ok(function.name)
            _ -> Error(Nil)
          }
        })
      dict.insert(acc, name, fns)
    })
  let definitions =
    list_flat_map(modules, fn(entry) {
      let #(name, module) = entry
      let Module(defs) = module
      let local_fns =
        list_filter_map(defs, fn(definition) {
          case definition {
            DFunction(function) -> Ok(function.name)
            _ -> Error(Nil)
          }
        })
      list_filter_map(defs, fn(definition) {
        case definition {
          DImport(_) -> Error(Nil)
          DFunction(_) ->
            Ok(rewrite_definition(definition, name, local_fns, exports))
          _ -> Ok(definition)
        }
      })
    })
  Module(definitions)
}

fn rewrite_definition(definition, module, local_fns, exports) -> Definition {
  case definition {
    DFunction(function) ->
      DFunction(Function(
        function.is_pub,
        qualify(module, function.name),
        function.params,
        function.ret,
        rewrite_expr(function.body, module, local_fns, exports),
        function.line,
      ))
    _ -> definition
  }
}

fn is_lower_name(name) -> Bool {
  case string.first(name) {
    Ok(first) -> string.contains("abcdefghijklmnopqrstuvwxyz", first)
    Error(_) -> False
  }
}

fn qualify(module, name) -> String {
  case module {
    "" -> name
    _ -> module <> "_" <> name
  }
}

fn rewrite_expr(expr, module, local_fns, exports) -> Expr {
  case expr {
    EInt(_) | EFloat(_) | EString(_) | EBool(_) | ENil | EVar(_) -> expr
    ETuple(elements) ->
      ETuple(
        list_map(elements, fn(element) {
          rewrite_expr(element, module, local_fns, exports)
        }),
      )
    ECtor(name, args) ->
      ECtor(
        name,
        list_map(args, fn(arg) { rewrite_expr(arg, module, local_fns, exports) }),
      )
    ECall(fun, args) ->
      ECall(
        rewrite_target(fun, module, local_fns, exports),
        list_map(args, fn(arg) { rewrite_expr(arg, module, local_fns, exports) }),
      )
    EBinop(op, left, right) ->
      EBinop(
        op,
        rewrite_expr(left, module, local_fns, exports),
        rewrite_expr(right, module, local_fns, exports),
      )
    EUnop(op, operand) ->
      EUnop(op, rewrite_expr(operand, module, local_fns, exports))
    EBlock(statements) ->
      EBlock(
        list_map(statements, fn(statement) {
          rewrite_statement(statement, module, local_fns, exports)
        }),
      )
    ECase(subject, arms) ->
      ECase(
        rewrite_expr(subject, module, local_fns, exports),
        list_map(arms, fn(arm) {
          let Arm(pattern, guard, body) = arm
          Arm(
            pattern,
            rewrite_guard(guard, module, local_fns, exports),
            rewrite_expr(body, module, local_fns, exports),
          )
        }),
      )
    EField(EVar(alias), name) ->
      case is_lower_name(name) && module_exports(exports, alias, name) {
        True -> EVar(qualify(alias, name))
        False -> EField(EVar(alias), name)
      }
    EField(obj, name) ->
      EField(rewrite_expr(obj, module, local_fns, exports), name)
    ELabelled(label, value) ->
      ELabelled(label, rewrite_expr(value, module, local_fns, exports))
    ELambda(params, body) ->
      ELambda(params, rewrite_expr(body, module, local_fns, exports))
    EClosure(code, captures, env_ty, fn_ty) ->
      EClosure(
        code,
        list_map(captures, fn(cap) {
          rewrite_expr(cap, module, local_fns, exports)
        }),
        env_ty,
        fn_ty,
      )
    EEnvGet(_, _, _) -> expr
    EPanic(_, _) -> expr
    EBitArray(elements) ->
      EBitArray(
        list_map(elements, fn(element) {
          rewrite_expr(element, module, local_fns, exports)
        }),
      )
    EUpdate(name, base, fields) ->
      EUpdate(
        name,
        rewrite_expr(base, module, local_fns, exports),
        list_map(fields, fn(field) {
          let #(label, value) = field
          #(label, rewrite_expr(value, module, local_fns, exports))
        }),
      )
  }
}

fn rewrite_guard(guard, module, local_fns, exports) {
  case guard {
    Some(expr) -> Some(rewrite_expr(expr, module, local_fns, exports))
    None -> None
  }
}

fn rewrite_statement(statement, module, local_fns, exports) -> Statement {
  case statement {
    Let(pattern, value) ->
      Let(pattern, rewrite_expr(value, module, local_fns, exports))
    Stmt(expr) -> Stmt(rewrite_expr(expr, module, local_fns, exports))
  }
}

fn rewrite_target(fun, module, local_fns, exports) -> Expr {
  case fun {
    EVar(name) ->
      case list_contains(local_fns, name) {
        True -> EVar(qualify(module, name))
        False -> fun
      }
    EField(EVar(alias), name) ->
      // `mod.func` -> `mod_func`; `mod.Constructor` is left for the
      // constructor-qualification pass.
      case is_lower_name(name) && module_exports(exports, alias, name) {
        True -> EVar(qualify(alias, name))
        False -> fun
      }
    _ -> rewrite_expr(fun, module, local_fns, exports)
  }
}

// ---------------------------------------------------------------------------
// small list helpers
// ---------------------------------------------------------------------------

fn list_map(items, f) {
  case items {
    [] -> []
    [item, ..rest] -> [f(item), ..list_map(rest, f)]
  }
}

fn list_flat_map(items, f) {
  case items {
    [] -> []
    [item, ..rest] -> list_append(f(item), list_flat_map(rest, f))
  }
}

fn list_filter_map(items, f) {
  case items {
    [] -> []
    [item, ..rest] ->
      case f(item) {
        Ok(value) -> [value, ..list_filter_map(rest, f)]
        Error(_) -> list_filter_map(rest, f)
      }
  }
}

fn list_append(a, b) {
  case a {
    [] -> b
    [head, ..tail] -> [head, ..list_append(tail, b)]
  }
}

fn module_exports(exports, alias, name) -> Bool {
  case dict.get(exports, alias) {
    Ok(fns) -> list_contains(fns, name)
    Error(_) -> False
  }
}

fn list_contains(items, value) -> Bool {
  case items {
    [] -> False
    [head, ..tail] ->
      case head == value {
        True -> True
        False -> list_contains(tail, value)
      }
  }
}
