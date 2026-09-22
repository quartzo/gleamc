//// Hindley–Milner type inference for the generic surface AST. Built on
//// `types.gleam`. Declared type parameters are rigid; use sites instantiate
//// fresh unification variables, so generics truly work.
////
//// The monomorphiser runs on the result to make every concrete instantiation
//// explicit before codegen.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleamc/ast.{
  type CustomType, type Expr, type Function, type Module, type Pattern,
  type Type, type Variant, Arm, CustomType, DCustomType, DFunction, EBinop,
  EBlock, EBool, ECall, ECase, EClosure, ECtor, EEnvGet, EField, EFloat, EInt,
  ELabelled, ELambda, ENil, EString, ETuple, EUnop, EVar, Function, Let, Module,
  PBool, PCtor, PFloat, PInt, PLabelled, PNil, PString, PTuple, PVar, PWildcard,
  Stmt, Variant,
}
import gleamc/types.{
  type Scheme, type Subst, type Ty, Con, Fun, Rig, Scheme, Tup, Var,
}

pub type InferError {
  InferError(message: String)
}

pub type CtorDef {
  CtorDef(type_name: String, field_names: List(String), scheme: Scheme)
}

pub type TypeDef {
  TypeDef(name: String, params: List(Int), variants: List(VariantDef))
}

pub type VariantDef {
  VariantDef(name: String, fields: List(#(String, Ty)))
}

pub type Program {
  Program(
    functions: Dict(String, Scheme),
    ctors: Dict(String, CtorDef),
    types: Dict(String, TypeDef),
  )
}

pub type St {
  St(subst: Subst, counter: Int)
}

pub type Env {
  Env(
    globals: Dict(String, Scheme),
    locals: Dict(String, Scheme),
    ctors: Dict(String, CtorDef),
    types: Dict(String, TypeDef),
  )
}

// ---------------------------------------------------------------------------
// entry point
// ---------------------------------------------------------------------------

pub fn check(module: Module) -> Result(Program, InferError) {
  let Module(definitions) = module
  let st = St(types.empty(), 0)
  let #(types_map, ctors, functions, st) = collect(definitions, st)
  let globals =
    builtins()
    |> merge_globals(functions)
    |> merge_globals(ctor_schemes(ctors))
  let env = Env(globals, dict.new(), ctors, types_map)
  use st <- result_try(check_definitions(definitions, env, st))
  let _ = st
  Ok(Program(functions, ctors, types_map))
}

/// The merged global scheme environment (builtins + functions + constructors).
pub fn globals_of(program: Program) -> Dict(String, Scheme) {
  let Program(functions, ctors, _) = program
  builtins()
  |> merge_globals(functions)
  |> merge_globals(ctor_schemes(ctors))
}

// ---------------------------------------------------------------------------
// declaration collection
// ---------------------------------------------------------------------------

fn collect(definitions, st: St) {
  list.fold(
    definitions,
    #(dict.new(), dict.new(), dict.new(), st),
    fn(acc, def) {
      let #(types_map, ctors, functions, st) = acc
      case def {
        DCustomType(custom) -> {
          let #(types_map, ctors, st) =
            collect_type(custom, types_map, ctors, st)
          #(types_map, ctors, functions, st)
        }
        DFunction(function) -> {
          let #(scheme, st) = function_scheme(function, st)
          #(types_map, ctors, dict.insert(functions, function.name, scheme), st)
        }
        _ -> acc
      }
    },
  )
}

fn collect_type(custom: CustomType, types_map, ctors, st: St) {
  let CustomType(_, type_name, generics, variants) = custom
  let #(mapping, param_ids, st) =
    list.fold(generics, #(dict.new(), [], st), fn(acc, name) {
      let #(map, ids, st) = acc
      let id = st.counter
      let st = St(..st, counter: id + 1)
      #(dict.insert(map, name, Rig(id)), list.append(ids, [id]), st)
    })
  let variant_defs = list.map(variants, fn(v) { variant_def(v, mapping) })
  let result_ty = Con(type_name, list.map(param_ids, Var))
  let ctors =
    list.fold(variant_defs, ctors, fn(acc, variant) {
      let VariantDef(name, fields) = variant
      let field_types =
        list.map(fields, fn(field) {
          let #(_, ty) = field
          ty
        })
      let field_names =
        list.map(fields, fn(field) {
          let #(field_name, _) = field
          field_name
        })
      dict.insert(
        acc,
        name,
        CtorDef(
          type_name,
          field_names,
          Scheme(param_ids, Fun(field_types, result_ty)),
        ),
      )
    })
  #(
    dict.insert(
      types_map,
      type_name,
      TypeDef(type_name, param_ids, variant_defs),
    ),
    ctors,
    st,
  )
}

