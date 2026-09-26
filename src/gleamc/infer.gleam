//// Hindley–Milner type inference for the generic surface AST. Built on
//// `types.gleam`. Declared type parameters are rigid; use sites instantiate
//// fresh unification variables, so generics truly work.
////
//// The monomorphiser runs on the result to make every concrete instantiation
//// explicit before lowering.

import gleam/int

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleamc/util
import gleamc/ast.{
  type CustomType, type Expr, type External, type Function, type Module,
  type Pattern, type Type, type Variant, Arm, CustomType, DCustomType, DExternal,
  DFunction, EBinop, EBitArray, EBlock, EBool, ECall, ECase, EClosure, ECtor,
  EEnvGet, EField, EFloat, EInt, ELabelled, ELambda, ENil, EPanic, EString,
  ETuple, EUnop, EUpdate, EVar, External, Function, Let, Module, PAs, PBitArray,
  PBool, PCtor, PFloat,
  PInt, PLabelled, PNil, PString, PTuple, PVar, PWildcard, Stmt, Variant,
}
import gleamc/texpr
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
  use #(_resolved, program) <- result_try(check_resolved(module))
  Ok(program)
}

/// Like `check`, but also returns the module with inferred parameter and
/// return types substituted in, so the monomorphiser sees concrete types
/// instead of the `__infer_*` markers.
pub fn check_resolved(
  module: Module,
) -> Result(#(Module, Program), InferError) {
  let Module(definitions) = module
  let st = St(types.empty(), 0)
  let #(types_map, ctors, functions, var_ids, st) = collect(definitions, st)
  let functions_by_name =
    list.fold(definitions, dict.new(), fn(acc, def) {
      case def {
        DFunction(function) -> dict.insert(acc, function.name, function)
        _ -> acc
      }
    })
  let globals =
    builtins()
    |> merge_globals(functions)
    |> merge_globals(ctor_schemes(ctors))
  let env_counts =
    dict.fold(globals, dict.new(), fn(acc, _, scheme) {
      counts_add(acc, type_var_counts(types.env_free_vars([scheme])))
    })
  // Infer, then re-infer. A single topological pass uses the declared (collect)
  // signature for a function not yet inferred, so a mutually-recursive group of
  // unannotated functions only gets precise types once a later pass sees the
  // group's inferred schemes.
  use #(functions, st) <- result_try(infer_rounds(
    order_functions(definitions),
    functions_by_name,
    ctors,
    types_map,
    var_ids,
    functions,
    globals,
    env_counts,
    st,
    3,
  ))
  let #(resolved, functions) =
    resolve_definitions(definitions, functions, var_ids, st.subst)
  Ok(#(Module(resolved), Program(functions, ctors, types_map)))
}

fn globals_for(functions, ctors) {
  builtins()
  |> merge_globals(functions)
  |> merge_globals(ctor_schemes(ctors))
}

fn env_counts_for(globals) {
  dict.fold(globals, dict.new(), fn(acc, _, scheme) {
    counts_add(acc, type_var_counts(types.env_free_vars([scheme])))
  })
}

fn infer_rounds(
  order,
  functions_by_name,
  ctors,
  types_map,
  var_ids,
  functions,
  globals,
  counts,
  st,
  rounds,
) {
  case rounds <= 0 {
    True -> Ok(#(functions, st))
    False -> {
      use #(functions, st) <- result_try(infer_in_order(
        order,
        functions_by_name,
        ctors,
        types_map,
        var_ids,
        functions,
        globals,
        counts,
        st,
      ))
      let globals = globals_for(functions, ctors)
      infer_rounds(
        order,
        functions_by_name,
        ctors,
        types_map,
        var_ids,
        functions,
        globals,
        env_counts_for(globals),
        st,
        rounds - 1,
      )
    }
  }
}

/// Rewrites inferred parameter/return types into the module and rebuilds each
/// function's scheme so its quantified variables line up, in order, with the
/// type variables of the rewritten surface (the monomorphiser relies on that).
fn resolve_definitions(definitions, functions, var_ids, subst) {
  list.fold(definitions, #([], functions), fn(acc, def) {
    let #(out, functions) = acc
    case def {
      DFunction(function) -> {
        let resolved = resolve_function(function, var_ids, subst)
        let functions = align_scheme(functions, resolved, var_ids)
        #(list.append(out, [DFunction(resolved)]), functions)
      }
      _ -> #(list.append(out, [def]), functions)
    }
  })
}

fn align_scheme(functions, function: Function, var_ids) {
  let name = function.name
  let scheme = case dict.get(functions, name) {
    Ok(found) -> found
    Error(_) -> Scheme([], Fun([], Con("Nil", [])))
  }
  let Scheme(_, zonked) = scheme
  let free = types.free_vars(zonked)
  let id_map = case dict.get(var_ids, name) {
    Ok(found) -> found
    Error(_) -> dict.new()
  }
  let ids =
    list.filter_map(function_type_vars(function), fn(var_name) {
      case surface_var_id(var_name, id_map) {
        Error(_) -> Error(Nil)
        Ok(id) ->
          case list.contains(free, id) {
            True -> Ok(id)
            False -> Error(Nil)
          }
      }
    })
  dict.insert(functions, name, Scheme(util.dedupe(ids), zonked))
}

fn surface_var_id(var_name, id_map) -> Result(Int, Nil) {
  case string.starts_with(var_name, "__gen_") {
    True ->
      case int.parse(string.drop_start(var_name, 6)) {
        Ok(id) -> Ok(id)
        Error(_) -> Error(Nil)
      }
    False -> dict.get(id_map, var_name)
  }
}

fn general_var_name(id: Int) -> String {
  "__gen_" <> int.to_string(id)
}

fn surface_of_general(ty: Ty) -> Type {
  case ty {
    Con("Int", []) -> ast.TInt
    Con("Float", []) -> ast.TFloat
    Con("Bool", []) -> ast.TBool
    Con("String", []) -> ast.TString
    Con("Nil", []) -> ast.TNil
    Con(name, []) -> ast.TNamed(name)
    Con(name, args) -> ast.TApp(name, list.map(args, surface_of_general))
    Var(id) -> ast.TVar(general_var_name(id))
    types.Rig(id) -> ast.TVar(general_var_name(id))
    Fun(params, ret) ->
      ast.TFun(list.map(params, surface_of_general), surface_of_general(ret))
    Tup(items) -> ast.TTuple(list.map(items, surface_of_general))
  }
}

