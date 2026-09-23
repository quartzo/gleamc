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
  ELambda, ENil, EPanic, EString, ETuple, EUnop, EUpdate, EVar, Function, Import,
  Let, Module, PAs, PBitArray, PCtor, PLabelled, PTuple, PVar, Stmt, Variant,
}

type Ctx {
  Ctx(
    /// alias -> function names the module defines.
    exports: Dict(String, List(String)),
    /// alias -> constructor names the module defines.
    ctors: Dict(String, Dict(String, Bool)),
    /// constructor name -> aliases that define it.
    owners: Dict(String, List(String)),
    /// alias -> (unqualified function name -> source alias).
    fn_scope: Dict(String, Dict(String, String)),
    /// alias -> (unqualified constructor name -> canonical name).
    ctor_scope: Dict(String, Dict(String, String)),
    /// import conflicts (a name imported from two places, or shadowing a local).
    conflicts: List(String),
  )
}

pub fn merge(modules: List(#(String, Module))) -> Result(Module, String) {
  let modules = dedupe_modules(modules)
  let ctx = build_ctx(modules)
  use _ <- result.try(validate_modules(modules, ctx))
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
  let fn_scope =
    list.fold(modules, dict.new(), fn(acc, entry) {
      let #(name, module) = entry
      let Module(defs) = module
      dict.insert(acc, name, module_fn_scope(defs, name, exports))
    })
  let ctor_scope =
    list.fold(modules, dict.new(), fn(acc, entry) {
      let #(name, module) = entry
      let Module(defs) = module
      dict.insert(acc, name, module_ctor_scope(defs, name, ctors, owners))
    })
  let conflicts =
    list.flat_map(modules, fn(entry) {
      let #(name, module) = entry
      let Module(defs) = module
      scope_conflicts(name, defs, exports, ctors)
    })
  Ctx(exports, ctors, owners, fn_scope, ctor_scope, conflicts)
}

fn module_fn_scope(defs, _alias, exports) {
  list.fold(import_decls(defs), dict.new(), fn(acc, import_decl) {
    let Import(path, items) = import_decl
    let source = last_segment(path)
    case dict.get(exports, source) {
      Error(_) -> acc
      Ok(fns) ->
        list.fold(items, acc, fn(acc, item) {
          case list_contains(fns, item) {
            True -> dict.insert(acc, item, source)
            False -> acc
          }
        })
    }
  })
}

fn module_ctor_scope(defs, _alias, ctors, _owners) {
  list.fold(import_decls(defs), dict.new(), fn(acc, import_decl) {
    let Import(path, items) = import_decl
    let source = last_segment(path)
    case dict.get(ctors, source) {
      Error(_) -> acc
      Ok(names) ->
        list.fold(items, acc, fn(acc, item) {
          case dict.has_key(names, item) {
            True -> dict.insert(acc, item, canonical(source, item))
            False -> acc
          }
        })
    }
  })
}

/// A name imported twice (from different modules) or shadowing a local is an
/// error, matching the official compiler.
fn scope_conflicts(alias, defs, exports, ctors) {
  let #(_seen, conflicts) =
    list.fold(import_decls(defs), #(dict.new(), []), fn(acc, import_decl) {
      let #(seen, conflicts) = acc
      let Import(path, items) = import_decl
      let source = last_segment(path)
      list.fold(items, #(seen, conflicts), fn(acc, item) {
        let #(seen, conflicts) = acc
        case dict.get(seen, item) {
          Ok(previous) ->
            case previous == source {
              True -> acc
              False -> #(seen, [conflict_message(alias, item), ..conflicts])
            }
          Error(_) ->
            case is_known_item(exports, ctors, source, item) {
              True -> #(dict.insert(seen, item, source), conflicts)
              False -> acc
            }
        }
      })
    })
  conflicts
}

fn is_known_item(exports, ctors, source, item) {
  let is_fn = case dict.get(exports, source) {
    Ok(fns) -> list_contains(fns, item)
    Error(_) -> False
  }
  let is_ctor = case dict.get(ctors, source) {
    Ok(names) -> dict.has_key(names, item)
    Error(_) -> False
  }
  is_fn || is_ctor
}

fn conflict_message(alias, item) {
  "`" <> item <> "` is imported multiple times (module `" <> alias <> "`)"
}

fn import_decls(defs) {
  list_filter_map(defs, fn(definition) {
    case definition {
      DImport(import_decl) -> Ok(import_decl)
      _ -> Error(Nil)
    }
  })
}