fn variant_def(variant: Variant, mapping) -> VariantDef {
  let Variant(name, fields) = variant
  VariantDef(
    name,
    list.map(fields, fn(field) {
      let #(field_name, surface) = field
      #(field_name, convert(surface, mapping))
    }),
  )
}

fn function_scheme(function: Function, st: St) {
  let Function(_, _, params, ret, _) = function
  let surface_vars = function_type_vars(function)
  let #(mapping, param_ids, st) =
    list.fold(surface_vars, #(dict.new(), [], st), fn(acc, name) {
      let #(map, ids, st) = acc
      let id = st.counter
      let st = St(..st, counter: id + 1)
      #(dict.insert(map, name, Rig(id)), list.append(ids, [id]), st)
    })
  let param_types =
    list.map(params, fn(param) {
      let #(_, surface) = param
      convert(surface, mapping)
    })
  let ret_ty = convert(ret, mapping)
  #(Scheme(param_ids, Fun(param_types, ret_ty)), st)
}

fn function_type_vars(function: Function) -> List(String) {
  let Function(_, _, params, ret, _) = function
  let from_params =
    list.flat_map(params, fn(param) {
      let #(_, surface) = param
      type_vars_in(surface)
    })
  dedupe(list.append(from_params, type_vars_in(ret)))
}

fn type_vars_in(surface: Type) -> List(String) {
  case surface {
    ast.TVar(name) -> [name]
    ast.TApp(_, args) -> list.flat_map(args, type_vars_in)
    ast.TTuple(items) -> list.flat_map(items, type_vars_in)
    ast.TFun(params, ret) ->
      list.append(list.flat_map(params, type_vars_in), type_vars_in(ret))
    _ -> []
  }
}

fn convert(surface: Type, mapping) -> Ty {
  case surface {
    ast.TInt -> Con("Int", [])
    ast.TFloat -> Con("Float", [])
    ast.TBool -> Con("Bool", [])
    ast.TString -> Con("String", [])
    ast.TNil -> Con("Nil", [])
    ast.TVar(name) ->
      case dict.get(mapping, name) {
        Ok(ty) -> ty
        Error(_) -> Con(name, [])
      }
    ast.TNamed(name) -> Con(name, [])
    ast.TApp(name, args) ->
      Con(name, list.map(args, fn(arg) { convert(arg, mapping) }))
    ast.TTuple(items) ->
      Tup(list.map(items, fn(item) { convert(item, mapping) }))
    ast.TFun(params, ret) ->
      Fun(
        list.map(params, fn(p) { convert(p, mapping) }),
        convert(ret, mapping),
      )
  }
}

fn ctor_schemes(ctors) -> Dict(String, Scheme) {
  dict.fold(ctors, dict.new(), fn(acc, name, def) {
    let CtorDef(_, _, scheme) = def
    dict.insert(acc, name, scheme)
  })
}