fn infer_in_order(
  order,
  functions_by_name,
  ctors,
  types_map,
  var_ids,
  functions,
  globals,
  counts,
  st,
) {
  case order {
    [] -> Ok(#(functions, st))
    [name, ..rest] -> {
      use #(functions, globals, counts, st) <- result_try(infer_one(
        name,
        functions_by_name,
        ctors,
        types_map,
        var_ids,
        functions,
        globals,
        counts,
        st,
      ))
      infer_in_order(
        rest,
        functions_by_name,
        ctors,
        types_map,
        var_ids,
        functions,
        globals,
        counts,
        st,
      )
    }
  }
}

fn infer_one(
  name: String,
  functions_by_name: Dict(String, Function),
  ctors,
  types_map,
  var_ids,
  functions,
  globals,
  counts,
  st: St,
) {
  case dict.get(functions_by_name, name) {
    Error(_) -> Ok(#(functions, globals, counts, st))
    Ok(function) -> {
      let scheme = case dict.get(functions, name) {
        Ok(found) -> found
        Error(_) -> Scheme([], Fun([], Con("Nil", [])))
      }
      let Scheme(_, fun_ty) = scheme
      let #(param_types, ret_ty) = fun_parts(fun_ty)
      let locals =
        list.fold(
          list.zip(function.params, param_types),
          dict.new(),
          fn(acc, pair) {
            let #(#(param_name, _), param_ty) = pair
            dict.insert(acc, param_name, Scheme([], param_ty))
          },
        )
      let env = Env(globals, locals, ctors, types_map)
      use #(body_ty, st) <- result_try(with_function(
        name,
        function.line,
        infer(env, st, function.body),
      ))
      use st <- result_try(unify_st(ret_ty, body_ty, st))
      let zonked = types.zonk(fun_ty, st.subst)
      let id_map = case dict.get(var_ids, name) {
        Ok(found) -> found
        Error(_) -> dict.new()
      }
      let remove = type_var_counts(types.env_free_vars([scheme]))
      let _ = id_map
      let scheme = generalize_counts(counts, remove, zonked)
      let counts =
        counts_add(
          counts_sub(counts, remove),
          type_var_counts(types.env_free_vars([scheme])),
        )
      Ok(#(
        dict.insert(functions, name, scheme),
        dict.insert(globals, name, scheme),
        counts,
        st,
      ))
    }
  }
}

fn order_functions(definitions) {
  let functions =
    list.filter_map(definitions, fn(def) {
      case def {
        DFunction(function) -> Ok(function)
        _ -> Error(Nil)
      }
    })
  let names = list.map(functions, fn(function) { function.name })
  let name_set =
    list.fold(names, dict.new(), fn(acc, name) { dict.insert(acc, name, True) })
  let refs =
    list.fold(functions, dict.new(), fn(acc, function) {
      dict.insert(acc, function.name, referenced_names(function.body, name_set))
    })
  let #(order, _visited) =
    list.fold(functions, #([], dict.new()), fn(acc, function) {
      let #(order, visited) = acc
      visit_function(function.name, refs, visited, order)
    })
  order
}

fn visit_function(name, refs, visited, order) {
  case dict.get(visited, name) {
    Ok(_) -> #(order, visited)
    Error(_) -> {
      let visited = dict.insert(visited, name, True)
      let deps = case dict.get(refs, name) {
        Ok(found) -> found
        Error(_) -> []
      }
      let #(order, visited) =
        list.fold(deps, #(order, visited), fn(acc, dep) {
          let #(order, visited) = acc
          visit_function(dep, refs, visited, order)
        })
      #(list.append(order, [name]), visited)
    }
  }
}

fn referenced_names(expr: Expr, names: Dict(String, Bool)) -> List(String) {
  list.filter(expr_var_names(expr, []), fn(name) {
    case dict.get(names, name) {
      Ok(_) -> True
      Error(_) -> False
    }
  })
}

/// Multiset of free type-variable ids over the environment, kept incrementally
/// so `generalize` does not have to rescan every scheme on every function.
fn type_var_counts(ids: List(Int)) -> Dict(Int, Int) {
  list.fold(ids, dict.new(), fn(acc, id) {
    dict.insert(acc, id, case dict.get(acc, id) {
      Ok(n) -> n + 1
      Error(_) -> 1
    })
  })
}

fn counts_add(a, b) {
  dict.fold(b, a, fn(acc, id, n) {
    dict.insert(acc, id, case dict.get(acc, id) {
      Ok(m) -> m + n
      Error(_) -> n
    })
  })
}

fn counts_sub(a, b) {
  dict.fold(b, a, fn(acc, id, n) {
    case dict.get(acc, id) {
      Ok(m) ->
        case m - n {
          0 -> dict.delete(acc, id)
          left -> dict.insert(acc, id, left)
        }
      Error(_) -> acc
    }
  })
}

fn generalize_counts(counts, remove, ty: Ty) -> Scheme {
  let vars =
    list.filter(util.dedupe(types.free_vars(ty)), fn(id) {
      let c = case dict.get(counts, id) {
        Ok(n) -> n
        Error(_) -> 0
      }
      let r = case dict.get(remove, id) {
        Ok(n) -> n
        Error(_) -> 0
      }
      c - r <= 0
    })
  Scheme(vars, ty)
}

