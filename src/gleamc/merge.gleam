//// Module merge (M8): qualifies function names per module and inlines
//// every loaded module into a single AST, so the rest of the pipeline
//// stays single-module.
////
//// Naming: the entry module has name "" (no prefix); other modules use
//// their import alias (last path segment). Local calls become qualified
//// (`mod_fn`); cross-module calls `mod.fn(...)` become `mod_fn(...)`.
////
//// Constructors are module-scoped, like the official compiler: a name may be
//// reused across modules but must be unique within a module. They are
//// canonicalised to `alias.Ctor` (bare for the entry module) so the rest of
//// the pipeline can keep resolving constructors by name.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleamc/ast.{
  type Definition, type Expr, type Module, type Pattern, type Statement, Arm,
  CustomType, DCustomType, DFunction, DImport, EBinop, EBitArray, EBlock, EBool,
  ECall, ECase, EClosure, ECtor, EEnvGet, EField, EFloat, EInt, ELabelled,
  ELambda, ENil, EPanic, EString, ETuple, EUnop, EUpdate, EVar, Function, Let,
  Module, PBitArray, PCtor, PLabelled, PTuple, Stmt, Variant,
}

type Ctx {
  Ctx(
    /// alias -> function names the module defines.
    exports: Dict(String, List(String)),
    /// alias -> constructor names the module defines.
    ctors: Dict(String, Dict(String, Bool)),
    /// constructor name -> aliases that define it.
    owners: Dict(String, List(String)),
  )
}

pub fn merge(modules: List(#(String, Module))) -> Result(Module, String) {
  let modules = dedupe_modules(modules)
  let ctx = build_ctx(modules)
  use _ <- result.try(validate_modules(modules))
  let definitions =
    list_flat_map(modules, fn(entry) {
      let #(name, module) = entry
      let Module(defs) = module
      list_filter_map(defs, fn(definition) {
        case definition {
          DImport(_) -> Error(Nil)
          _ -> Ok(rewrite_definition(definition, name, ctx))
        }
      })
    })
  Ok(Module(definitions))
}

/// Drops duplicate module entries (the same module may be read along several
/// import paths).
fn dedupe_modules(modules) -> List(#(String, Module)) {
  let #(_seen, kept) =
    list.fold(list.reverse(modules), #(dict.new(), []), fn(acc, entry) {
      let #(seen, kept) = acc
      let #(alias, _) = entry
      case dict.has_key(seen, alias) {
        True -> acc
        False -> #(dict.insert(seen, alias, True), [entry, ..kept])
      }
    })
  kept
}

fn build_ctx(modules) -> Ctx {
  let exports =
    list.fold(modules, dict.new(), fn(acc, entry) {
      let #(name, module) = entry
      let Module(defs) = module
      dict.insert(acc, name, module_function_names(defs))
    })
  let ctors =
    list.fold(modules, dict.new(), fn(acc, entry) {
      let #(name, module) = entry
      let Module(defs) = module
      dict.insert(acc, name, module_ctor_set(defs))
    })
  let owners =
    list.fold(modules, dict.new(), fn(acc, entry) {
      let #(name, module) = entry
      let Module(defs) = module
      list.fold(module_ctor_names(defs), acc, fn(acc, ctor) {
        let existing = case dict.get(acc, ctor) {
          Ok(found) -> found
          Error(_) -> []
        }
        dict.insert(acc, ctor, [name, ..existing])
      })
    })
  Ctx(exports, ctors, owners)
}

fn module_function_names(defs) {
  list_filter_map(defs, fn(definition) {
    case definition {
      DFunction(function) -> Ok(function.name)
      _ -> Error(Nil)
    }
  })
}

fn module_ctor_names(defs) {
  list.flat_map(defs, fn(definition) {
    case definition {
      DCustomType(custom) -> {
        let CustomType(_, _, _, variants, _) = custom
        list.map(variants, fn(variant) {
          let Variant(name, _) = variant
          name
        })
      }
      _ -> []
    }
  })
}

