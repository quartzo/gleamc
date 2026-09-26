//// Dead-code elimination: after monomorphisation, drop top-level functions
//// that are not reachable from `main` or a public function.

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleamc/ast.{PBitArray, PCtor, PLabelled, PTuple}
import gleamc/tmono

pub fn prune(module: tmono.TModule) -> tmono.TModule {
  let tmono.TModule(definitions) = module
  let functions =
    list.filter_map(definitions, fn(definition) {
      case definition {
        tmono.TDFunction(function) -> Ok(function.name)
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
          tmono.TDFunction(function) ->
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
      tmono.TModule(
        list.filter(definitions, fn(definition) {
          case definition {
            tmono.TDFunction(function) -> dict.has_key(reachable, function.name)
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
          let next = refs_in_known(refs, known, [])
          wander(list.append(rest, next), definitions, known, visited)
        }
      }
  }
}

fn refs_in_known(refs, known, acc) {
  case refs {
    [] -> list.reverse(acc)
    [ref, ..rest] ->
      case dict.has_key(known, ref) {
        True -> refs_in_known(rest, known, [ref, ..acc])
        False -> refs_in_known(rest, known, acc)
      }
  }
}

fn function_body(definitions, name) {
  case definitions {
    [] -> Error(Nil)
    [tmono.TDFunction(function), ..rest] ->
      case function.name == name {
        True -> Ok(function.body)
        False -> function_body(rest, name)
      }
    [_, ..rest] -> function_body(rest, name)
  }
}

fn expr_refs(expr, acc) -> List(String) {
  case expr {
    tmono.TVar(name, _) -> [name, ..acc]
    tmono.TClosure(code, captures, _, _, _) ->
      list.fold(captures, [drop_prefix(code), ..acc], fn(acc, x) {
        expr_refs(x, acc)
      })
    tmono.TBitArray(elements, _) ->
      list.fold(elements, acc, fn(acc, x) { expr_refs(x, acc) })
    tmono.TTuple(elements, _) ->
      list.fold(elements, acc, fn(acc, x) { expr_refs(x, acc) })
    tmono.TCtor(_, args, _) ->
      list.fold(args, acc, fn(acc, x) { expr_refs(x, acc) })
    tmono.TCall(fun, args, _) -> {
      let acc = expr_refs(fun, acc)
      list.fold(args, acc, fn(acc, x) { expr_refs(x, acc) })
    }
    tmono.TBinop(_, left, right, _) -> expr_refs(right, expr_refs(left, acc))
    tmono.TUnop(_, operand, _) -> expr_refs(operand, acc)
    tmono.TField(obj, _, _) -> expr_refs(obj, acc)
    tmono.TLabelled(_, value, _) -> expr_refs(value, acc)
    tmono.TLambda(_, body, _) -> expr_refs(body, acc)
    tmono.TUpdate(_, base, fields, _) -> {
      let acc = expr_refs(base, acc)
      list.fold(fields, acc, fn(acc, field) {
        let #(_, value) = field
        expr_refs(value, acc)
      })
    }
    tmono.TBlock(statements, _) ->
      list.fold(statements, acc, fn(acc, x) { stmt_refs(x, acc) })
    tmono.TCase(subject, arms, _) -> {
      let acc = expr_refs(subject, acc)
      list.fold(arms, acc, fn(acc, arm) {
        let tmono.TArm(pattern, guard, body) = arm
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
    tmono.TLet(pattern, value) -> expr_refs(value, pattern_refs(pattern, acc))
    tmono.TStmt(expr) -> expr_refs(expr, acc)
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