fn expr_var_names(expr: Expr, acc: List(String)) -> List(String) {
  case expr {
    EVar(name) -> [name, ..acc]
    EField(obj, _) -> expr_var_names(obj, acc)
    ECtor(_, args) -> expr_var_names_all(args, acc)
    ECall(fun, args) -> expr_var_names_all(args, expr_var_names(fun, acc))
    EBinop(_, left, right) -> expr_var_names(right, expr_var_names(left, acc))
    EUnop(_, operand) -> expr_var_names(operand, acc)
    EBlock(statements) ->
      list.fold(statements, acc, fn(acc, statement) {
        case statement {
          Let(_, value) -> expr_var_names(value, acc)
          Stmt(e) -> expr_var_names(e, acc)
        }
      })
    ECase(subject, arms) -> {
      let acc = expr_var_names(subject, acc)
      list.fold(arms, acc, fn(acc, arm) {
        let Arm(_, guard, body) = arm
        let acc = case guard {
          Some(e) -> expr_var_names(e, acc)
          None -> acc
        }
        expr_var_names(body, acc)
      })
    }
    ETuple(items) -> expr_var_names_all(items, acc)
    ELabelled(_, value) -> expr_var_names(value, acc)
    ELambda(_, body) -> expr_var_names(body, acc)
    EClosure(_, captures, _, _) -> expr_var_names_all(captures, acc)
    EUpdate(_, base, fields) ->
      list.fold(fields, expr_var_names(base, acc), fn(acc, field) {
        let #(_, value) = field
        expr_var_names(value, acc)
      })
    EBitArray(items) -> expr_var_names_all(items, acc)
    EInt(_)
    | EFloat(_)
    | EString(_)
    | EBool(_)
    | ENil
    | EEnvGet(_, _, _)
    | EPanic(_, _) -> acc
  }
}

fn expr_var_names_all(exprs: List(Expr), acc: List(String)) -> List(String) {
  list.fold(exprs, acc, fn(acc, expr) { expr_var_names(expr, acc) })
}

fn is_infer_var(surface: Type) -> Bool {
  case surface {
    ast.TVar(name) -> string.starts_with(name, "__infer_")
    _ -> False
  }
}

fn resolve_function(function: Function, var_ids, subst) -> Function {
  let Function(is_pub, name, params, ret, body, line) = function
  let id_map = case dict.get(var_ids, name) {
    Ok(found) -> found
    Error(_) -> dict.new()
  }
  let params2 =
    list.map(params, fn(param) {
      let #(param_name, surface) = param
      #(param_name, resolve_infer_surface(surface, id_map, subst))
    })
  Function(
    is_pub,
    name,
    params2,
    resolve_infer_surface(ret, id_map, subst),
    body,
    line,
  )
}

/// Replaces an inferred marker with its concrete type when it is no longer
/// generic; generic ones stay as variables so the monomorphiser can
/// specialise them per call site.
fn resolve_infer_surface(surface, id_map, subst) {
  case is_infer_var(surface) {
    False -> surface
    True ->
      case surface {
        ast.TVar(var_name) ->
          case dict.get(id_map, var_name) {
            Error(_) -> surface
            Ok(id) -> surface_of_general(types.zonk(Var(id), subst))
          }
        _ -> surface
      }
  }
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
    #(dict.new(), dict.new(), dict.new(), dict.new(), st),
    fn(acc, def) {
      let #(types_map, ctors, functions, var_ids, st) = acc
      case def {
        DCustomType(custom) -> {
          let #(types_map, ctors, st) =
            collect_type(custom, types_map, ctors, st)
          #(types_map, ctors, functions, var_ids, st)
        }
        DFunction(function) -> {
          let #(scheme, id_map, st) = function_scheme(function, st)
          #(
            types_map,
            ctors,
            dict.insert(functions, function.name, scheme),
            dict.insert(var_ids, function.name, id_map),
            st,
          )
        }
        DExternal(external) -> {
          let #(scheme, id_map, st) = external_scheme(external, st)
          #(
            types_map,
            ctors,
            dict.insert(functions, external.name, scheme),
            dict.insert(var_ids, external.name, id_map),
            st,
          )
        }
        _ -> acc
      }
    },
  )
}

fn collect_type(custom: CustomType, types_map, ctors, st: St) {
  let CustomType(_, type_name, generics, variants, _) = custom
  let #(mapping, param_ids, st) =
    list.fold(generics, #(dict.new(), [], st), fn(acc, name) {
      let #(map, ids, st) = acc
      let id = st.counter
      let st = St(..st, counter: id + 1)
      #(dict.insert(map, name, Rig(id)), list.append(ids, [id]), st)
    })
  let variant_defs = list.map(variants, fn(v) { variant_def(v, mapping) })
  let result_ty = Con(type_name, list.map(param_ids, fn(id) { Var(id) }))
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
  let Function(_, _, params, ret, _, _) = function
  params_ret_scheme(params, ret, function_type_vars(function), st)
}

fn external_scheme(external: External, st: St) {
  let External(_, _, params, ret, _, _, _) = external
  params_ret_scheme(params, ret, external_type_vars(external), st)
}

fn params_ret_scheme(params, ret, surface_vars, st: St) {
  let #(mapping, param_ids, id_map, st) =
    list.fold(surface_vars, #(dict.new(), [], dict.new(), st), fn(acc, name) {
      let #(map, ids, id_map, st) = acc
      let id = st.counter
      let st = St(..st, counter: id + 1)
      // Inferred markers (`__infer_*`, from unannotated parameters and return
      // types) are flexible vars; declared type variables are rigid.
      let inferred = string.starts_with(name, "__infer_")
      let ty = case inferred {
        True -> Var(id)
        False -> Rig(id)
      }
      #(
        dict.insert(map, name, ty),
        list.append(ids, [id]),
        dict.insert(id_map, name, id),
        st,
      )
    })
  let param_types =
    list.map(params, fn(param) {
      let #(_, surface) = param
      convert(surface, mapping)
    })
  let ret_ty = convert(ret, mapping)
  #(Scheme(param_ids, Fun(param_types, ret_ty)), id_map, st)
}

fn function_type_vars(function: Function) -> List(String) {
  let Function(_, _, params, ret, _, _) = function
  let from_params =
    list.flat_map(params, fn(param) {
      let #(_, surface) = param
      type_vars_in(surface)
    })
  util.dedupe(list.append(from_params, type_vars_in(ret)))
}