fn module_ctor_set(defs) {
  list.fold(module_ctor_names(defs), dict.new(), fn(acc, ctor) {
    dict.insert(acc, ctor, True)
  })
}

/// A constructor name may not be defined twice in the same module.
fn validate_modules(modules) -> Result(Nil, String) {
  list.try_each(modules, fn(entry) {
    let #(alias, module) = entry
    let Module(defs) = module
    case no_duplicates(module_ctor_names(defs), []) {
      Ok(_) -> Ok(Nil)
      Error(_) ->
        Error(
          "constructor names must be unique within a module (module `"
          <> alias
          <> "`)",
        )
    }
  })
}

fn no_duplicates(names, seen) -> Result(Nil, Nil) {
  case names {
    [] -> Ok(Nil)
    [name, ..rest] ->
      case list_contains(seen, name) {
        True -> Error(Nil)
        False -> no_duplicates(rest, [name, ..seen])
      }
  }
}

// ---------------------------------------------------------------------------
// constructor resolution
// ---------------------------------------------------------------------------

fn canonical(module, name) -> String {
  case module {
    "" -> name
    _ -> module <> "." <> name
  }
}

fn module_has_ctor(ctx: Ctx, alias, name) -> Bool {
  case dict.get(ctx.ctors, alias) {
    Ok(names) -> dict.has_key(names, name)
    Error(_) -> False
  }
}

/// Resolves a constructor reference to its canonical name. A dotted name is
/// already module-qualified; an unqualified name prefers the current module's
/// constructor, then a globally unique one.
fn resolve_ctor(ctx: Ctx, module, name) -> String {
  case string.contains(name, ".") {
    True -> name
    False ->
      case module_has_ctor(ctx, module, name) {
        True -> canonical(module, name)
        False ->
          case dict.get(ctx.owners, name) {
            Ok([only]) -> canonical(only, name)
            _ -> name
          }
      }
  }
}

// ---------------------------------------------------------------------------
// definitions
// ---------------------------------------------------------------------------