fn builtins() -> Dict(String, Scheme) {
  let none = []
  let s = Con("String", [])
  let n = Con("Nil", [])
  let i = Con("Int", [])
  let f = Con("Float", [])
  let b = Con("Bool", [])
  dict.new()
  |> dict.insert("io.println", Scheme(none, Fun([s], n)))
  |> dict.insert("io.print", Scheme(none, Fun([s], n)))
  |> dict.insert("int.to_string", Scheme(none, Fun([i], s)))
  |> dict.insert("float.to_string", Scheme(none, Fun([f], s)))
  |> dict.insert("bool.to_string", Scheme(none, Fun([b], s)))
  |> dict.insert("int.min", Scheme(none, Fun([i, i], i)))
  |> dict.insert("int.max", Scheme(none, Fun([i, i], i)))
  |> dict.insert("int.absolute_value", Scheme(none, Fun([i], i)))
  |> dict.insert("float.min", Scheme(none, Fun([f, f], f)))
  |> dict.insert("float.max", Scheme(none, Fun([f, f], f)))
  |> dict.insert("float.absolute_value", Scheme(none, Fun([f], f)))
  |> dict.insert("float.floor", Scheme(none, Fun([f], f)))
  |> dict.insert("float.ceiling", Scheme(none, Fun([f], f)))
  |> dict.insert("float.round", Scheme(none, Fun([f], i)))
  |> dict.insert("float.truncate", Scheme(none, Fun([f], i)))
  |> dict.insert("string.contains", Scheme(none, Fun([s, s], b)))
  |> dict.insert("string.starts_with", Scheme(none, Fun([s, s], b)))
  |> dict.insert("string.ends_with", Scheme(none, Fun([s, s], b)))
  |> dict.insert("string.trim", Scheme(none, Fun([s], s)))
  |> dict.insert("string.trim_start", Scheme(none, Fun([s], s)))
  |> dict.insert("string.trim_end", Scheme(none, Fun([s], s)))
  |> dict.insert("string.replace", Scheme(none, Fun([s, s, s], s)))
  |> dict.insert("string.slice", Scheme(none, Fun([s, i, i], s)))
  |> dict.insert("string.length", Scheme(none, Fun([s], i)))
  |> dict.insert("string.append", Scheme(none, Fun([s, s], s)))
  |> dict.insert("string.uppercase", Scheme(none, Fun([s], s)))
  |> dict.insert("string.lowercase", Scheme(none, Fun([s], s)))
  |> dict.insert("string.reverse", Scheme(none, Fun([s], s)))
}

fn merge_globals(a, b) {
  dict.fold(b, a, fn(acc, key, value) { dict.insert(acc, key, value) })
}

// ---------------------------------------------------------------------------
// function body checking
// ---------------------------------------------------------------------------

fn check_definitions(definitions, env: Env, st: St) {
  case definitions {
    [] -> Ok(st)
    [DFunction(function), ..rest] -> {
      use st <- result_try(check_function(function, env, st))
      check_definitions(rest, env, st)
    }
    [_, ..rest] -> check_definitions(rest, env, st)
  }
}

fn check_function(function: Function, env: Env, st) {
  let Function(_, name, params, ret, body) = function
  let scheme = case dict.get(env.globals, name) {
    Ok(found) -> found
    Error(_) -> Scheme([], Fun([], Con("Nil", [])))
  }
  let Scheme(_, fun_ty) = scheme
  let #(param_types, ret_ty) = fun_parts(fun_ty)
  let locals =
    list.fold(list.zip(params, param_types), dict.new(), fn(acc, pair) {
      let #(#(param_name, _), param_ty) = pair
      dict.insert(acc, param_name, Scheme([], param_ty))
    })
  let env = Env(..env, locals: locals)
  use #(body_ty, st) <- result_try(infer(env, st, body))
  let _ = ret
  unify_st(ret_ty, body_ty, st)
}

// ---------------------------------------------------------------------------
// inference
// ---------------------------------------------------------------------------