fn external_type_vars(external: External) -> List(String) {
  let External(_, _, params, ret, _, _, _) = external
  let from_params =
    list.flat_map(params, fn(param) {
      let #(_, surface) = param
      type_vars_in(surface)
    })
  util.dedupe(list.append(from_params, type_vars_in(ret)))
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

fn no_vars() -> List(Int) {
  []
}

fn builtins() -> Dict(String, Scheme) {
  let none = no_vars()
  let s = Con("String", [])
  let n = Con("Nil", [])
  let i = Con("Int", [])
  let f = Con("Float", [])
  let b = Con("Bool", [])
  dict.new()
  |> dict.insert("io.println", Scheme(none, Fun([s], n)))
  |> dict.insert("io.print", Scheme(none, Fun([s], n)))
  |> dict.insert("time.timer", Scheme(none, Fun([i], n)))
  |> dict.insert("time.timer_count", Scheme(none, Fun([i], i)))
  |> dict.insert(
    "uv.fs_open",
    Scheme(none, Fun([s, i, i], i)),
  )
  |> dict.insert("uv.fs_fstat", Scheme(none, Fun([i], i)))
  |> dict.insert(
    "uv.fs_read",
    Scheme(none, Fun([i, i], Con("BitArray", []))),
  )
  |> dict.insert("uv.fs_close", Scheme(none, Fun([i], i)))
  |> dict.insert(
    "uv.fs_write",
    Scheme(none, Fun([i, Con("BitArray", [])], i)),
  )
  |> dict.insert("uv.fs_unlink", Scheme(none, Fun([s], i)))
  |> dict.insert("uv.fs_mkdir", Scheme(none, Fun([s, i], i)))
  |> dict.insert("uv.fs_rmdir", Scheme(none, Fun([s], i)))
  |> dict.insert("uv.fs_rename", Scheme(none, Fun([s, s], i)))
  |> dict.insert("uv.fs_symlink", Scheme(none, Fun([s, s], i)))
  |> dict.insert("uv.fs_link", Scheme(none, Fun([s, s], i)))
  |> dict.insert("uv.fs_chmod", Scheme(none, Fun([s, i], i)))
  |> dict.insert(
    "uv.fs_stat",
    Scheme(none, Fun([s, i], Con("BitArray", []))),
  )
  |> dict.insert(
    "uv.fs_realpath",
    Scheme(none, Fun([s], Con("BitArray", []))),
  )
  |> dict.insert(
    "uv.fs_readdir",
    Scheme(none, Fun([s], Con("BitArray", []))),
  )
  |> dict.insert("uv.fs_cwd", Scheme(none, Fun([], Con("BitArray", []))))
  |> dict.insert("int.to_string", Scheme(none, Fun([i], s)))
  |> dict.insert("float.to_string", Scheme(none, Fun([f], s)))
  |> dict.insert("bool.to_string", Scheme(none, Fun([b], s)))
  |> dict.insert("int.min", Scheme(none, Fun([i, i], i)))
  |> dict.insert("int.max", Scheme(none, Fun([i, i], i)))
  |> dict.insert("int.absolute_value", Scheme(none, Fun([i], i)))
  |> dict.insert("float.raw_power", Scheme(none, Fun([f, f], f)))
  |> dict.insert("float.raw_square_root", Scheme(none, Fun([f], f)))
  |> dict.insert("float.raw_exponential", Scheme(none, Fun([f], f)))
  |> dict.insert("float.raw_logarithm", Scheme(none, Fun([f], f)))
  |> dict.insert("int.bitwise_and", Scheme(none, Fun([i, i], i)))
  |> dict.insert("int.bitwise_or", Scheme(none, Fun([i, i], i)))
  |> dict.insert("int.bitwise_exclusive_or", Scheme(none, Fun([i, i], i)))
  |> dict.insert("int.bitwise_not", Scheme(none, Fun([i], i)))
  |> dict.insert("int.bitwise_shift_left", Scheme(none, Fun([i, i], i)))
  |> dict.insert("int.bitwise_shift_right", Scheme(none, Fun([i, i], i)))
  |> dict.insert("int.raw_to_base_string", Scheme(none, Fun([i, i], s)))
  |> dict.insert(
    "gleamc.key_compare",
    Scheme([9001], Fun([Var(9001), Var(9001)], i)),
  )
  |> dict.insert("gleamc.show", Scheme([9002], Fun([Var(9002)], s)))
  |> dict.insert("gleamc.hash", Scheme([9004], Fun([Var(9004)], i)))
  |> dict.insert(
    "buffer.new",
    Scheme([9005], Fun([i], Con("Buffer", [Var(9005)]))),
  )
  |> dict.insert(
    "buffer.len",
    Scheme([9006], Fun([Con("Buffer", [Var(9006)])], i)),
  )
  |> dict.insert(
    "buffer.get",
    Scheme([9007], Fun([Con("Buffer", [Var(9007)]), i], Var(9007))),
  )
  |> dict.insert(
    "buffer.set",
    Scheme(
      [9008],
      Fun([Con("Buffer", [Var(9008)]), i, Var(9008)], Con("Buffer", [
        Var(9008),
      ])),
    ),
  )
  |> dict.insert(
    "buffer.is_null",
    Scheme([9009], Fun([Con("Buffer", [Var(9009)])], b)),
  )
  |> dict.insert(
    "buffer.take",
    Scheme([9010], Fun([Con("Buffer", [Var(9010)]), i], Var(9010))),
  )
  |> dict.insert("io.debug", Scheme([9003], Fun([Var(9003)], n)))
  |> dict.insert("int.to_float", Scheme(none, Fun([i], f)))
  |> dict.insert("string.compare_bytes", Scheme(none, Fun([s, s], i)))
  |> dict.insert("string.raw_codepoint_at", Scheme(none, Fun([s, i], i)))
  |> dict.insert("string.raw_codepoint_to_string", Scheme(none, Fun([i], s)))
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
  |> dict.insert("string.byte_size", Scheme(none, Fun([s], i)))
  |> dict.insert(
    "bit_array.from_string",
    Scheme(none, Fun([s], Con("BitArray", []))),
  )
  |> dict.insert(
    "bit_array.raw_to_string",
    Scheme(none, Fun([Con("BitArray", [])], s)),
  )
  |> dict.insert(
    "bit_array.byte_size",
    Scheme(none, Fun([Con("BitArray", [])], i)),
  )
  |> dict.insert(
    "bit_array.byte",
    Scheme(none, Fun([Con("BitArray", []), i], i)),
  )
  |> dict.insert(
    "bit_array.int64_at",
    Scheme(none, Fun([Con("BitArray", []), i], i)),
  )
  |> dict.insert(
    "bit_array.append",
    Scheme(
      none,
      Fun([Con("BitArray", []), Con("BitArray", [])], Con("BitArray", [])),
    ),
  )
  |> dict.insert(
    "bit_array.bit_size",
    Scheme(none, Fun([Con("BitArray", [])], i)),
  )
  |> dict.insert("string.slice", Scheme(none, Fun([s, i, i], s)))
  |> dict.insert("string.length", Scheme(none, Fun([s], i)))
  |> dict.insert("string.append", Scheme(none, Fun([s, s], s)))
  |> dict.insert("string.uppercase", Scheme(none, Fun([s], s)))
  |> dict.insert("string.lowercase", Scheme(none, Fun([s], s)))
  |> dict.insert("string.reverse", Scheme(none, Fun([s], s)))
  |> dict.insert(
    "bit_array.is_utf8",
    Scheme(none, Fun([Con("BitArray", [])], b)),
  )
  |> dict.insert("host.run", Scheme(none, Fun([s], Con("BitArray", []))))
  |> dict.insert(
    "host.char_code_at",
    Scheme(none, Fun([s, i], i)),
  )
  |> dict.insert(
    "host.char_byte_len",
    Scheme(none, Fun([s, i], i)),
  )
  |> dict.insert(
    "host.byte_slice",
    Scheme(none, Fun([s, i, i], s)),
  )
  |> dict.insert("host.argv", Scheme(none, Fun([], Con("BitArray", []))))
  |> dict.insert("host.get_env", Scheme(none, Fun([s], s)))
  |> dict.insert("host.which", Scheme(none, Fun([s], s)))
  |> dict.insert("host.now_ms", Scheme(none, Fun([], i)))
  |> dict.insert(
    "host.blob_slice",
    Scheme(none, Fun([Con("BitArray", []), i], Con("BitArray", []))),
  )
  |> dict.insert(
    "host.int64_at",
    Scheme(none, Fun([Con("BitArray", []), i], i)),
  )
  |> dict.insert(
    "process_ffi.new_subject",
    Scheme([9100], Fun([], Con("Subject", [Var(9100)]))),
  )
  |> dict.insert(
    "process_ffi.send",
    Scheme(
      [9101],
      Fun([Con("Subject", [Var(9101)]), Var(9101)], n),
    ),
  )
  |> dict.insert(
    "process_ffi.receive",
    Scheme([9102], Fun([Con("Subject", [Var(9102)])], Var(9102))),
  )
  |> dict.insert(
    "process.spawn",
    Scheme([9103], Fun([Fun([], n)], Con("Pid", []))),
  )
  |> dict.insert(
    "task.async",
    Scheme([9104], Fun([Fun([], Var(9104))], Con("Task", [Var(9104)]))),
  )
  |> dict.insert(
    "task_ffi.await",
    Scheme([9106], Fun([Con("Task", [Var(9106)])], Var(9106))),
  )
}

/// The names of every builtin, used by `ffi_modes` coverage checks.
pub fn builtin_names() -> List(String) {
  dict.keys(builtins())
}

fn merge_globals(a, b) {
  dict.fold(b, a, fn(acc, key, value) { dict.insert(acc, key, value) })
}

// ---------------------------------------------------------------------------
// function body checking
// ---------------------------------------------------------------------------

fn with_function(name, line, result) {
  case result {
    Error(InferError(message)) -> Error(InferError(locate(line, name, message)))
    Ok(value) -> Ok(value)
  }
}

fn locate(line, name, message) {
  case line > 0 {
    True ->
      "at line "
      <> int.to_string(line)
      <> ", in function `"
      <> name
      <> "`: "
      <> message
    False -> "in function `" <> name <> "`: " <> message
  }
}

// ---------------------------------------------------------------------------
// inference
// ---------------------------------------------------------------------------

pub fn infer(env: Env, st: St, expr: Expr) -> Result(#(Ty, St), InferError) {
  use #(typed, st) <- result_try(infer_t(env, st, expr))
  Ok(#(texpr.type_of(typed), st))
}

/// Elaborate a surface expression into a typed expression (`texpr.TExpr`).
/// This is the single inference recursion: callers read types from the result
/// instead of re-inferring.
pub fn infer_t(
  env: Env,
  st: St,
  expr: Expr,
) -> Result(#(texpr.TExpr, St), InferError) {
  case expr {
    EInt(n) -> Ok(#(texpr.TInt(n, Con("Int", [])), st))
    EFloat(f) -> Ok(#(texpr.TFloat(f, Con("Float", [])), st))
    EString(s) -> Ok(#(texpr.TString(s, Con("String", [])), st))
    EBool(b) -> Ok(#(texpr.TBool(b, Con("Bool", [])), st))
    ENil -> Ok(#(texpr.TNil(Con("Nil", [])), st))
    EVar(name) -> infer_var(env, st, name)
    ETuple(elements) -> {
      use #(tys, st) <- result_try(infer_all(env, st, elements))
      Ok(#(texpr.TTuple(tys, Tup(list.map(tys, texpr.type_of))), st))
    }
    ECtor(name, args) -> infer_ctor(env, st, name, args)
    ECall(fun, args) -> infer_call(env, st, fun, args)
    EUnop(op, operand) -> infer_unop(env, st, op, operand)
    EBinop(op, left, right) -> infer_binop(env, st, op, left, right)
    EBlock(statements) -> infer_block(env, st, statements)
    ECase(subject, arms) -> infer_case(env, st, subject, arms)
    EField(obj, name) -> infer_field(env, st, obj, name)
    ELabelled(label, value) -> {
      use #(typed, st) <- result_try(infer_t(env, st, value))
      Ok(#(texpr.TLabelled(label, typed, texpr.type_of(typed)), st))
    }
    ELambda(names, body) -> infer_lambda(env, st, names, body)
    EClosure(code, _, env_ty, fn_ty) -> {
      let ty = convert(fn_ty, dict.new())
      Ok(#(texpr.TClosure(code, [], env_ty, ty, ty), st))
    }
    EEnvGet(env_ty, index, ty) ->
      Ok(#(texpr.TEnvGet(env_ty, index, convert(ty, dict.new())), st))
    EPanic(message, _) -> {
      let #(ty, counter) = types.fresh(st.counter)
      Ok(#(texpr.TPanic(message, ty), St(..st, counter: counter)))
    }
    EBitArray(elements) -> {
      use #(element_tys, st) <- result_try(infer_all(env, st, elements))
      use st <- result_try(unify_lists(
        list.repeat(Con("Int", []), list.length(element_tys)),
        list.map(element_tys, texpr.type_of),
        st,
        "bit array segment",
      ))
      Ok(#(texpr.TBitArray(element_tys, Con("BitArray", [])), st))
    }
    EUpdate(name, base, fields) -> infer_update(env, st, name, base, fields)
  }
}

fn find_update_field(fields, name) {
  case
    list.find(fields, fn(field) {
      let #(label, _) = field
      label == name
    })
  {
    Ok(field) -> {
      let #(_, value) = field
      Ok(value)
    }
    Error(_) -> Error(Nil)
  }
}

fn check_update_fields(fields, field_names) {
  case fields {
    [] -> Ok(Nil)
    [#(label, _), ..rest] ->
      case list.contains(field_names, label) {
        True -> check_update_fields(rest, field_names)
        False ->
          Error(InferError("unknown field `" <> label <> "` in record update"))
      }
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
  use #(body_t, st) <- result_try(infer_t(body_env, st, body))
  Ok(#(
    texpr.TLambda(
      names,
      body_t,
      Fun(list.reverse(param_tys), texpr.type_of(body_t)),
    ),
    st,
  ))
}

fn infer_var(
  env: Env,
  st: St,
  name: String,
) -> Result(#(texpr.TExpr, St), InferError) {
  let scheme = case dict.get(env.locals, name) {
    Ok(found) -> Ok(found)
    Error(_) -> dict.get(env.globals, name)
  }
  case scheme {
    Ok(found) -> {
      let #(ty, counter) = types.instantiate(found, st.counter)
      Ok(#(texpr.TVar(name, ty), St(..st, counter: counter)))
    }
    Error(_) -> Error(InferError("unknown variable `" <> name <> "`"))
  }
}

fn infer_all(env: Env, st: St, exprs) {
  infer_all_loop(env, st, exprs, [])
}

fn infer_all_loop(env: Env, st: St, exprs, acc) {
  case exprs {
    [] -> Ok(#(list.reverse(acc), st))
    [expr, ..rest] ->
      case infer_t(env, st, expr) {
        Ok(#(typed, st)) -> infer_all_loop(env, st, rest, [typed, ..acc])
        Error(error) -> Error(error)
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
      use st <- result_try(unify_lists(
        param_tys,
        list.map(arg_tys, texpr.type_of),
        st,
        name,
      ))
      Ok(#(texpr.TCtor(name, arg_tys, ret), st))
    }
  }
}

fn infer_call(env: Env, st: St, fun, args) {
  case fun {
    EVar(name) -> {
      use #(fun_t, st) <- result_try(infer_var(env, st, name))
      infer_call_dispatch(env, st, texpr.type_of(fun_t), fun_t, args, name)
    }
    EField(EVar(module), name) ->
      infer_call(env, st, EVar(module <> "." <> name), args)
    _ -> {
      use #(fun_t, st) <- result_try(infer_t(env, st, fun))
      infer_call_dispatch(env, st, texpr.type_of(fun_t), fun_t, args, "call")
    }
  }
}

/// When the callee type is still a variable (e.g. calling a higher-order
/// parameter), infer the arguments and unify the callee with their function
/// type; otherwise the parameter types are known and can guide inference.
fn infer_call_dispatch(env, st: St, fun_ty, fun_t, args, ctx) {
  case types.resolve(fun_ty, st.subst) {
    Var(_) -> {
      use #(arg_tys, st) <- result_try(infer_all(env, st, args))
      let #(ret, counter) = types.fresh(st.counter)
      let st = St(..st, counter: counter)
      use st <- result_try(unify_st(
        fun_ty,
        Fun(list.map(arg_tys, texpr.type_of), ret),
        st,
      ))
      Ok(#(texpr.TCall(fun_t, arg_tys, ret), st))
    }
    // Use the resolved type: a function bound by a pattern (e.g. a tuple
    // element) is still a variable that only the substitution resolves.
    resolved -> infer_call_with(env, st, resolved, fun_t, args, ctx)
  }
}

fn infer_call_with(env, st, fun_ty, fun_t, args, ctx) {
  let #(param_tys, ret) = fun_parts(fun_ty)
  use #(arg_tys, st) <- result_try(infer_args_expect(env, st, param_tys, args))
  use st <- result_try(unify_lists(
    param_tys,
    list.map(arg_tys, texpr.type_of),
    st,
    ctx,
  ))
  Ok(#(texpr.TCall(fun_t, arg_tys, ret), st))
}

/// Infers call arguments against the callee's parameter types, so a lambda's
/// parameters are known before its body is checked (needed for field access).
fn infer_args_expect(env, st, expected_list, args) {
  case args, expected_list {
    [], _ -> Ok(#([], st))
    [arg, ..rest], [expected, ..rest_expected] -> {
      use #(arg_t, st) <- result_try(infer_arg_expect(
        env,
        st,
        Some(expected),
        arg,
      ))
      use st <- result_try(unify_st(expected, texpr.type_of(arg_t), st))
      use #(rest_t, st) <- result_try(infer_args_expect(
        env,
        st,
        rest_expected,
        rest,
      ))
      Ok(#([arg_t, ..rest_t], st))
    }
    [arg, ..rest], [] -> {
      use #(arg_t, st) <- result_try(infer_t(env, st, arg))
      use #(rest_t, st) <- result_try(infer_args_expect(env, st, [], rest))
      Ok(#([arg_t, ..rest_t], st))
    }
  }
}

fn infer_arg_expect(env, st, expected, arg) {
  case arg, expected {
    ELambda(names, body), Some(Fun(param_tys, ret)) ->
      case list.length(names) == list.length(param_tys) {
        True -> infer_lambda_expect(env, st, names, body, param_tys, ret)
        False -> infer_t(env, st, arg)
      }
    ELabelled(label, value), _ -> {
      use #(value_t, st) <- result_try(
        infer_arg_expect(env, st, expected, value),
      )
      Ok(#(texpr.TLabelled(label, value_t, texpr.type_of(value_t)), st))
    }
    _, _ -> infer_t(env, st, arg)
  }
}

fn infer_lambda_expect(env, st, names, body, param_tys, ret) {
  let lambda_locals =
    list.fold(list.zip(names, param_tys), dict.new(), fn(acc, pair) {
      let #(name, ty) = pair
      dict.insert(acc, name, Scheme([], ty))
    })
  let body_env = Env(..env, locals: merge_dicts(env.locals, lambda_locals))
  use #(body_t, st) <- result_try(infer_t(body_env, st, body))
  let _ = ret
  Ok(#(
    texpr.TLambda(names, body_t, Fun(param_tys, texpr.type_of(body_t))),
    st,
  ))
}

fn infer_unop(env: Env, st: St, op, operand) {
  use #(operand_t, st) <- result_try(infer_t(env, st, operand))
  let ty = texpr.type_of(operand_t)
  case op {
    "-" -> {
      // Negation is overloaded on Int and Float; resolve Float when known and
      // otherwise default to Int.
      case types.zonk(ty, st.subst) {
        Con("Float", []) ->
          Ok(#(texpr.TUnop(op, operand_t, Con("Float", [])), st))
        _ -> {
          use st <- result_try(unify_st(Con("Int", []), ty, st))
          Ok(#(texpr.TUnop(op, operand_t, Con("Int", [])), st))
        }
      }
    }
    "-." -> {
      use st <- result_try(unify_st(Con("Float", []), ty, st))
      Ok(#(texpr.TUnop(op, operand_t, Con("Float", [])), st))
    }
    "!" -> {
      use st <- result_try(unify_st(Con("Bool", []), ty, st))
      Ok(#(texpr.TUnop(op, operand_t, Con("Bool", [])), st))
    }
    _ -> Error(InferError("unknown unary operator `" <> op <> "`"))
  }
}

fn infer_binop(env: Env, st: St, op, left, right) {
  use #(left_t, st) <- result_try(infer_t(env, st, left))
  use #(right_t, st) <- result_try(infer_t(env, st, right))
  let left_ty = texpr.type_of(left_t)
  let right_ty = texpr.type_of(right_t)
  use #(result_ty, st) <- result_try(case op {
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
  })
  Ok(#(texpr.TBinop(op, left_t, right_t, result_ty), st))
}

fn unify_both(operand_ty, left_ty, right_ty, result_ty, st) {
  use st <- result_try(unify_st(operand_ty, left_ty, st))
  use st <- result_try(unify_st(operand_ty, right_ty, st))
  Ok(#(result_ty, st))
}

fn infer_block(env: Env, st: St, statements) {
  infer_block_loop(env, st, statements, [], Con("Nil", []))
}

fn infer_block_loop(env, st, statements, acc, last_ty) {
  case statements {
    [] -> Ok(#(texpr.TBlock(list.reverse(acc), last_ty), st))
    [Let(pattern, value), ..rest] -> {
      use #(value_t, st) <- result_try(infer_t(env, st, value))
      let value_ty = texpr.type_of(value_t)
      use #(bound, st) <- result_try(bind_pattern(env, pattern, value_ty, st))
      // Local `let` bindings are monomorphic, as in Gleam: no generalisation.
      // Generalising would instantiate a fresh copy at every use, so a
      // unification on one use would not propagate to another.
      let scheme = Scheme([], types.zonk(value_ty, st.subst))
      let locals = bind_let(env.locals, pattern, bound, scheme)
      infer_block_loop(
        Env(..env, locals: locals),
        st,
        rest,
        [texpr.TLet(pattern, value_t), ..acc],
        Con("Nil", []),
      )
    }
    [Stmt(expr), ..rest] -> {
      use #(expr_t, st) <- result_try(infer_t(env, st, expr))
      infer_block_loop(
        env,
        st,
        rest,
        [texpr.TStmt(expr_t), ..acc],
        texpr.type_of(expr_t),
      )
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
  use #(subject_t, st) <- result_try(infer_t(env, st, subject))
  use #(arms_t, result_ty, st) <- result_try(
    infer_arms(env, st, texpr.type_of(subject_t), arms, [], None),
  )
  Ok(#(texpr.TCase(subject_t, arms_t, result_ty), st))
}

fn infer_arms(env: Env, st: St, subject_ty, arms, acc, result_ty) {
  case arms {
    [] ->
      case result_ty {
        None -> Error(InferError("`case` with no arms"))
        Some(ty) -> Ok(#(list.reverse(acc), ty, st))
      }
    [Arm(pattern, guard, body), ..rest] -> {
      use #(bound, st) <- result_try(bind_pattern(env, pattern, subject_ty, st))
      let arm_env = Env(..env, locals: merge_dicts(env.locals, bound))
      use #(guard_t, st) <- result_try(check_arm_guard(arm_env, st, guard))
      use #(body_t, st) <- result_try(infer_t(arm_env, st, body))
      let body_ty = texpr.type_of(body_t)
      let arm = texpr.TArm(pattern, guard_t, body_t)
      case result_ty {
        None ->
          infer_arms(env, st, subject_ty, rest, [arm, ..acc], Some(body_ty))
        Some(ty) -> {
          use st <- result_try(unify_st(ty, body_ty, st))
          infer_arms(env, st, subject_ty, rest, [arm, ..acc], Some(ty))
        }
      }
    }
  }
}

fn check_arm_guard(env: Env, st: St, guard) {
  case guard {
    None -> Ok(#(None, st))
    Some(expr) -> {
      use #(expr_t, st) <- result_try(infer_t(env, st, expr))
      use st <- result_try(unify_st(Con("Bool", []), texpr.type_of(expr_t), st))
      Ok(#(Some(expr_t), st))
    }
  }
}

fn infer_field(env: Env, st: St, obj, name) {
  use #(obj_t, st) <- result_try(infer_t(env, st, obj))
  case types.resolve(texpr.type_of(obj_t), st.subst) {
    Con(type_name, args) -> {
      use field_ty <- result_try(field_type(env, type_name, args, name))
      Ok(#(texpr.TField(obj_t, name, field_ty), st))
    }
    Var(_) -> field_on_var(env, st, obj_t, name)
    _ -> Error(InferError("field access on a non-record value"))
  }
}

/// When the object type is still unknown, resolve it from the field name: if
/// exactly one type has a field with that name, unify the object with it.
fn field_on_var(env: Env, st: St, obj_t, name) {
  case unique_field_type_name(env, name) {
    Error(_) -> {
      // Ambiguous (or unknown): defer. The object type is usually resolved
      // later (e.g. by a record update or through other uses) and the backend
      // checker validates the access against the concrete type.
      let #(field_ty, counter) = types.fresh(st.counter)
      Ok(#(texpr.TField(obj_t, name, field_ty), St(..st, counter: counter)))
    }
    Ok(type_name) -> {
      let TypeDef(_, params, _) =
        dict.get(env.types, type_name)
        |> result.unwrap(TypeDef("", [], []))
      let #(vars, counter) = types.fresh_many(st.counter, list.length(params))
      let st = St(..st, counter: counter)
      use st <- result_try(unify_st(
        texpr.type_of(obj_t),
        Con(type_name, vars),
        st,
      ))
      use field_ty <- result_try(field_type(env, type_name, vars, name))
      Ok(#(texpr.TField(obj_t, name, field_ty), st))
    }
  }
}

/// Record update: desugar to a constructor whose unchanged fields read from
/// `base`, exactly like the untyped inference, then keep only the written
/// fields in the typed node.
fn infer_update(env: Env, st: St, name, base, fields) {
  case dict.get(env.ctors, name) {
    Error(_) -> Error(InferError("unknown record `" <> name <> "`"))
    Ok(CtorDef(_, field_names, scheme)) -> {
      use _ <- result_try(check_update_fields(fields, field_names))
      // The constructor name fixes the base's type (`Builder(..b)` makes
      // `b: Builder`), so infer the base once and read the unchanged fields
      // from it directly; never re-infer the base (as Gleam does).
      let #(ctor_ty, st) = instantiate_ty(scheme, st)
      let #(param_tys, ret) = fun_parts(ctor_ty)
      use #(base_t, st) <- result_try(infer_t(env, st, base))
      use st <- result_try(unify_st(ret, texpr.type_of(base_t), st))
      use #(typed_args, st) <- result_try(
        infer_update_args(env, st, base_t, field_names, param_tys, fields, []),
      )
      let indexed =
        list.index_map(field_names, fn(field_name, index) {
          #(field_name, index)
        })
      let typed_fields =
        list.filter_map(fields, fn(field) {
          let #(label, _) = field
          case list.find(indexed, fn(pair) {
            let #(field_name, _) = pair
            field_name == label
          }) {
            Ok(pair) -> {
              let #(_, index) = pair
              case list.drop(typed_args, index) {
                [typed, ..] -> Ok(#(label, typed))
                [] -> Error(Nil)
              }
            }
            Error(_) -> Error(Nil)
          }
        })
      Ok(#(texpr.TUpdate(name, base_t, typed_fields, ret), st))
    }
  }
}

/// Build the constructor arguments of a record update in formal field order:
/// updated fields infer their value and unify with the parameter type;
/// unchanged fields read from the already-typed base.
fn infer_update_args(
  env: Env,
  st: St,
  base_t: texpr.TExpr,
  field_names: List(String),
  param_tys: List(types.Ty),
  fields: List(#(String, Expr)),
  acc: List(texpr.TExpr),
) {
  case field_names, param_tys {
    [], _ -> Ok(#(list.reverse(acc), st))
    [field_name, ..rest_names], [param_ty, ..rest_params] -> {
      let param_ty = types.zonk(param_ty, st.subst)
      use #(arg_t, st) <- result_try(case find_update_field(fields, field_name) {
        Ok(value) -> {
          use #(value_t, st) <- result_try(infer_t(env, st, value))
          use st <- result_try(unify_st(param_ty, texpr.type_of(value_t), st))
          Ok(#(value_t, st))
        }
        Error(_) -> Ok(#(texpr.TField(base_t, field_name, param_ty), st))
      })
      infer_update_args(
        env,
        st,
        base_t,
        rest_names,
        rest_params,
        fields,
        [arg_t, ..acc],
      )
    }
    _, _ -> Error(InferError("record update has the wrong number of fields"))
  }
}

fn unique_field_type_name(env: Env, name) -> Result(String, Nil) {
  let candidates =
    list.filter_map(dict.to_list(env.types), fn(entry) {
      let #(type_name, def) = entry
      let TypeDef(_, _, variants) = def
      case
        list.any(variants, fn(variant) {
          let VariantDef(_, fields) = variant
          result.is_ok(list.key_find(fields, name))
        })
      {
        True -> Ok(type_name)
        False -> Error(Nil)
      }
    })
  case candidates {
    [only] -> Ok(only)
    _ -> Error(Nil)
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
    PAs(inner, name) -> {
      use #(bindings, st) <- result_try(bind_pattern(env, inner, ty, st))
      Ok(#(dict.insert(bindings, name, Scheme([], ty)), st))
    }
    PBitArray(patterns) -> {
      use st <- result_try(unify_st(Con("BitArray", []), ty, st))
      bind_patterns(
        env,
        patterns,
        list.repeat(Con("Int", []), list.length(patterns)),
        st,
      )
    }
  }
}

/// Resolves labelled/positional pattern arguments to the formal field order.
fn empty_pattern_slots(names: List(String)) -> List(Option(Pattern)) {
  list.map(names, fn(_) { None })
}

pub fn order_pattern(field_names, ctx, args) -> Result(List(Pattern), String) {
  let slots = empty_pattern_slots(field_names)
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

fn result_try(result, next) {
  case result {
    Ok(value) -> next(value)
    Error(err) -> Error(err)
  }
}