fn rewrite_definition(definition, module, ctx) -> Definition {
  case definition {
    DFunction(function) ->
      DFunction(Function(
        function.is_pub,
        qualify(module, function.name),
        function.params,
        function.ret,
        rewrite_expr(function.body, module, ctx),
        function.line,
      ))
    DCustomType(custom) -> {
      let CustomType(is_pub, name, generics, variants, is_opaque) = custom
      DCustomType(CustomType(
        is_pub,
        name,
        generics,
        list_map(variants, fn(variant) {
          let Variant(variant_name, fields) = variant
          Variant(canonical(module, variant_name), fields)
        }),
        is_opaque,
      ))
    }
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

fn rewrite_expr(expr, module, ctx) -> Expr {
  case expr {
    EInt(_) | EFloat(_) | EString(_) | EBool(_) | ENil | EVar(_) -> expr
    ETuple(elements) ->
      ETuple(
        list_map(elements, fn(element) { rewrite_expr(element, module, ctx) }),
      )
    ECtor(name, args) ->
      ECtor(
        resolve_ctor(ctx, module, name),
        list_map(args, fn(arg) { rewrite_expr(arg, module, ctx) }),
      )
    ECall(EField(EVar(alias), name), args) ->
      case module_has_ctor(ctx, alias, name) {
        True ->
          ECtor(
            canonical(alias, name),
            list_map(args, fn(arg) { rewrite_expr(arg, module, ctx) }),
          )
        False ->
          ECall(
            rewrite_target(EField(EVar(alias), name), module, ctx),
            list_map(args, fn(arg) { rewrite_expr(arg, module, ctx) }),
          )
      }
    ECall(fun, args) ->
      ECall(
        rewrite_target(fun, module, ctx),
        list_map(args, fn(arg) { rewrite_expr(arg, module, ctx) }),
      )
    EBinop(op, left, right) ->
      EBinop(
        op,
        rewrite_expr(left, module, ctx),
        rewrite_expr(right, module, ctx),
      )
    EUnop(op, operand) -> EUnop(op, rewrite_expr(operand, module, ctx))
    EBlock(statements) ->
      EBlock(
        list_map(statements, fn(statement) {
          rewrite_statement(statement, module, ctx)
        }),
      )
    ECase(subject, arms) ->
      ECase(
        rewrite_expr(subject, module, ctx),
        list_map(arms, fn(arm) {
          let Arm(pattern, guard, body) = arm
          Arm(
            rewrite_pattern(pattern, module, ctx),
            rewrite_guard(guard, module, ctx),
            rewrite_expr(body, module, ctx),
          )
        }),
      )
    EField(EVar(alias), name) ->
      case module_has_ctor(ctx, alias, name) {
        True -> ECtor(canonical(alias, name), [])
        False ->
          case is_lower_name(name) && module_exports(ctx.exports, alias, name) {
            True -> EVar(qualify(alias, name))
            False -> EField(EVar(alias), name)
          }
      }
    EField(obj, name) -> EField(rewrite_expr(obj, module, ctx), name)
    ELabelled(label, value) ->
      ELabelled(label, rewrite_expr(value, module, ctx))
    ELambda(params, body) -> ELambda(params, rewrite_expr(body, module, ctx))
    EClosure(code, captures, env_ty, fn_ty) ->
      EClosure(
        code,
        list_map(captures, fn(cap) { rewrite_expr(cap, module, ctx) }),
        env_ty,
        fn_ty,
      )
    EEnvGet(_, _, _) -> expr
    EPanic(_, _) -> expr
    EBitArray(elements) ->
      EBitArray(
        list_map(elements, fn(element) { rewrite_expr(element, module, ctx) }),
      )
    EUpdate(name, base, fields) ->
      EUpdate(
        resolve_ctor(ctx, module, name),
        rewrite_expr(base, module, ctx),
        list_map(fields, fn(field) {
          let #(label, value) = field
          #(label, rewrite_expr(value, module, ctx))
        }),
      )
  }
}

fn rewrite_pattern(pattern, module, ctx) -> Pattern {
  case pattern {
    PCtor(name, args) ->
      PCtor(
        resolve_ctor(ctx, module, name),
        list_map(args, fn(arg) { rewrite_pattern(arg, module, ctx) }),
      )
    PTuple(patterns) ->
      PTuple(
        list_map(patterns, fn(inner) { rewrite_pattern(inner, module, ctx) }),
      )
    PBitArray(patterns) ->
      PBitArray(
        list_map(patterns, fn(inner) { rewrite_pattern(inner, module, ctx) }),
      )
    PLabelled(label, inner) ->
      PLabelled(label, rewrite_pattern(inner, module, ctx))
    _ -> pattern
  }
}

fn rewrite_guard(guard, module, ctx) {
  case guard {
    Some(expr) -> Some(rewrite_expr(expr, module, ctx))
    None -> None
  }
}

fn rewrite_statement(statement, module, ctx) -> Statement {
  case statement {
    Let(pattern, value) ->
      Let(
        rewrite_pattern(pattern, module, ctx),
        rewrite_expr(value, module, ctx),
      )
    Stmt(expr) -> Stmt(rewrite_expr(expr, module, ctx))
  }
}

fn rewrite_target(fun, module, ctx) -> Expr {
  case fun {
    EVar(name) ->
      case list_contains(module_local_fns(ctx, module), name) {
        True -> EVar(qualify(module, name))
        False -> fun
      }
    EField(EVar(alias), name) ->
      case is_lower_name(name) && module_exports(ctx.exports, alias, name) {
        True -> EVar(qualify(alias, name))
        False -> fun
      }
    _ -> rewrite_expr(fun, module, ctx)
  }
}

fn module_local_fns(ctx: Ctx, module) -> List(String) {
  case dict.get(ctx.exports, module) {
    Ok(fns) -> fns
    Error(_) -> []
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