fn last_segment(path) {
  case list.reverse(path) {
    [last, ..] -> last
    [] -> ""
  }
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

/// A constructor name may not be defined twice in the same module, and an
/// imported name may not clash with a local one.
fn validate_modules(modules, ctx: Ctx) -> Result(Nil, String) {
  case ctx.conflicts {
    [conflict, ..] -> Error(conflict)
    [] ->
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
      case lookups(ctx.ctor_scope, module, name) {
        Ok(found) -> found
        Error(_) ->
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
}

fn lookups(scope, module, name) -> Result(String, Nil) {
  case dict.get(scope, module) {
    Ok(names) ->
      case dict.get(names, name) {
        Ok(found) -> Ok(found)
        Error(_) -> Error(Nil)
      }
    Error(_) -> Error(Nil)
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
        rewrite_expr(
          function.body,
          module,
          ctx,
          list_map(function.params, fn(param) {
            let #(name, _) = param
            name
          }),
        ),
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

fn rewrite_expr(expr, module, ctx, bound) -> Expr {
  case expr {
    EInt(_) | EFloat(_) | EString(_) | EBool(_) | ENil -> expr
    EVar(name) ->
      case list_contains(bound, name) {
        True -> expr
        False ->
          case list_contains(module_local_fns(ctx, module), name) {
            True -> EVar(qualify(module, name))
            False ->
              case lookups(ctx.fn_scope, module, name) {
                Ok(source) -> EVar(qualify(source, name))
                Error(_) -> expr
              }
          }
      }
    ETuple(elements) ->
      ETuple(
        list_map(elements, fn(element) {
          rewrite_expr(element, module, ctx, bound)
        }),
      )
    ECtor(name, args) ->
      ECtor(
        resolve_ctor(ctx, module, name),
        list_map(args, fn(arg) { rewrite_expr(arg, module, ctx, bound) }),
      )
    ECall(EField(EVar(alias), name), args) ->
      case module_has_ctor(ctx, alias, name) {
        True ->
          ECtor(
            canonical(alias, name),
            list_map(args, fn(arg) { rewrite_expr(arg, module, ctx, bound) }),
          )
        False ->
          ECall(
            rewrite_target(EField(EVar(alias), name), module, ctx, bound),
            list_map(args, fn(arg) { rewrite_expr(arg, module, ctx, bound) }),
          )
      }
    ECall(fun, args) ->
      ECall(
        rewrite_target(fun, module, ctx, bound),
        list_map(args, fn(arg) { rewrite_expr(arg, module, ctx, bound) }),
      )
    EBinop(op, left, right) ->
      EBinop(
        op,
        rewrite_expr(left, module, ctx, bound),
        rewrite_expr(right, module, ctx, bound),
      )
    EUnop(op, operand) -> EUnop(op, rewrite_expr(operand, module, ctx, bound))
    EBlock(statements) ->
      EBlock(rewrite_statements(statements, module, ctx, bound))
    ECase(subject, arms) ->
      ECase(
        rewrite_expr(subject, module, ctx, bound),
        list_map(arms, fn(arm) {
          let Arm(pattern, guard, body) = arm
          let inner = list.append(pattern_bindings(pattern), bound)
          Arm(
            rewrite_pattern(pattern, module, ctx),
            rewrite_guard(guard, module, ctx, inner),
            rewrite_expr(body, module, ctx, inner),
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
    EField(obj, name) -> EField(rewrite_expr(obj, module, ctx, bound), name)
    ELabelled(label, value) ->
      ELabelled(label, rewrite_expr(value, module, ctx, bound))
    ELambda(params, body) ->
      ELambda(
        params,
        rewrite_expr(body, module, ctx, list.append(params, bound)),
      )
    EClosure(code, captures, env_ty, fn_ty) ->
      EClosure(
        code,
        list_map(captures, fn(cap) { rewrite_expr(cap, module, ctx, bound) }),
        env_ty,
        fn_ty,
      )
    EEnvGet(_, _, _) -> expr
    EPanic(_, _) -> expr
    EBitArray(elements) ->
      EBitArray(
        list_map(elements, fn(element) {
          rewrite_expr(element, module, ctx, bound)
        }),
      )
    EUpdate(name, base, fields) ->
      EUpdate(
        resolve_ctor(ctx, module, name),
        rewrite_expr(base, module, ctx, bound),
        list_map(fields, fn(field) {
          let #(label, value) = field
          #(label, rewrite_expr(value, module, ctx, bound))
        }),
      )
  }
}

fn rewrite_statements(statements, module, ctx, bound) -> List(Statement) {
  case statements {
    [] -> []
    [statement, ..rest] ->
      case statement {
        Let(pattern, value) -> {
          let value2 = rewrite_expr(value, module, ctx, bound)
          let inner = list.append(pattern_bindings(pattern), bound)
          [
            Let(rewrite_pattern(pattern, module, ctx), value2),
            ..rewrite_statements(rest, module, ctx, inner)
          ]
        }
        Stmt(expr) -> [
          Stmt(rewrite_expr(expr, module, ctx, bound)),
          ..rewrite_statements(rest, module, ctx, bound)
        ]
      }
  }
}

fn pattern_bindings(pattern) -> List(String) {
  case pattern {
    PVar(name) -> [name]
    PAs(inner, name) -> [name, ..pattern_bindings(inner)]
    PLabelled(_, inner) -> pattern_bindings(inner)
    PCtor(_, args) -> list_flat_map(args, pattern_bindings)
    PTuple(patterns) -> list_flat_map(patterns, pattern_bindings)
    PBitArray(patterns) -> list_flat_map(patterns, pattern_bindings)
    _ -> []
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

fn rewrite_guard(guard, module, ctx, bound) {
  case guard {
    Some(expr) -> Some(rewrite_expr(expr, module, ctx, bound))
    None -> None
  }
}

fn rewrite_target(fun, module, ctx, bound) -> Expr {
  case fun {
    EVar(name) ->
      case list_contains(bound, name) {
        True -> fun
        False ->
          case list_contains(module_local_fns(ctx, module), name) {
            True -> EVar(qualify(module, name))
            False ->
              case lookups(ctx.fn_scope, module, name) {
                Ok(source) -> EVar(qualify(source, name))
                Error(_) -> fun
              }
          }
      }
    EField(EVar(alias), name) ->
      case is_lower_name(name) && module_exports(ctx.exports, alias, name) {
        True -> EVar(qualify(alias, name))
        False -> fun
      }
    _ -> rewrite_expr(fun, module, ctx, bound)
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