pub fn infer(env: Env, st: St, expr: Expr) -> Result(#(Ty, St), InferError) {
  case expr {
    EInt(_) -> Ok(#(Con("Int", []), st))
    EFloat(_) -> Ok(#(Con("Float", []), st))
    EString(_) -> Ok(#(Con("String", []), st))
    EBool(_) -> Ok(#(Con("Bool", []), st))
    ENil -> Ok(#(Con("Nil", []), st))
    EVar(name) -> infer_var(env, st, name)
    ETuple(elements) -> {
      use #(tys, st) <- result_try(infer_all(env, st, elements))
      Ok(#(Tup(tys), st))
    }
    ECtor(name, args) -> infer_ctor(env, st, name, args)
    ECall(fun, args) -> infer_call(env, st, fun, args)
    EUnop(op, operand) -> infer_unop(env, st, op, operand)
    EBinop(op, left, right) -> infer_binop(env, st, op, left, right)
    EBlock(statements) -> infer_block(env, st, statements)
    ECase(subject, arms) -> infer_case(env, st, subject, arms)
    EField(obj, name) -> infer_field(env, st, obj, name)
    ELabelled(_, value) -> infer(env, st, value)
    ELambda(names, body) -> infer_lambda(env, st, names, body)
    EClosure(_, _, _, fn_ty) -> Ok(#(convert(fn_ty, dict.new()), st))
    EEnvGet(_, _, ty) -> Ok(#(convert(ty, dict.new()), st))
  }
}

fn infer_lambda(env, st: St, names, body) {
  let #(param_tys, lambda_locals, st) =
    list.fold(names, #([], dict.new(), st), fn(acc, name) {
      let #(tys, locals, st) = acc
      let #(ty, counter) = types.fresh(st.counter)
      #(
        [ty, ..tys],
        dict.insert(locals, name, Scheme([], ty)),
        St(..st, counter: counter),
      )
    })
  let body_env = Env(..env, locals: merge_dicts(env.locals, lambda_locals))
  use #(body_ty, st) <- result_try(infer(body_env, st, body))
  Ok(#(Fun(list.reverse(param_tys), body_ty), st))
}

fn infer_var(env: Env, st: St, name: String) -> Result(#(Ty, St), InferError) {
  let scheme = case dict.get(env.locals, name) {
    Ok(found) -> Ok(found)
    Error(_) -> dict.get(env.globals, name)
  }
  case scheme {
    Ok(found) -> {
      let #(ty, counter) = types.instantiate(found, st.counter)
      Ok(#(ty, St(..st, counter: counter)))
    }
    Error(_) -> Error(InferError("unknown variable `" <> name <> "`"))
  }
}

fn infer_all(env: Env, st: St, exprs) {
  case exprs {
    [] -> Ok(#([], st))
    [expr, ..rest] -> {
      use #(ty, st) <- result_try(infer(env, st, expr))
      use #(tys, st) <- result_try(infer_all(env, st, rest))
      Ok(#([ty, ..tys], st))
    }
  }
}

fn infer_ctor(env: Env, st: St, name, args) {
  case dict.get(env.ctors, name) {
    Error(_) -> Error(InferError("unknown constructor `" <> name <> "`"))
    Ok(def) -> {
      let CtorDef(_, _, scheme) = def
      let #(ctor_ty, st) = instantiate_ty(scheme, st)
      let #(param_tys, ret) = fun_parts(ctor_ty)
      use #(arg_tys, st) <- result_try(infer_all(env, st, args))
      use st <- result_try(unify_lists(param_tys, arg_tys, st, name))
      Ok(#(ret, st))
    }
  }
}

fn infer_call(env: Env, st: St, fun, args) {
  case fun {
    EVar(name) -> {
      use #(fun_ty, st) <- result_try(infer_var(env, st, name))
      let #(param_tys, ret) = fun_parts(fun_ty)
      use #(arg_tys, st) <- result_try(infer_all(env, st, args))
      use st <- result_try(unify_lists(param_tys, arg_tys, st, name))
      Ok(#(ret, st))
    }
    EField(EVar(module), name) ->
      infer_call(env, st, EVar(module <> "." <> name), args)
    _ -> {
      use #(fun_ty, st) <- result_try(infer(env, st, fun))
      let #(param_tys, ret) = fun_parts(fun_ty)
      use #(arg_tys, st) <- result_try(infer_all(env, st, args))
      use st <- result_try(unify_lists(param_tys, arg_tys, st, "call"))
      Ok(#(ret, st))
    }
  }
}

fn infer_unop(env: Env, st: St, op, operand) {
  use #(ty, st) <- result_try(infer(env, st, operand))
  case op {
    "-" -> {
      // Negation is overloaded on Int and Float; resolve Float when known and
      // otherwise default to Int.
      case types.zonk(ty, st.subst) {
        Con("Float", []) -> Ok(#(Con("Float", []), st))
        _ -> {
          use st <- result_try(unify_st(Con("Int", []), ty, st))
          Ok(#(Con("Int", []), st))
        }
      }
    }
    "-." -> {
      use st <- result_try(unify_st(Con("Float", []), ty, st))
      Ok(#(Con("Float", []), st))
    }
    "!" -> {
      use st <- result_try(unify_st(Con("Bool", []), ty, st))
      Ok(#(Con("Bool", []), st))
    }
    _ -> Error(InferError("unknown unary operator `" <> op <> "`"))
  }
}

fn infer_binop(env: Env, st: St, op, left, right) {
  use #(left_ty, st) <- result_try(infer(env, st, left))
  use #(right_ty, st) <- result_try(infer(env, st, right))
  case op {
    "+" | "-" | "*" | "/" | "%" ->
      unify_both(Con("Int", []), left_ty, right_ty, Con("Int", []), st)
    "+." | "-." | "*." | "/." ->
      unify_both(Con("Float", []), left_ty, right_ty, Con("Float", []), st)
    "==" | "!=" -> {
      use st <- result_try(unify_st(left_ty, right_ty, st))
      Ok(#(Con("Bool", []), st))
    }
    "<" | "<=" | ">" | ">=" ->
      unify_both(Con("Int", []), left_ty, right_ty, Con("Bool", []), st)
    "<." | "<=." | ">." | ">=." ->
      unify_both(Con("Float", []), left_ty, right_ty, Con("Bool", []), st)
    "<>" ->
      unify_both(Con("String", []), left_ty, right_ty, Con("String", []), st)
    "&&" | "||" ->
      unify_both(Con("Bool", []), left_ty, right_ty, Con("Bool", []), st)
    _ -> Error(InferError("unknown operator `" <> op <> "`"))
  }
}

fn unify_both(operand_ty, left_ty, right_ty, result_ty, st) {
  use st <- result_try(unify_st(operand_ty, left_ty, st))
  use st <- result_try(unify_st(operand_ty, right_ty, st))
  Ok(#(result_ty, st))
}

fn infer_block(env: Env, st: St, statements) {
  case statements {
    [] -> Ok(#(Con("Nil", []), st))
    [Stmt(expr)] -> infer(env, st, expr)
    [Let(pattern, value), ..rest] -> {
      use #(value_ty, st) <- result_try(infer(env, st, value))
      use #(bound, st) <- result_try(bind_pattern(env, pattern, value_ty, st))
      let scheme = generalize_in(env, st, value_ty)
      let locals = bind_let(env.locals, pattern, bound, scheme)
      infer_block(Env(..env, locals: locals), st, rest)
    }
    [Stmt(expr), ..rest] -> {
      use #(_, st) <- result_try(infer(env, st, expr))
      infer_block(env, st, rest)
    }
  }
}

/// `let` adds the generalised scheme for a simple variable pattern; tuple
/// destructuring binds the components monomorphically.
fn bind_let(locals, pattern, bound, scheme) {
  case pattern {
    PVar(name) -> dict.insert(locals, name, scheme)
    _ ->
      dict.fold(bound, locals, fn(acc, key, value) {
        dict.insert(acc, key, value)
      })
  }
}

fn infer_case(env: Env, st: St, subject, arms) {
  use #(subject_ty, st) <- result_try(infer(env, st, subject))
  infer_arms(env, st, subject_ty, arms, None)
}

fn infer_arms(env: Env, st: St, subject_ty, arms, result_ty) {
  case arms {
    [] ->
      case result_ty {
        None -> Error(InferError("`case` with no arms"))
        Some(ty) -> Ok(#(ty, st))
      }
    [Arm(pattern, guard, body), ..rest] -> {
      use #(bound, st) <- result_try(bind_pattern(env, pattern, subject_ty, st))
      let arm_env = Env(..env, locals: merge_dicts(env.locals, bound))
      use st <- result_try(check_arm_guard(arm_env, st, guard))
      use #(body_ty, st) <- result_try(infer(arm_env, st, body))
      case result_ty {
        None -> infer_arms(env, st, subject_ty, rest, Some(body_ty))
        Some(ty) -> {
          use st <- result_try(unify_st(ty, body_ty, st))
          infer_arms(env, st, subject_ty, rest, Some(ty))
        }
      }
    }
  }
}

fn check_arm_guard(env: Env, st: St, guard) {
  case guard {
    None -> Ok(st)
    Some(expr) -> {
      use #(ty, st) <- result_try(infer(env, st, expr))
      unify_st(Con("Bool", []), ty, st)
    }
  }
}

fn infer_field(env: Env, st: St, obj, name) {
  use #(obj_ty, st) <- result_try(infer(env, st, obj))
  case types.resolve(obj_ty, st.subst) {
    Con(type_name, args) -> {
      use field_ty <- result_try(field_type(env, type_name, args, name))
      Ok(#(field_ty, st))
    }
    _ -> Error(InferError("field access on a non-record value"))
  }
}

fn field_type(env: Env, type_name, args, name) {
  case dict.get(env.types, type_name) {
    Error(_) -> Error(InferError("unknown type `" <> type_name <> "`"))
    Ok(def) -> {
      let TypeDef(_, params, variants) = def
      let found =
        list.filter_map(variants, fn(variant) {
          let VariantDef(_, fields) = variant
          case list.key_find(fields, name) {
            Ok(field_ty) -> Ok(substitute_params(field_ty, params, args))
            Error(_) -> Error(Nil)
          }
        })
      case found {
        [field_ty, ..] -> Ok(field_ty)
        [] ->
          Error(InferError(
            "type `" <> type_name <> "` has no field `" <> name <> "`",
          ))
      }
    }
  }
}

fn substitute_params(ty, params, args) {
  let mapping =
    list.fold(list.zip(params, args), dict.new(), fn(acc, pair) {
      let #(param, arg) = pair
      dict.insert(acc, param, arg)
    })
  subst_ids(ty, mapping)
}

fn subst_ids(ty, mapping) {
  case ty {
    Rig(id) ->
      case dict.get(mapping, id) {
        Ok(replacement) -> replacement
        Error(_) -> ty
      }
    Var(_) -> ty
    Con(name, args) ->
      Con(name, list.map(args, fn(arg) { subst_ids(arg, mapping) }))
    Fun(args, ret) ->
      Fun(
        list.map(args, fn(arg) { subst_ids(arg, mapping) }),
        subst_ids(ret, mapping),
      )
    Tup(items) -> Tup(list.map(items, fn(item) { subst_ids(item, mapping) }))
  }
}

// ---------------------------------------------------------------------------
// patterns
// ---------------------------------------------------------------------------

fn bind_pattern(
  env: Env,
  pattern,
  ty,
  st: St,
) -> Result(#(Dict(String, Scheme), St), InferError) {
  case pattern {
    PWildcard -> Ok(#(dict.new(), st))
    PVar(name) -> Ok(#(dict.insert(dict.new(), name, Scheme([], ty)), st))
    PInt(_) -> bind_literal(ty, Con("Int", []), st)
    PFloat(_) -> bind_literal(ty, Con("Float", []), st)
    PString(_) -> bind_literal(ty, Con("String", []), st)
    PBool(_) -> bind_literal(ty, Con("Bool", []), st)
    PNil -> bind_literal(ty, Con("Nil", []), st)
    PTuple(patterns) -> {
      let counter = st.counter
      let #(vars, counter) = types.fresh_many(counter, list.length(patterns))
      let st = St(..st, counter: counter)
      use st <- result_try(unify_st(Tup(vars), ty, st))
      bind_patterns(env, patterns, vars, st)
    }
    PCtor(name, args) ->
      case dict.get(env.ctors, name) {
        Error(_) -> Error(InferError("unknown constructor `" <> name <> "`"))
        Ok(def) -> {
          let CtorDef(_, field_names, scheme) = def
          use ordered <- result_try(
            map_order(order_pattern(field_names, name, args)),
          )
          let #(ctor_ty, st) = instantiate_ty(scheme, st)
          let #(param_tys, ret) = fun_parts(ctor_ty)
          use st <- result_try(unify_st(ret, ty, st))
          bind_patterns(env, ordered, param_tys, st)
        }
      }
    PLabelled(_, inner) -> bind_pattern(env, inner, ty, st)
  }
}

/// Resolves labelled/positional pattern arguments to the formal field order.
pub fn order_pattern(field_names, ctx, args) -> Result(List(Pattern), String) {
  let slots = list.map(field_names, fn(_) { None })
  case fill_patterns(field_names, args, slots, 0) {
    Error(_) -> Error("too many arguments in " <> ctx)
    Ok(filled) -> collect_slots(filled, ctx, [])
  }
}

fn fill_patterns(
  names,
  args,
  slots,
  next_pos,
) -> Result(List(Option(Pattern)), Nil) {
  case args {
    [] -> Ok(slots)
    [arg, ..rest] ->
      case arg {
        PLabelled(label, inner) ->
          case index_of(names, label) {
            Error(_) -> fill_patterns(names, rest, slots, next_pos)
            Ok(index) ->
              fill_patterns(
                names,
                rest,
                set_slot(slots, index, Some(inner)),
                next_pos,
              )
          }
        _ ->
          case next_empty(slots, next_pos) {
            Error(_) -> Error(Nil)
            Ok(index) ->
              fill_patterns(
                names,
                rest,
                set_slot(slots, index, Some(arg)),
                index + 1,
              )
          }
      }
  }
}

fn collect_slots(slots, ctx, acc) -> Result(List(Pattern), String) {
  case slots {
    [] -> Ok(list.reverse(acc))
    [None, ..] -> Error("missing argument in " <> ctx)
    [Some(value), ..rest] -> collect_slots(rest, ctx, [value, ..acc])
  }
}

fn index_of(items, target) {
  case items {
    [] -> Error(Nil)
    [item, ..rest] ->
      case item == target {
        True -> Ok(0)
        False -> {
          use index <- result_try(index_of(rest, target))
          Ok(index + 1)
        }
      }
  }
}

fn next_empty(slots, from) {
  next_empty_loop(slots, from, 0)
}

fn next_empty_loop(slots, from, index) {
  case slots {
    [] -> Error(Nil)
    [slot, ..rest] ->
      case index >= from && slot == None {
        True -> Ok(index)
        False -> next_empty_loop(rest, from, index + 1)
      }
  }
}

fn set_slot(slots, index, value) {
  case slots {
    [] -> []
    [head, ..rest] ->
      case index == 0 {
        True -> [value, ..rest]
        False -> {
          let tail = set_slot(rest, index - 1, value)
          [head, ..tail]
        }
      }
  }
}

fn map_order(result) {
  case result {
    Ok(value) -> Ok(value)
    Error(message) -> Error(InferError(message))
  }
}

fn bind_literal(ty, expected, st) {
  use st <- result_try(unify_st(expected, ty, st))
  Ok(#(dict.new(), st))
}

fn bind_patterns(env: Env, patterns, types_list, st: St) {
  case patterns, types_list {
    [], _ -> Ok(#(dict.new(), st))
    [pattern, ..rest_patterns], [ty, ..rest_types] -> {
      use #(bound, st) <- result_try(bind_pattern(env, pattern, ty, st))
      use #(rest_bound, st) <- result_try(bind_patterns(
        env,
        rest_patterns,
        rest_types,
        st,
      ))
      Ok(#(merge_dicts(bound, rest_bound), st))
    }
    _, _ -> Error(InferError("pattern arity mismatch"))
  }
}

fn merge_dicts(a, b) {
  dict.fold(b, a, fn(acc, key, value) { dict.insert(acc, key, value) })
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn instantiate_ty(scheme: Scheme, st: St) -> #(Ty, St) {
  let #(ty, counter) = types.instantiate(scheme, st.counter)
  #(ty, St(..st, counter: counter))
}

fn fun_parts(ty) {
  case ty {
    Fun(args, ret) -> #(args, ret)
    _ -> #([], ty)
  }
}

fn unify_st(a, b, st: St) -> Result(St, InferError) {
  case types.unify(a, b, st.subst) {
    Ok(subst) -> Ok(St(..st, subst: subst))
    Error(message) -> Error(InferError(message))
  }
}

fn unify_lists(expected, actual, st, context) {
  case expected, actual {
    [], [] -> Ok(st)
    [e, ..er], [a, ..ar] -> {
      use st <- result_try(unify_st(e, a, st))
      unify_lists(er, ar, st, context)
    }
    _, _ -> Error(InferError("arity mismatch in `" <> context <> "`"))
  }
}

fn generalize_in(env: Env, st: St, ty: Ty) -> Scheme {
  let env_free =
    list.flat_map(dict.to_list(env.locals), fn(entry) {
      let #(_, scheme) = entry
      let Scheme(vars, scheme_ty) = scheme
      list.filter(types.free_vars(scheme_ty), fn(id) {
        !list.contains(vars, id)
      })
    })
  types.generalize(env_free, types.zonk(ty, st.subst))
}

fn dedupe(items) {
  list.fold(items, [], fn(acc, item) {
    case list.contains(acc, item) {
      True -> acc
      False -> list.append(acc, [item])
    }
  })
}

fn result_try(result, next) {
  case result {
    Ok(value) -> next(value)
    Error(err) -> Error(err)
  }
}
