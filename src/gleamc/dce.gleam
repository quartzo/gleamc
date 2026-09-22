//// Dead-code elimination: after monomorphisation, drop top-level functions
//// that are not reachable from `main` or a public function.

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleamc/ast.{
  type Module, Arm, DFunction, EBinop, EBitArray, EBlock, ECall, ECase, EClosure,
  ECtor, EField, ELabelled, ELambda, ETuple, EUnop, EUpdate, EVar, Let, Module,
  PBitArray, PCtor, PLabelled, PTuple, Stmt,
}

pub fn prune(module: Module) -> Module {
  let Module(definitions) = module
  let functions =
    list.filter_map(definitions, fn(definition) {
      case definition {
        DFunction(function) -> Ok(function.name)
        _ -> Error(Nil)
      }
    })
  let known =
    list.fold(functions, dict.new(), fn(acc, name) {
      dict.insert(acc, name, True)
    })
  let roots = case list.contains(functions, "main") {
    // A program with an entry point only needs what `main` reaches.
    True -> ["main"]
    // Otherwise keep the public API.
    False ->
      list.filter_map(definitions, fn(definition) {
        case definition {
          DFunction(function) ->
            case function.is_pub {
              True -> Ok(function.name)
              False -> Error(Nil)
            }
          _ -> Error(Nil)
        }
      })
  }
  case roots {
    [] -> module
    _ -> {
      let reachable = wander(roots, definitions, known, dict.new())
      Module(
        list.filter(definitions, fn(definition) {
          case definition {
            DFunction(function) -> dict.has_key(reachable, function.name)
            _ -> True
          }
        }),
      )
    }
  }
}

fn wander(pending, definitions, known, visited) {
  case pending {
    [] -> visited
    [name, ..rest] ->
      case dict.has_key(visited, name) {
        True -> wander(rest, definitions, known, visited)
        False -> {
          let visited = dict.insert(visited, name, True)
          let refs = case function_body(definitions, name) {
            Ok(body) -> expr_refs(body, [])
            Error(_) -> []
          }
          let next = list.filter(refs, fn(ref) { dict.has_key(known, ref) })
          wander(list.append(rest, next), definitions, known, visited)
        }
      }
  }
}

fn function_body(definitions, name) {
  case definitions {
    [] -> Error(Nil)
    [DFunction(function), ..rest] ->
      case function.name == name {
        True -> Ok(function.body)
        False -> function_body(rest, name)
      }
    [_, ..rest] -> function_body(rest, name)
  }
}

fn expr_refs(expr, acc) -> List(String) {
  case expr {
    EVar(name) -> [name, ..acc]
    EClosure(code, captures, _, _) ->
      list.fold(captures, [drop_prefix(code), ..acc], fn(acc, x) {
        expr_refs(x, acc)
      })
    EBitArray(elements) ->
      list.fold(elements, acc, fn(acc, x) { expr_refs(x, acc) })
    ETuple(elements) ->
      list.fold(elements, acc, fn(acc, x) { expr_refs(x, acc) })
    ECtor(_, args) -> list.fold(args, acc, fn(acc, x) { expr_refs(x, acc) })
    ECall(fun, args) -> {
      let acc = expr_refs(fun, acc)
      list.fold(args, acc, fn(acc, x) { expr_refs(x, acc) })
    }
    EBinop(_, left, right) -> expr_refs(right, expr_refs(left, acc))
    EUnop(_, operand) -> expr_refs(operand, acc)
    EField(obj, _) -> expr_refs(obj, acc)
    ELabelled(_, value) -> expr_refs(value, acc)
    ELambda(_, body) -> expr_refs(body, acc)
    EUpdate(_, base, fields) -> {
      let acc = expr_refs(base, acc)
      list.fold(fields, acc, fn(acc, field) {
        let #(_, value) = field
        expr_refs(value, acc)
      })
    }
    EBlock(statements) ->
      list.fold(statements, acc, fn(acc, x) { stmt_refs(x, acc) })
    ECase(subject, arms) -> {
      let acc = expr_refs(subject, acc)
      list.fold(arms, acc, fn(acc, arm) {
        let Arm(pattern, guard, body) = arm
        let acc = pattern_refs(pattern, acc)
        let acc = case guard {
          Some(g) -> expr_refs(g, acc)
          None -> acc
        }
        expr_refs(body, acc)
      })
    }
    _ -> acc
  }
}

fn stmt_refs(statement, acc) {
  case statement {
    Let(pattern, value) -> expr_refs(value, pattern_refs(pattern, acc))
    Stmt(expr) -> expr_refs(expr, acc)
  }
}

fn pattern_refs(pattern, acc) {
  case pattern {
    PCtor(_, args) -> list.fold(args, acc, fn(acc, x) { pattern_refs(x, acc) })
    PBitArray(patterns) ->
      list.fold(patterns, acc, fn(acc, x) { pattern_refs(x, acc) })
    PTuple(patterns) ->
      list.fold(patterns, acc, fn(acc, x) { pattern_refs(x, acc) })
    PLabelled(_, inner) -> pattern_refs(inner, acc)
    _ -> acc
  }
}

fn drop_prefix(code) -> String {
  case string.starts_with(code, "Gleamc_") {
    True -> string.drop_start(code, 7)
    False -> code
  }
}
