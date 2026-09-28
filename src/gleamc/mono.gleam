//// Monomorphisation (Stage 3): turns the generic AST into a monomorphic one.
////
//// Generic types and functions are specialised per concrete instantiation,
//// discovered from the entry points by a worklist that reuses the HM checker
//// for type computation. After this pass every `TApp`/`TVar` is gone and
//// constructors/functions have concrete, mangled names, so the existing
//// monomorphic backend (lower + ownership) can run unchanged.

import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleamc/ast.{
  type CustomType, type Expr, type Function, type Module, type Pattern,
  type Type, type Variant, Arm, CustomType, DCustomType, DExternal, DFunction,
  EBinop, EBitArray, EBlock, EBool, ECall, ECase, EClosure, ECtor, EEnvGet,
  EField, EFloat, EInt, ELabelled, ELambda, ENil, EPanic, EString, ETuple, EUnop,
  EUpdate, EVar, Function, Let, Module, PAs, PBitArray, PBool, PCtor, PFloat,
  PInt, PLabelled, PNil, PString, PTuple, PVar, PWildcard, Stmt, TApp, TFun,
  TNamed, TTuple, TVar, Variant,
}
import gleamc/ffi
import gleamc/infer
import gleamc/texpr
import gleamc/tmono
import gleamc/types.{type Scheme, Con, Fun, Scheme, Tup, Var}
import gleamc/util

pub fn monomorphize(module: Module) -> Result(tmono.TModule, String) {
  use #(resolved, program) <- result_try(
    map_check(infer.check_resolved(module)),
  )
  let state = initial_state(resolved, program)
  use state <- result_try(seed(state))
  use state <- result_try(run(state))
  let sorted_types =
    list.sort(state.type_out, fn(a, b) {
      int.compare(type_rank(state, a), type_rank(state, b))
    })
  // `@external` declarations have no body to specialise; keep them verbatim.
  let Module(definitions) = resolved
  let external_defs =
    list.filter_map(definitions, fn(def) {
      case def {
        DExternal(external) -> Ok(tmono.TDExternal(external))
        _ -> Error(Nil)
      }
    })
  let typed_type_defs =
    list.map(sorted_types, fn(custom) { tmono.TDCustomType(custom) })
  // `state.fn_out` accumulates by prepending; reverse it back to emission
  // order, matching the order the surface module would have had.
  let typed_fn_defs =
    list.map(list.reverse(state.fn_out), fn(function) {
      tmono.TDFunction(function)
    })
  // The monomorphiser owns the typed monomorphic product: every node was
  // annotated during the walk, so no further elaboration is needed.
  Ok(
    tmono.TModule(list.append(
      typed_type_defs,
      list.append(typed_fn_defs, external_defs),
    )),
  )
}

// ---------------------------------------------------------------------------
// state
// ---------------------------------------------------------------------------

type State {
  State(
    subst: types.Subst,
    counter: Int,
    globals: Dict(String, Scheme),
    ctors: Dict(String, infer.CtorDef),
    types: Dict(String, infer.TypeDef),
    /// The type variables in scope while walking the current specialised
    /// function body, mapped to their concrete surface types. Used to turn an
    /// inferred type into its specialised surface type.
    surface_map: Dict(String, Type),
    surface_fns: Dict(String, Function),
    surface_types: Dict(String, CustomType),
    type_order: Dict(String, Int),
    type_rank: Dict(String, Int),
    fn_names: Dict(String, String),
    type_names: Dict(String, String),
    type_generics: Dict(String, Type),
    ctor_names: Dict(String, String),
    pending_fn: List(#(String, List(Type))),
    pending_type: List(#(String, List(Type))),
    fn_out: List(tmono.TFunction),
    type_out: List(CustomType),
  )
}

fn initial_state(module: Module, program: infer.Program) -> State {
  let Module(definitions) = module
  let surface_fns =
    list.fold(definitions, dict.new(), fn(acc, def) {
      case def {
        DFunction(function) -> dict.insert(acc, function.name, function)
        _ -> acc
      }
    })
  let surface_types =
    list.fold(definitions, dict.new(), fn(acc, def) {
      case def {
        DCustomType(custom) -> {
          let CustomType(_, name, _, _, _) = custom
          dict.insert(acc, name, custom)
        }
        _ -> acc
      }
    })
  let type_order =
    list.fold(
      list.index_map(definitions, fn(d, i) { #(d, i) }),
      dict.new(),
      fn(acc, pair) {
        let #(def, index) = pair
        case def {
          DCustomType(custom) -> {
            let CustomType(_, name, _, _, _) = custom
            dict.insert(acc, name, index)
          }
          _ -> acc
        }
      },
    )
  let infer.Program(_functions, ctors, types_map) = program
  State(
    subst: types.empty(),
    counter: 0,
    globals: infer.globals_of(program),
    ctors: ctors,
    types: types_map,
    surface_map: dict.new(),
    surface_fns: surface_fns,
    surface_types: surface_types,
    type_order: type_order,
    type_rank: dict.new(),
    fn_names: dict.new(),
    type_names: dict.new(),
    type_generics: dict.new(),
    ctor_names: dict.new(),
    pending_fn: [],
    pending_type: [],
    fn_out: [],
    type_out: [],
  )
}

/// Seeds the worklist with the monomorphic functions (those without type
/// parameters). Generic functions are only specialised when called.
fn seed(state: State) {
  let state =
    list.fold(dict.to_list(state.surface_fns), state, fn(acc, entry) {
      let #(name, function) = entry
      case function_type_vars(function) {
        [] -> request_fn(acc, name, [])
        _ -> acc
      }
    })
  Ok(state)
}

// ---------------------------------------------------------------------------
// worklist
// ---------------------------------------------------------------------------

fn run(state: State) {
  case state.pending_fn {
    [#(name, args), ..rest] -> {
      let state = State(..state, pending_fn: rest)
      use state <- result_try(specialise_fn(state, name, args))
      run(state)
    }
    [] ->
      case state.pending_type {
        [#(name, args), ..rest] -> {
          let state = State(..state, pending_type: rest)
          use state <- result_try(specialise_type(state, name, args))
          run(state)
        }
        [] -> Ok(state)
      }
  }
}

fn request_fn(state: State, name: String, args: List(Type)) -> State {
  case args {
    [] ->
      case dict.get(state.fn_names, key(name, args)) {
        Ok(_) -> state
        Error(_) ->
          State(
            ..state,
            fn_names: dict.insert(state.fn_names, key(name, args), name),
            pending_fn: [#(name, args), ..state.pending_fn],
          )
      }
    _ -> {
      let specialized = name <> "_" <> mangle_args(args)
      case dict.get(state.fn_names, key(name, args)) {
        Ok(_) -> state
        Error(_) ->
          State(
            ..state,
            fn_names: dict.insert(state.fn_names, key(name, args), specialized),
            pending_fn: [#(name, args), ..state.pending_fn],
          )
      }
    }
  }
}

fn fn_specialised_name(state: State, name, args) {
  case dict.get(state.fn_names, key(name, args)) {
    Ok(specialized) -> specialized
    Error(_) -> name
  }
}

fn request_type(
  state: State,
  name: String,
  args: List(Type),
) -> #(String, State) {
  let specialized = case args {
    [] -> name
    _ -> name <> "_" <> mangle_args(args)
  }
  case dict.get(state.type_names, key(name, args)) {
    Ok(existing) -> #(existing, state)
    Error(_) -> #(
      specialized,
      State(
        ..state,
        type_names: dict.insert(state.type_names, key(name, args), specialized),
        type_generics: dict.insert(state.type_generics, specialized, case args {
          [] -> TNamed(name)
          _ -> TApp(name, args)
        }),
        pending_type: [#(name, args), ..state.pending_type],
      ),
    )
  }
}

fn ctor_specialised_name(state: State, type_name, name, args) {
  case dict.get(state.ctor_names, ctor_key(type_name, name, args)) {
    Ok(specialized) -> specialized
    Error(_) -> ctor_specialised(type_name, name, args)
  }
}

fn ctor_key(type_name, name, args) -> String {
  type_name <> "|" <> key(name, args)
}

fn key(name, args) -> String {
  name <> "|" <> mangle_args(args)
}

// ---------------------------------------------------------------------------
// specialisation
// ---------------------------------------------------------------------------

/// Substitutes the enclosing type variables, keeping generic applications as
/// `TApp` (internal form used for inference). `mono_type` specialises after.
fn subst_surface(surface_map: Dict(String, Type), ty: Type) -> Type {
  case ty {
    TVar(name) ->
      case dict.get(surface_map, name) {
        Ok(concrete) -> concrete
        Error(_) -> ty
      }
    TApp(name, args) ->
      TApp(name, list.map(args, fn(arg) { subst_surface(surface_map, arg) }))
    TTuple(items) ->
      TTuple(list.map(items, fn(item) { subst_surface(surface_map, item) }))
    TFun(params, ret) ->
      TFun(
        list.map(params, fn(p) { subst_surface(surface_map, p) }),
        subst_surface(surface_map, ret),
      )
    _ -> ty
  }
}

fn specialise_fn(state: State, name, type_args) {
  case specialise_fn_inner(state, name, type_args) {
    Ok(found) -> Ok(found)
    Error(err) -> Error("while specialising `" <> name <> "`: " <> err)
  }
}

fn specialise_fn_inner(state: State, name, type_args) {
  case dict.get(state.surface_fns, name) {
    Error(_) -> Ok(state)
    Ok(function) -> {
      let Function(is_pub, _, params, ret, body, line) = function
      let var_names = function_type_vars(function)
      let surface_map =
        list.fold(list.zip(var_names, type_args), dict.new(), fn(acc, pair) {
          let #(var_name, arg) = pair
          dict.insert(acc, var_name, arg)
        })
      // Make the enclosing type variables visible to the body walk, so each
      // output node can carry its specialised surface type.
      let state = State(..state, surface_map: surface_map)
      use #(params2, state) <- result_try(mono_params(
        state,
        surface_map,
        params,
      ))
      use #(ret2, state) <- result_try(mono_type(state, surface_map, ret))
      let locals =
        list.fold(params, dict.new(), fn(acc, param) {
          let #(param_name, param_ty) = param
          let internal = ty_of_surface(subst_surface(surface_map, param_ty))
          dict.insert(acc, param_name, Scheme([], internal))
        })
      let internal_ret = ty_of_surface(subst_surface(surface_map, ret))
      // Pre-infer the body so that type variables which are resolved by later
      // uses (e.g. a nullary constructor among a call's arguments) are known
      // before monomorphisation specialises those expressions. Variables that
      // stay free are genuinely unconstrained and default to `Nil`.
      let env = infer.Env(state.globals, locals, state.ctors, state.types)
      // Elaborate the body once; the typed tree carries every node's type, so
      // the monomorphiser reads types from it instead of re-inferring. An
      // inference failure is non-fatal, exactly as before: fall back to the
      // surface body with an empty substitution.
      let body_result = case
        infer.infer_t(env, infer.St(types.empty(), state.counter), body)
      {
        Ok(#(body_t, st2)) -> {
          let state0 = State(..state, subst: st2.subst, counter: st2.counter)
          mono_expr_ex_pair(
            state0,
            locals,
            Some(internal_ret),
            body,
            Some(body_t),
          )
        }
        Error(_) -> {
          let state0 =
            State(..state, subst: types.empty(), counter: state.counter)
          mono_expr_ex(state0, locals, Some(internal_ret), body)
        }
      }
      use #(body2, state1) <- result_try(body_result)
      let specialized = fn_specialised_name(state1, name, type_args)
      // Register the specialised signature so later `type_of` calls (on
      // already-specialised calls) can resolve its type.
      let internal_params =
        list.map(params2, fn(param) {
          let #(_, param_ty) = param
          ty_of_surface(param_ty)
        })
      let scheme = Scheme([], Fun(internal_params, ty_of_surface(ret2)))
      let globals = case specialized == name {
        // Monomorphic functions already have a (generic) scheme in globals;
        // only new specialised names need registering.
        True -> state1.globals
        False -> dict.insert(state1.globals, specialized, scheme)
      }
      Ok(
        State(..state1, globals: globals, fn_out: [
          tmono.TFunction(is_pub, specialized, params2, ret2, body2, line),
          ..state1.fn_out
        ]),
      )
    }
  }
}

fn mono_params(state: State, surface_map, params) {
  mono_params_acc(state, surface_map, params, [])
}

fn mono_params_acc(
  state,
  surface_map,
  params,
  acc,
) -> Result(#(List(#(String, Type)), State), String) {
  case params {
    [] -> Ok(#(list.reverse(acc), state))
    [#(name, ty), ..rest] -> {
      use #(ty2, state) <- result_try(mono_type(state, surface_map, ty))
      mono_params_acc(state, surface_map, rest, [#(name, ty2), ..acc])
    }
  }
}

fn rank_of_surface(state: State, ty) -> Int {
  let found = case ty {
    TApp(name, args) ->
      case dict.get(state.type_names, key(name, args)) {
        Ok(specialized) -> dict.get(state.type_rank, specialized)
        Error(_) -> Error(Nil)
      }
    TNamed(name) -> dict.get(state.type_rank, name)
    _ -> Error(Nil)
  }
  case found {
    Ok(rank) -> rank
    Error(_) -> 0
  }
}

fn specialise_type(state: State, name, type_args) {
  case dict.get(state.surface_types, name) {
    Error(_) -> Ok(state)
    Ok(custom) -> {
      let CustomType(is_pub, _, generics, variants, _) = custom
      let surface_map =
        list.fold(list.zip(generics, type_args), dict.new(), fn(acc, pair) {
          let #(generic, arg) = pair
          dict.insert(acc, generic, arg)
        })
      let specialized = case dict.get(state.type_names, key(name, type_args)) {
        Ok(found) -> found
        Error(_) -> name
      }
      // Rank so that a specialised type is emitted after the types it embeds
      // (e.g. `Option(Option(Int))` after `Option(Int)`).
      let arg_rank =
        list.fold(type_args, 0, fn(acc, arg) {
          int.max(acc, rank_of_surface(state, arg))
        })
      let state =
        State(
          ..state,
          type_rank: dict.insert(
            state.type_rank,
            specialized,
            order_of(state, name) * 100_000 + arg_rank + 1,
          ),
        )
      use #(variants2, state) <- result_try(mono_variants(
        state,
        name,
        type_args,
        surface_map,
        variants,
      ))
      Ok(
        State(..state, type_out: [
          CustomType(is_pub, specialized, [], variants2, False),
          ..state.type_out
        ]),
      )
    }
  }
}

fn mono_variants(state: State, type_name, type_args, surface_map, variants) {
  mono_variants_acc(state, type_name, type_args, surface_map, variants, [])
}

fn mono_variants_acc(
  state,
  type_name,
  type_args,
  surface_map,
  variants,
  acc,
) -> Result(#(List(Variant), State), String) {
  case variants {
    [] -> Ok(#(list.reverse(acc), state))
    [Variant(ctor, fields), ..rest] -> {
      let ctor_specialized =
        ctor_specialised_name(state, type_name, ctor, type_args)
      use #(fields2, state) <- result_try(mono_fields(
        state,
        surface_map,
        fields,
      ))
      mono_variants_acc(state, type_name, type_args, surface_map, rest, [
        Variant(ctor_specialized, fields2),
        ..acc
      ])
    }
  }
}

fn mono_fields(state: State, surface_map, fields) {
  mono_fields_acc(state, surface_map, fields, [])
}

fn mono_fields_acc(
  state,
  surface_map,
  fields,
  acc,
) -> Result(#(List(#(String, Type)), State), String) {
  case fields {
    [] -> Ok(#(list.reverse(acc), state))
    [#(name, ty), ..rest] -> {
      use #(ty2, state) <- result_try(mono_type(state, surface_map, ty))
      mono_fields_acc(state, surface_map, rest, [#(name, ty2), ..acc])
    }
  }
}

/// Rewrites a surface type: substitutes the enclosing type variables and
/// specialises generic applications (`Option(Int)` -> `Option_Int`).
fn mono_type(
  state: State,
  surface_map: Dict(String, Type),
  ty: Type,
) -> Result(#(Type, State), String) {
  case ty {
    TVar(name) ->
      case dict.get(surface_map, name) {
        // The bound type is itself a surface type and may contain generic
        // applications (`List(Int)` for `List(List(Int))`), so specialise it.
        Ok(concrete) -> mono_type(state, surface_map, concrete)
        Error(_) -> Error("unbound type variable `" <> name <> "`")
      }
    TApp(name, args) -> {
      use #(args2, state) <- result_try(mono_types(state, surface_map, args))
      let #(specialized, state) = request_type(state, name, args2)
      Ok(#(TNamed(specialized), state))
    }
    TTuple(items) -> {
      use #(items2, state) <- result_try(mono_types(state, surface_map, items))
      Ok(#(TTuple(items2), state))
    }
    TFun(params, ret) -> {
      use #(params2, state) <- result_try(mono_types(state, surface_map, params))
      use #(ret2, state) <- result_try(mono_type(state, surface_map, ret))
      Ok(#(TFun(params2, ret2), state))
    }
    TNamed(name) ->
      // A custom type referenced only as a field of another type (e.g.
      // `ExitReason` inside `Down`) must still be emitted, so request it.
      case dict.get(state.surface_types, name) {
        Ok(_) -> {
          let #(specialized, state) = request_type(state, name, [])
          Ok(#(TNamed(specialized), state))
        }
        Error(_) -> Ok(#(ty, state))
      }
    _ -> Ok(#(ty, state))
  }
}

fn mono_types(
  state: State,
  surface_map: Dict(String, Type),
  types_list: List(Type),
) {
  mono_types_acc(state, surface_map, types_list, [])
}

fn mono_types_acc(
  state,
  surface_map,
  types_list,
  acc,
) -> Result(#(List(Type), State), String) {
  case types_list {
    [] -> Ok(#(list.reverse(acc), state))
    [ty, ..rest] -> {
      use #(ty2, state) <- result_try(mono_type(state, surface_map, ty))
      mono_types_acc(state, surface_map, rest, [ty2, ..acc])
    }
  }
}

// ---------------------------------------------------------------------------
// specialised surface types for output nodes
// ---------------------------------------------------------------------------

/// The specialised surface type of an inferred `types.Ty` under the enclosing
/// function's type substitution. Types are ground by now, so the registration
/// performed by `mono_type` is idempotent (the specialised type was already
/// requested when the surface was rewritten).
fn specialised(state: State, ty: types.Ty) -> #(Type, State) {
  case mono_type(state, state.surface_map, surface_of(ty)) {
    Ok(#(surface, state2)) -> #(surface, state2)
    Error(_) -> #(surface_of(ty), state)
  }
}

/// The result type of a binary operator, mirroring the checker.
fn binop_ty(op: String) -> Type {
  case op {
    "+" | "-" | "*" | "/" | "%" -> ast.TInt
    "+." | "-." | "*." | "/." -> ast.TFloat
    "<>" -> ast.TString
    _ -> ast.TBool
  }
}

/// The result type of a unary operator, mirroring the checker.
fn unop_ty(op: String, operand_ty: Type) -> Type {
  case op {
    "!" -> ast.TBool
    "-." -> ast.TFloat
    _ -> operand_ty
  }
}

/// The specialised function type of a top-level function instantiated with
/// `type_args`, as the checker would compute it from the signature.
fn fn_specialised_ty(
  state: State,
  name: String,
  type_args: List(Type),
) -> #(Type, State) {
  case dict.get(state.surface_fns, name) {
    Error(_) -> #(ast.TNil, state)
    Ok(function) -> {
      let Function(_, _, params, ret, _, _) = function
      let var_names = function_type_vars(function)
      let smap =
        list.fold(list.zip(var_names, type_args), dict.new(), fn(acc, pair) {
          let #(var_name, arg) = pair
          dict.insert(acc, var_name, arg)
        })
      let param_types =
        list.map(params, fn(param) {
          let #(_, param_ty) = param
          param_ty
        })
      case mono_types(state, smap, param_types) {
        Ok(#(params2, state2)) ->
          case mono_type(state2, smap, ret) {
            Ok(#(ret2, state3)) -> #(ast.TFun(params2, ret2), state3)
            Error(_) -> #(ast.TNil, state2)
          }
        Error(_) -> #(ast.TNil, state)
      }
    }
  }
}

/// The specialised type of a variable (a local binding, or a top-level
/// function used as a value).
fn var_specialised_ty(
  state: State,
  locals: Dict(String, Scheme),
  name: String,
) -> #(Type, State) {
  case dict.get(locals, name) {
    Ok(Scheme(_, ty)) -> specialised(state, types.zonk(ty, state.subst))
    Error(_) ->
      case dict.get(state.globals, name) {
        Ok(Scheme(_, ty)) -> specialised(state, types.zonk(ty, state.subst))
        Error(_) -> #(ast.TNil, state)
      }
  }
}

/// The type of a block: its final statement's type, or `Nil` when it ends in a
/// `let` (or is empty), mirroring the checker.
fn block_ty(statements: List(tmono.TStatement)) -> Type {
  case list.reverse(statements) {
    [] -> ast.TNil
    [tmono.TStmt(expr), ..] -> tmono.type_of(expr)
    [tmono.TLet(_, _), ..] -> ast.TNil
  }
}

/// The result type of a `case`: the first arm body's type, mirroring the
/// checker (all arm bodies share a type after mono).
fn arms_result_ty(arms: List(tmono.TArm)) -> Type {
  case arms {
    [] -> ast.TNil
    [tmono.TArm(_, _, body), ..] -> tmono.type_of(body)
  }
}

/// The specialised return type of a builtin (or any global scheme) applied to
/// `arg_tys`, resolved against the scheme without advancing the counter.
fn global_call_ret_ty(
  state: State,
  fun: Expr,
  arg_tys: List(types.Ty),
  expected: Option(types.Ty),
) -> Type {
  case fun {
    EField(EVar(module), name) -> {
      let full = module <> "." <> name
      case dict.get(state.globals, full) {
        Error(_) -> ast.TNil
        Ok(scheme) -> {
          let Scheme(_, fun_ty) = scheme
          let #(param_tys, ret) = fun_parts(fun_ty)
          let generic_args =
            list.map(arg_tys, fn(ty) { unspecialize_internal(state, ty) })
          let unified = case unify_seq(param_tys, generic_args, types.empty()) {
            Ok(subst) -> subst
            Error(_) -> types.empty()
          }
          let unified = case expected {
            Some(expected_ty) ->
              case
                map_unify(
                  ret,
                  unspecialize_internal(state, expected_ty),
                  unified,
                )
              {
                Ok(subst) -> subst
                Error(_) -> unified
              }
            None -> unified
          }
          let #(ty, _) = specialised(state, types.zonk(ret, unified))
          ty
        }
      }
    }
    _ -> ast.TNil
  }
}

/// The specialised type of a record field, resolved from the (generic) custom
/// type definition and the object's specialised type. The inference companion
/// can leave an ambiguous field type as an unresolved variable, so the backend
/// checker's rule (look the field up in the constructor info) is mirrored here.
fn field_specialised_ty(
  state: State,
  obj_ty: Type,
  name: String,
) -> #(Type, State) {
  case obj_ty {
    TNamed(specialized) -> {
      let #(orig, args) = case dict.get(state.type_generics, specialized) {
        Ok(TNamed(base)) -> #(base, [])
        Ok(TApp(base, type_args)) -> #(base, type_args)
        Ok(_) -> #(specialized, [])
        Error(_) -> #(specialized, [])
      }
      case dict.get(state.surface_types, orig) {
        Error(_) -> #(ast.TNil, state)
        Ok(CustomType(_, _, generics, variants, _)) -> {
          let smap =
            list.fold(list.zip(generics, args), dict.new(), fn(acc, pair) {
              let #(generic, arg) = pair
              dict.insert(acc, generic, arg)
            })
          let found =
            list.filter_map(variants, fn(variant) {
              let Variant(_, fields) = variant
              case list.key_find(fields, name) {
                Ok(field_ty) -> Ok(field_ty)
                Error(_) -> Error(Nil)
              }
            })
          case found {
            [field_ty, ..] ->
              case mono_type(state, smap, field_ty) {
                Ok(#(ty, state2)) -> #(ty, state2)
                Error(_) -> #(ast.TNil, state)
              }
            [] -> #(ast.TNil, state)
          }
        }
      }
    }
    _ -> #(ast.TNil, state)
  }
}

/// The callee `TExpr` for a call whose surface callee is not a plain variable,
/// mirroring the checker's builtin shape (`module.name` becomes a field of a
/// `Nil`-typed module variable).
fn callee_texpr(
  state: State,
  locals,
  fun: Expr,
) -> Result(#(tmono.TExpr, State), String) {
  case fun {
    EField(EVar(module), name) ->
      Ok(#(tmono.TField(tmono.TVar(module, ast.TNil), name, ast.TNil), state))
    _ -> mono_expr(state, locals, fun)
  }
}

// ---------------------------------------------------------------------------
// expression rewriting (type-directed)
// ---------------------------------------------------------------------------

fn mono_expr(
  state: State,
  locals: Dict(String, Scheme),
  expr,
) -> Result(#(tmono.TExpr, State), String) {
  case expr {
    EInt(value) -> Ok(#(tmono.TInt(value, ast.TInt), state))
    EFloat(value) -> Ok(#(tmono.TFloat(value, ast.TFloat), state))
    EString(value) -> Ok(#(tmono.TString(value, ast.TString), state))
    EBool(value) -> Ok(#(tmono.TBool(value, ast.TBool), state))
    ENil -> Ok(#(tmono.TNil(ast.TNil), state))
    EVar(name) -> {
      let #(ty, state) = var_specialised_ty(state, locals, name)
      Ok(#(tmono.TVar(name, ty), state))
    }
    ELabelled(label, value) -> {
      use #(value2, state) <- result_try(mono_expr(state, locals, value))
      Ok(#(tmono.TLabelled(label, value2, tmono.type_of(value2)), state))
    }
    ETuple(elements) -> {
      use #(elements2, state) <- result_try(mono_exprs(state, locals, elements))
      let ty = ast.TTuple(list.map(elements2, tmono.type_of))
      Ok(#(tmono.TTuple(elements2, ty), state))
    }
    EBinop(op, left, right) -> {
      use #(left2, state) <- result_try(mono_expr(state, locals, left))
      let #(left_ty, state) = type_of(state, locals, left)
      use #(right2, state) <- result_try(mono_expr_ex(
        state,
        locals,
        Some(left_ty),
        right,
      ))
      Ok(#(tmono.TBinop(op, left2, right2, binop_ty(op)), state))
    }
    EUnop(op, operand) -> {
      use #(operand2, state) <- result_try(mono_expr(state, locals, operand))
      let ty = unop_ty(op, tmono.type_of(operand2))
      Ok(#(tmono.TUnop(op, operand2, ty), state))
    }
    EField(obj, name) -> {
      use #(obj2, state) <- result_try(mono_expr(state, locals, obj))
      let #(ty, state) = field_specialised_ty(state, tmono.type_of(obj2), name)
      Ok(#(tmono.TField(obj2, name, ty), state))
    }
    EBlock(statements) -> mono_block(state, locals, statements)
    ECall(fun, args) -> mono_call(state, locals, fun, args, None)
    ECtor(name, args) -> mono_ctor(state, locals, name, args)
    ECase(subject, arms) -> mono_case(state, locals, subject, arms)
    ELambda(_, _) -> Error("lambda requires an expected function type")
    EClosure(code, captures, env_ty, fn_ty) -> {
      use #(captures2, state) <- result_try(mono_exprs(state, locals, captures))
      Ok(#(tmono.TClosure(code, captures2, env_ty, fn_ty, fn_ty), state))
    }
    EEnvGet(env_ty, index, ty) -> {
      use #(specialized, state) <- result_try(specialize_env_get(state, ty))
      Ok(#(tmono.TEnvGet(env_ty, index, specialized), state))
    }
    EPanic(message, ty) -> Ok(#(tmono.TPanic(message, ty), state))
    EUpdate(name, base, fields) ->
      mono_update(state, locals, no_expected_ty(), name, base, fields)
    EBitArray(elements) -> {
      use #(elements2, state) <- result_try(mono_exprs(state, locals, elements))
      Ok(#(tmono.TBitArray(elements2, ast.TNamed("BitArray")), state))
    }
  }
}

/// Like `mono_expr`, but with an expected type used to resolve constructors
/// that carry no arguments.
fn mono_expr_ex(
  state,
  locals,
  expected,
  expr,
) -> Result(#(tmono.TExpr, State), String) {
  case expr {
    ECtor(name, args) -> mono_ctor_ex(state, locals, name, args, expected)
    ECase(subject, arms) -> {
      use #(subject2, state) <- result_try(mono_expr(state, locals, subject))
      let #(subject_ty, state) = type_of(state, locals, subject)
      use #(arms2, state) <- result_try(mono_arms_ex(
        state,
        locals,
        subject_ty,
        expected,
        arms,
      ))
      let ty = arms_result_ty(arms2)
      Ok(#(tmono.TCase(subject2, arms2, ty), state))
    }
    EBlock(statements) -> mono_block_ex(state, locals, expected, statements)
    ECall(fun, args) -> mono_call(state, locals, fun, args, expected)
    ELambda(names, body) ->
      lift_lambda(state, locals, names, body, None, expected)
    EClosure(code, captures, env_ty, fn_ty) -> {
      use #(captures2, state) <- result_try(mono_exprs(state, locals, captures))
      Ok(#(tmono.TClosure(code, captures2, env_ty, fn_ty, fn_ty), state))
    }
    EEnvGet(env_ty, index, ty) -> {
      use #(specialized, state) <- result_try(specialize_env_get(state, ty))
      Ok(#(tmono.TEnvGet(env_ty, index, specialized), state))
    }
    EPanic(message, _) -> {
      use #(ty, state) <- result_try(case expected {
        Some(expected_ty) ->
          mono_type(state, dict.new(), surface_of(expected_ty))
        None -> Ok(#(ast.TNil, state))
      })
      Ok(#(tmono.TPanic(message, ty), state))
    }
    EVar(name) ->
      case dict.get(locals, name) {
        Ok(_) -> {
          let #(ty, state) = var_specialised_ty(state, locals, name)
          Ok(#(tmono.TVar(name, ty), state))
        }
        Error(_) ->
          case eta_expand(state, locals, name, expected) {
            Ok(expanded) -> Ok(expanded)
            Error(_) -> {
              let #(ty, state) = var_specialised_ty(state, locals, name)
              Ok(#(tmono.TVar(name, ty), state))
            }
          }
      }
    ELabelled(label, value) -> {
      use #(value2, state) <- result_try(mono_expr_ex(
        state,
        locals,
        expected,
        value,
      ))
      Ok(#(tmono.TLabelled(label, value2, tmono.type_of(value2)), state))
    }
    ETuple(elements) -> {
      case expected {
        Some(Tup(expected_items)) ->
          case list.length(elements) == list.length(expected_items) {
            True -> {
              use #(elements2, state) <- result_try(mono_exprs_ex(
                state,
                locals,
                expected_items,
                elements,
              ))
              let ty = ast.TTuple(list.map(elements2, tmono.type_of))
              Ok(#(tmono.TTuple(elements2, ty), state))
            }
            False -> mono_expr(state, locals, expr)
          }
        _ -> mono_expr(state, locals, expr)
      }
    }
    _ -> mono_expr(state, locals, expr)
  }
}

/// The inferred type of a typed node, resolved under the current substitution.
fn node_ty(state: State, typed: texpr.TExpr) -> types.Ty {
  types.zonk(texpr.type_of(typed), state.subst)
}

/// Structural equality of two inferred types up to variable renaming (any
/// variable matches any variable; a variable never matches a concrete type).
/// Used by the verification harness to ignore the ids that differ between the
/// elaboration and a re-inference.
fn ty_alpha_equal(a: types.Ty, b: types.Ty) -> Bool {
  case a, b {
    types.Var(_), types.Var(_) -> True
    types.Var(_), types.Rig(_) -> True
    types.Rig(_), types.Var(_) -> True
    types.Rig(_), types.Rig(_) -> True
    types.Con(na, args_a), types.Con(nb, args_b) ->
      na == nb && tys_alpha_equal(args_a, args_b)
    types.Fun(params_a, ret_a), types.Fun(params_b, ret_b) ->
      tys_alpha_equal(params_a, params_b) && ty_alpha_equal(ret_a, ret_b)
    types.Tup(items_a), types.Tup(items_b) -> tys_alpha_equal(items_a, items_b)
    _, _ -> False
  }
}

fn tys_alpha_equal(a: List(types.Ty), b: List(types.Ty)) -> Bool {
  case a, b {
    [], [] -> True
    [x, ..xr], [y, ..yr] -> ty_alpha_equal(x, y) && tys_alpha_equal(xr, yr)
    _, _ -> False
  }
}

/// Read a node's inferred type from its annotation. With `GLEAMC_MONO_VERIFY`
/// set, cross-check against the state-advancing re-inference (`type_of`) and
/// report divergences, falling back to `type_of` to stay correct while the
/// migration proceeds.
fn read_ty(
  state: State,
  locals: Dict(String, Scheme),
  expr: Expr,
  typed: texpr.TExpr,
) -> #(types.Ty, State) {
  case expr {
    EVar(name) ->
      case dict.get(locals, name) {
        // A lambda parameter or local binding: the monomorphised `locals`
        // holds its concrete type, whereas the typed tree may still carry a
        // rigid type variable (e.g. a return-only function type parameter).
        Ok(Scheme(_, ty)) -> #(types.zonk(ty, state.subst), state)
        Error(_) -> read_ty_annotated(state, locals, expr, typed)
      }
    _ -> read_ty_annotated(state, locals, expr, typed)
  }
}

fn read_ty_annotated(
  state: State,
  locals: Dict(String, Scheme),
  expr: Expr,
  typed: texpr.TExpr,
) -> #(types.Ty, State) {
  let annotated = node_ty(state, typed)
  case ffi.get_env("GLEAMC_MONO_VERIFY") {
    Ok(_) -> {
      let #(re_inferred, state2) = type_of(state, locals, expr)
      case ty_alpha_equal(annotated, re_inferred) {
        True -> #(annotated, state2)
        False -> {
          io.println(
            "mono: type divergence: annotated="
            <> types.describe(annotated)
            <> " re-inferred="
            <> types.describe(re_inferred),
          )
          #(re_inferred, state2)
        }
      }
    }
    Error(_) -> #(annotated, state)
  }
}

/// Paired walk: the surface expression together with its typed companion (from
/// the single elaboration). Handled forms read the inferred type from the typed
/// node instead of re-inferring; everything else falls back to the surface walk
/// with the **original** expression (never a round-tripped one).
fn mono_expr_pair(
  state,
  locals,
  expr: Expr,
  typed: Option(texpr.TExpr),
) -> Result(#(tmono.TExpr, State), String) {
  case expr, typed {
    EBinop(op, left, right), Some(texpr.TBinop(_, left_t, right_t, _)) -> {
      use #(left2, state) <- result_try(mono_expr_pair(
        state,
        locals,
        left,
        Some(left_t),
      ))
      let #(left_ty, state) = read_ty(state, locals, left, left_t)
      use #(right2, state) <- result_try(mono_expr_ex_pair(
        state,
        locals,
        Some(left_ty),
        right,
        Some(right_t),
      ))
      Ok(#(tmono.TBinop(op, left2, right2, binop_ty(op)), state))
    }
    EUnop(op, operand), Some(texpr.TUnop(_, operand_t, _)) -> {
      use #(operand2, state) <- result_try(mono_expr_pair(
        state,
        locals,
        operand,
        Some(operand_t),
      ))
      let ty2 = unop_ty(op, tmono.type_of(operand2))
      Ok(#(tmono.TUnop(op, operand2, ty2), state))
    }
    EField(obj, name), Some(texpr.TField(obj_t, _, _)) -> {
      use #(obj2, state) <- result_try(mono_expr_pair(
        state,
        locals,
        obj,
        Some(obj_t),
      ))
      let #(ty2, state) = field_specialised_ty(state, tmono.type_of(obj2), name)
      Ok(#(tmono.TField(obj2, name, ty2), state))
    }
    ETuple(elements), Some(texpr.TTuple(elements_t, _)) -> {
      use #(elements2, state) <- result_try(mono_exprs_pair(
        state,
        locals,
        elements,
        elements_t,
      ))
      let ty2 = ast.TTuple(list.map(elements2, tmono.type_of))
      Ok(#(tmono.TTuple(elements2, ty2), state))
    }
    ELabelled(label, value), Some(texpr.TLabelled(_, value_t, _)) -> {
      use #(value2, state) <- result_try(mono_expr_pair(
        state,
        locals,
        value,
        Some(value_t),
      ))
      Ok(#(tmono.TLabelled(label, value2, tmono.type_of(value2)), state))
    }
    EBitArray(elements), Some(texpr.TBitArray(elements_t, _)) -> {
      use #(elements2, state) <- result_try(mono_exprs_pair(
        state,
        locals,
        elements,
        elements_t,
      ))
      Ok(#(tmono.TBitArray(elements2, ast.TNamed("BitArray")), state))
    }
    ECall(fun, args), Some(texpr.TCall(_, args_t, _)) ->
      mono_call_pair(state, locals, fun, args, args_t, None)
    ECtor(name, args), Some(texpr.TCtor(_, args_t, _)) ->
      mono_ctor_ex_pair(state, locals, name, args, args_t, None)
    ECase(subject, arms), Some(texpr.TCase(subject_t, arms_t, ty)) ->
      mono_case_pair(state, locals, subject, arms, subject_t, arms_t, ty)
    EUpdate(name, base, fields), Some(texpr.TUpdate(_, base_t, fields_t, ty)) ->
      mono_update_pair(
        state,
        locals,
        None,
        name,
        base,
        base_t,
        fields,
        fields_t,
        ty,
      )
    _, _ -> mono_expr(state, locals, expr)
  }
}

/// Like `mono_expr_pair`, but with an expected type for constructors/lambdas.
fn mono_expr_ex_pair(
  state,
  locals,
  expected,
  expr: Expr,
  typed: Option(texpr.TExpr),
) -> Result(#(tmono.TExpr, State), String) {
  case expr, typed {
    EBinop(_, _, _), Some(texpr.TBinop(_, _, _, _)) ->
      mono_expr_pair(state, locals, expr, typed)
    EUnop(_, _), Some(texpr.TUnop(_, _, _)) ->
      mono_expr_pair(state, locals, expr, typed)
    EField(_, _), Some(texpr.TField(_, _, _)) ->
      mono_expr_pair(state, locals, expr, typed)
    EBlock(statements), _ ->
      mono_block_ex_pair(state, locals, expected, statements, typed)
    ELambda(names, body), Some(texpr.TLambda(_, body_t, _)) ->
      lift_lambda(state, locals, names, body, Some(body_t), expected)
    ECall(fun, args), Some(texpr.TCall(_, args_t, _)) ->
      mono_call_pair(state, locals, fun, args, args_t, expected)
    ECtor(name, args), Some(texpr.TCtor(_, args_t, _)) ->
      mono_ctor_ex_pair(state, locals, name, args, args_t, expected)
    ECase(subject, arms), Some(texpr.TCase(subject_t, arms_t, ty)) ->
      mono_case_ex_pair(
        state,
        locals,
        subject,
        arms,
        subject_t,
        arms_t,
        ty,
        expected,
      )
    EUpdate(name, base, fields), Some(texpr.TUpdate(_, base_t, fields_t, ty)) ->
      mono_update_pair(
        state,
        locals,
        expected,
        name,
        base,
        base_t,
        fields,
        fields_t,
        ty,
      )
    _, _ -> mono_expr_ex(state, locals, expected, expr)
  }
}

/// Paired block walk: each statement is monomorphised with its typed
/// companion, so `let` value types are read instead of re-inferred.
fn mono_block_ex_pair(state, locals, expected, statements, typed) {
  case typed {
    Some(texpr.TBlock(typed_statements, _)) ->
      mono_block_ex_pair_acc(
        state,
        locals,
        expected,
        statements,
        typed_statements,
        [],
      )
    _ -> mono_block_ex(state, locals, expected, statements)
  }
}

fn mono_block_ex_pair_acc(
  state,
  locals,
  expected,
  statements,
  typed_statements,
  acc,
) -> Result(#(tmono.TExpr, State), String) {
  case statements, typed_statements {
    [], _ -> Ok(#(tmono.TBlock(list.reverse(acc), ast.TNil), state))
    [Stmt(expr)], [texpr.TStmt(expr_t), ..] -> {
      use #(expr2, state) <- result_try(mono_expr_ex_pair(
        state,
        locals,
        expected,
        expr,
        Some(expr_t),
      ))
      let statements2 = list.reverse([tmono.TStmt(expr2), ..acc])
      Ok(#(tmono.TBlock(statements2, block_ty(statements2)), state))
    }
    [Stmt(expr), ..rest], [texpr.TStmt(expr_t), ..trest] -> {
      use #(expr2, state) <- result_try(mono_expr_pair(
        state,
        locals,
        expr,
        Some(expr_t),
      ))
      mono_block_ex_pair_acc(state, locals, expected, rest, trest, [
        tmono.TStmt(expr2),
        ..acc
      ])
    }
    [Let(pattern, value), ..rest], [texpr.TLet(_, value_t), ..trest] -> {
      let #(declared_ty, state) = read_ty(state, locals, value, value_t)
      use #(value2, state) <- result_try(mono_expr_ex_pair(
        state,
        locals,
        Some(declared_ty),
        value,
        Some(value_t),
      ))
      let #(value_ty, state) = read_ty(state, locals, value, value_t)
      use #(pattern2, bindings, state) <- result_try(mono_pattern(
        state,
        locals,
        pattern,
        value_ty,
      ))
      let locals = merge_dicts(locals, bindings)
      mono_block_ex_pair_acc(state, locals, expected, rest, trest, [
        tmono.TLet(pattern2, value2),
        ..acc
      ])
    }
    _, _ -> mono_block_ex(state, locals, expected, statements)
  }
}

/// Monomorphises tuple elements with the expected element types, so literals
/// like `#([], [])` resolve their element type from the context.
fn mono_exprs_ex(
  state: State,
  locals: Dict(String, Scheme),
  expected_list: List(types.Ty),
  exprs: List(Expr),
) {
  mono_exprs_ex_acc(state, locals, expected_list, exprs, [])
}

fn mono_exprs_ex_acc(
  state: State,
  locals: Dict(String, Scheme),
  expected_list: List(types.Ty),
  exprs: List(Expr),
  acc: List(tmono.TExpr),
) -> Result(#(List(tmono.TExpr), State), String) {
  case exprs, expected_list {
    [], _ -> Ok(#(list.reverse(acc), state))
    [expr, ..rest_exprs], [expected, ..rest_expected] -> {
      use #(expr2, state) <- result_try(mono_expr_ex(
        state,
        locals,
        Some(expected),
        expr,
      ))
      mono_exprs_ex_acc(state, locals, rest_expected, rest_exprs, [expr2, ..acc])
    }
    [expr, ..rest_exprs], [] -> {
      use #(expr2, state) <- result_try(mono_expr(state, locals, expr))
      mono_exprs_ex_acc(state, locals, [], rest_exprs, [expr2, ..acc])
    }
  }
}

/// Turns a reference to a top-level function used as a value into a lambda
/// that calls it (`eta`-expansion), so the existing lambda lifting and
/// specialisation handle it. Requires an expected function type with the
/// same arity.
fn eta_expand(
  state: State,
  locals: Dict(String, Scheme),
  name: String,
  expected: Option(types.Ty),
) -> Result(#(tmono.TExpr, State), String) {
  case dict.get(state.globals, name), expected {
    Ok(scheme), Some(Fun(expected_params, _)) -> {
      let Scheme(_, fun_ty) = scheme
      let #(param_tys, _) = fun_parts(fun_ty)
      case list.length(param_tys) == list.length(expected_params) {
        True -> {
          let names =
            list.index_map(param_tys, fn(_, index) {
              "__fnarg_" <> int.to_string(index)
            })
          let args = list.map(names, fn(param) { EVar(param) })
          mono_expr_ex(
            state,
            locals,
            expected,
            ELambda(names, ECall(EVar(name), args)),
          )
        }
        False -> Error("cannot eta-expand `" <> name <> "`")
      }
    }
    _, _ -> Error("cannot eta-expand `" <> name <> "`")
  }
}

/// Lifts a non-capturing lambda to a top-level function and returns a
/// reference to it (`EVar`). Capturing closures are rejected for now.
fn lift_lambda(
  state: State,
  locals: Dict(String, Scheme),
  names,
  body,
  body_t,
  expected,
) {
  case expected {
    Some(Fun(param_tys, ret_ty)) -> {
      let free = free_var_names(body)
      let captured =
        list.filter(free, fn(name) {
          !list.contains(names, name) && has_binding(locals, name)
        })
      let counter = state.counter
      let fname = "__lambda_" <> int.to_string(counter)
      let state = State(..state, counter: counter + 1)
      use #(param_surfaces, state) <- result_try(mono_types(
        state,
        dict.new(),
        list.map(param_tys, surface_of),
      ))
      use #(_expected_ret, state) <- result_try(mono_type(
        state,
        dict.new(),
        surface_of(ret_ty),
      ))
      let env_ty = "__Env_" <> fname
      let #(with_types, state) =
        list.fold(captured, #([], state), fn(acc, name) {
          let #(pairs, acc_state) = acc
          case
            list.any(pairs, fn(existing) {
              let #(existing_name, _) = existing
              existing_name == name
            })
          {
            True -> acc
            False -> {
              let #(ty, next_state) =
                capture_surface_type(acc_state, locals, name)
              #(list.append(pairs, [#(name, ty)]), next_state)
            }
          }
        })
      let replacements =
        list.fold(
          list.index_map(with_types, fn(pair, index) {
            let #(name, ty) = pair
            #(name, tmono.TEnvGet(env_ty, index, ty))
          }),
          dict.new(),
          fn(acc, pair) {
            let #(name, expr) = pair
            dict.insert(acc, name, expr)
          },
        )
      let captures2 =
        list.map(with_types, fn(pair) {
          let #(name, ty) = pair
          tmono.TVar(name, ty)
        })
      // Captures are locals of the lifted function: the body sees them as
      // ordinary variables, so a nested lambda captures them into its own
      // environment. They are only rewritten to `EEnvGet` after the nested
      // lambdas have been lifted, otherwise the inner function would inherit
      // an `EEnvGet` of the outer `__env` while receiving a different one.
      let param_schemes =
        list.fold(list.zip(names, param_tys), dict.new(), fn(acc, pair) {
          let #(name, ty) = pair
          dict.insert(acc, name, Scheme([], ty))
        })
      let lam_locals =
        list.fold(with_types, param_schemes, fn(acc, pair) {
          let #(name, _) = pair
          case dict.get(locals, name) {
            Ok(scheme) -> dict.insert(acc, name, scheme)
            Error(_) -> acc
          }
        })
      use #(body_mono, state) <- result_try(mono_expr_ex_pair(
        state,
        lam_locals,
        Some(ret_ty),
        body,
        body_t,
      ))
      let body2 = replace_vars(body_mono, replacements)
      // The lambda's return type is its body's type: the expected type may still
      // be an unresolved variable here (e.g. `task.async(fn() { work() })`),
      // which would otherwise default to `Nil`.
      let ret_surface = tmono.type_of(body2)
      let fn_ty = TFun(param_surfaces, ret_surface)
      let env_param = #("__env", TNamed("void*"))
      let fn_def =
        tmono.TFunction(
          False,
          fname,
          [env_param, ..list.zip(names, param_surfaces)],
          ret_surface,
          body2,
          0,
        )
      Ok(#(
        tmono.TClosure("Gleamc_" <> fname, captures2, env_ty, fn_ty, fn_ty),
        State(..state, fn_out: [fn_def, ..state.fn_out]),
      ))
    }
    _ -> Error("lambda requires an expected function type")
  }
}

/// `Ctor(..base, field: value)` desugars to a block that evaluates `base` once
/// and reconstructs the constructor with the updated fields.
fn no_expected_ty() -> Option(types.Ty) {
  None
}

fn mono_update(
  state: State,
  locals,
  expected: Option(types.Ty),
  name,
  base,
  fields,
) {
  case dict.get(state.ctors, name) {
    Error(_) -> Error("unknown record `" <> name <> "`")
    Ok(def) -> {
      let infer.CtorDef(_, field_names, _) = def
      let counter = state.counter
      let temp = "__record_" <> int.to_string(counter)
      let state = State(..state, counter: counter + 1)
      let args =
        list.map(field_names, fn(field_name) {
          case find_update_field(fields, field_name) {
            Ok(value) -> value
            Error(_) -> EField(EVar(temp), field_name)
          }
        })
      let expanded = EBlock([Let(PVar(temp), base), Stmt(ECtor(name, args))])
      mono_expr_ex(state, locals, expected, expanded)
    }
  }
}

/// Paired record update: desugar to a block whose typed companion is built in
/// lockstep, so the walk never re-infers the update.
fn mono_update_pair(
  state: State,
  locals: Dict(String, Scheme),
  expected: Option(types.Ty),
  name: String,
  base: Expr,
  base_t: texpr.TExpr,
  fields: List(#(String, Expr)),
  fields_t: List(#(String, texpr.TExpr)),
  ty,
) {
  case dict.get(state.ctors, name) {
    Error(_) -> Error("unknown record `" <> name <> "`")
    Ok(def) -> {
      let infer.CtorDef(_, field_names, _) = def
      let counter = state.counter
      let temp = "__record_" <> int.to_string(counter)
      let state = State(..state, counter: counter + 1)
      let base_ty = node_ty(state, base_t)
      let #(args, targs, state) =
        list.fold(field_names, #([], [], state), fn(acc, field_name) {
          let #(args, targs, state) = acc
          case find_update_field(fields, field_name) {
            Ok(value) -> {
              let #(value_t, state) = case
                find_update_field_t(fields_t, field_name)
              {
                Ok(found) -> #(found, state)
                Error(_) -> #(texpr.TVar(field_name, base_ty), state)
              }
              #([value, ..args], [value_t, ..targs], state)
            }
            Error(_) -> {
              // Unchanged field: read it back from the bound base. A fresh
              // variable is unified with the constructor parameter by the
              // caller, mirroring the untyped desugaring.
              let #(fresh_ty, counter) = types.fresh(state.counter)
              let state = State(..state, counter: counter)
              let field_t =
                texpr.TField(texpr.TVar(temp, base_ty), field_name, fresh_ty)
              #(
                [EField(EVar(temp), field_name), ..args],
                [field_t, ..targs],
                state,
              )
            }
          }
        })
      let expanded =
        EBlock([Let(PVar(temp), base), Stmt(ECtor(name, list.reverse(args)))])
      let expanded_t =
        texpr.TBlock(
          [
            texpr.TLet(PVar(temp), base_t),
            texpr.TStmt(texpr.TCtor(name, list.reverse(targs), ty)),
          ],
          ty,
        )
      mono_expr_ex_pair(state, locals, expected, expanded, Some(expanded_t))
    }
  }
}

fn find_update_field_t(fields, name) {
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

/// Like `scheme_surface_type`, but specialized: the `EEnvGet` built from it is
/// created after the body has been monomorphised, so it is not passed through
/// `mono_expr` again and must already carry a concrete type.
fn capture_surface_type(state: State, locals, name) -> #(Type, State) {
  let surface = scheme_surface_type(state, locals, name)
  case mono_type(state, dict.new(), surface) {
    Ok(#(specialized, state2)) -> #(specialized, state2)
    Error(_) -> #(surface, state)
  }
}

fn specialize_env_get(state: State, ty) {
  case mono_type(state, dict.new(), ty) {
    Ok(#(specialized, state)) -> Ok(#(specialized, state))
    Error(_) -> Ok(#(ty, state))
  }
}

fn scheme_surface_type(state: State, locals, name) {
  case dict.get(locals, name) {
    Ok(scheme) -> {
      let Scheme(_, ty) = scheme
      surface_of(types.zonk(ty, state.subst))
    }
    Error(_) -> ast.TNil
  }
}

/// Naive simultaneous substitution of variables by expressions (lambda
/// captures). Assumes captured names are not shadowed inside the body.
/// Names bound by a pattern (including `as` and labelled patterns).
fn pattern_names(pattern) -> List(String) {
  case pattern {
    PVar(name) -> [name]
    PAs(inner, name) -> [name, ..pattern_names(inner)]
    PLabelled(_, inner) -> pattern_names(inner)
    PCtor(_, args) -> list.flat_map(args, pattern_names)
    PTuple(patterns) -> list.flat_map(patterns, pattern_names)
    PBitArray(patterns) -> list.flat_map(patterns, pattern_names)
    _ -> []
  }
}

/// Scope-aware simultaneous substitution of captured variables by
/// expressions. Shadowed bindings are left untouched.
fn replace_vars(expr, replacements) {
  replace_vars_bound(expr, replacements, dict.new())
}

fn bind_names(names, bound) {
  list.fold(names, bound, fn(acc, name) { dict.insert(acc, name, True) })
}

fn replace_vars_bound(expr, replacements, bound) {
  case expr {
    tmono.TVar(name, _) ->
      case dict.get(bound, name) {
        Ok(_) -> expr
        Error(_) ->
          case dict.get(replacements, name) {
            Ok(replacement) -> replacement
            Error(_) -> expr
          }
      }
    tmono.TTuple(elements, ty) ->
      tmono.TTuple(
        list.map(elements, fn(e) { replace_vars_bound(e, replacements, bound) }),
        ty,
      )
    tmono.TClosure(code, captures, env_ty, fn_ty, ty) ->
      tmono.TClosure(
        code,
        list.map(captures, fn(e) { replace_vars_bound(e, replacements, bound) }),
        env_ty,
        fn_ty,
        ty,
      )
    tmono.TCtor(name, args, ty) ->
      tmono.TCtor(
        name,
        list.map(args, fn(e) { replace_vars_bound(e, replacements, bound) }),
        ty,
      )
    tmono.TCall(fun, args, ty) ->
      tmono.TCall(
        replace_vars_bound(fun, replacements, bound),
        list.map(args, fn(e) { replace_vars_bound(e, replacements, bound) }),
        ty,
      )
    tmono.TBinop(op, l, r, ty) ->
      tmono.TBinop(
        op,
        replace_vars_bound(l, replacements, bound),
        replace_vars_bound(r, replacements, bound),
        ty,
      )
    tmono.TUnop(op, e, ty) ->
      tmono.TUnop(op, replace_vars_bound(e, replacements, bound), ty)
    tmono.TBlock(statements, ty) ->
      tmono.TBlock(replace_statements(statements, replacements, bound), ty)
    tmono.TCase(subject, arms, ty) ->
      tmono.TCase(
        replace_vars_bound(subject, replacements, bound),
        list.map(arms, fn(arm) {
          let tmono.TArm(pattern, guard, body) = arm
          let inner = bind_names(pattern_names(pattern), bound)
          tmono.TArm(
            pattern,
            replace_opt_bound(guard, replacements, inner),
            replace_vars_bound(body, replacements, inner),
          )
        }),
        ty,
      )
    tmono.TField(obj, name, ty) ->
      tmono.TField(replace_vars_bound(obj, replacements, bound), name, ty)
    tmono.TLabelled(label, value, ty) ->
      tmono.TLabelled(label, replace_vars_bound(value, replacements, bound), ty)
    tmono.TLambda(names, body, ty) ->
      tmono.TLambda(
        names,
        replace_vars_bound(body, replacements, bind_names(names, bound)),
        ty,
      )
    tmono.TUpdate(name, base, fields, ty) ->
      tmono.TUpdate(
        name,
        replace_vars_bound(base, replacements, bound),
        list.map(fields, fn(field) {
          let #(label, value) = field
          #(label, replace_vars_bound(value, replacements, bound))
        }),
        ty,
      )
    tmono.TBitArray(elements, ty) ->
      tmono.TBitArray(
        list.map(elements, fn(e) { replace_vars_bound(e, replacements, bound) }),
        ty,
      )
    _ -> expr
  }
}

fn replace_statements(statements, replacements, bound) {
  case statements {
    [] -> []
    [tmono.TLet(pattern, value), ..rest] -> {
      let value2 = replace_vars_bound(value, replacements, bound)
      let inner = bind_names(pattern_names(pattern), bound)
      [
        tmono.TLet(pattern, value2),
        ..replace_statements(rest, replacements, inner)
      ]
    }
    [tmono.TStmt(expr), ..rest] -> [
      tmono.TStmt(replace_vars_bound(expr, replacements, bound)),
      ..replace_statements(rest, replacements, bound)
    ]
  }
}

fn replace_opt_bound(opt, replacements, bound) {
  case opt {
    Some(expr) -> Some(replace_vars_bound(expr, replacements, bound))
    None -> None
  }
}

fn has_binding(locals, name) {
  case dict.get(locals, name) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn free_var_names(expr) -> List(String) {
  free_var_names_bound(expr, dict.new())
}

fn free_var_names_bound(expr, bound) -> List(String) {
  case expr {
    EVar(name) ->
      case dict.get(bound, name) {
        Ok(_) -> []
        Error(_) -> [name]
      }
    ETuple(elements) ->
      list.flat_map(elements, fn(e) { free_var_names_bound(e, bound) })
    ECtor(_, args) ->
      list.flat_map(args, fn(e) { free_var_names_bound(e, bound) })
    ECall(fun, args) ->
      list.append(
        free_var_names_bound(fun, bound),
        list.flat_map(args, fn(e) { free_var_names_bound(e, bound) }),
      )
    EBinop(_, l, r) ->
      list.append(
        free_var_names_bound(l, bound),
        free_var_names_bound(r, bound),
      )
    EUnop(_, e) -> free_var_names_bound(e, bound)
    EBlock(statements) -> free_var_names_block(statements, bound)
    ECase(subject, arms) ->
      list.append(
        free_var_names_bound(subject, bound),
        list.flat_map(arms, fn(arm) {
          let Arm(pattern, guard, body) = arm
          let inner = bind_names(pattern_names(pattern), bound)
          list.append(
            free_var_names_opt(guard, inner),
            free_var_names_bound(body, inner),
          )
        }),
      )
    EField(obj, _) -> free_var_names_bound(obj, bound)
    ELabelled(_, value) -> free_var_names_bound(value, bound)
    ELambda(names, body) -> free_var_names_bound(body, bind_names(names, bound))
    EUpdate(_, base, fields) ->
      list.append(
        free_var_names_bound(base, bound),
        list.flat_map(fields, fn(field) {
          let #(_, value) = field
          free_var_names_bound(value, bound)
        }),
      )
    EBitArray(elements) ->
      list.flat_map(elements, fn(e) { free_var_names_bound(e, bound) })
    _ -> []
  }
}

fn free_var_names_block(statements, bound) -> List(String) {
  case statements {
    [] -> []
    [Let(pattern, value), ..rest] -> {
      let inner = bind_names(pattern_names(pattern), bound)
      list.append(
        free_var_names_bound(value, bound),
        free_var_names_block(rest, inner),
      )
    }
    [Stmt(expr), ..rest] ->
      list.append(
        free_var_names_bound(expr, bound),
        free_var_names_block(rest, bound),
      )
  }
}

fn free_var_names_opt(opt, bound) -> List(String) {
  case opt {
    Some(expr) -> free_var_names_bound(expr, bound)
    None -> []
  }
}

fn mono_arms_ex(state, locals, subject_ty, result_expected, arms) {
  mono_arms_ex_acc(state, locals, subject_ty, result_expected, arms, [])
}

fn mono_arms_ex_acc(
  state,
  locals,
  subject_ty,
  result_expected,
  arms,
  acc,
) -> Result(#(List(tmono.TArm), State), String) {
  case arms {
    [] -> Ok(#(list.reverse(acc), state))
    [Arm(pattern, guard, body), ..rest] -> {
      use #(pattern2, bindings, state) <- result_try(mono_pattern(
        state,
        locals,
        pattern,
        subject_ty,
      ))
      let arm_locals = merge_dicts(locals, bindings)
      use #(guard2, state) <- result_try(mono_guard(state, arm_locals, guard))
      use #(body2, state) <- result_try(mono_expr_ex(
        state,
        arm_locals,
        result_expected,
        body,
      ))
      mono_arms_ex_acc(state, locals, subject_ty, result_expected, rest, [
        tmono.TArm(pattern2, guard2, body2),
        ..acc
      ])
    }
  }
}

fn mono_block_ex(state, locals, expected, statements) {
  mono_block_ex_acc(state, locals, expected, statements, [])
}

/// Tail-recursive: each statement is monomorphised in tail position and pushed
/// onto the accumulator, so a long block runs in constant stack (the last
/// statement keeps using the block's expected type).
fn mono_block_ex_acc(
  state,
  locals,
  expected,
  statements,
  acc,
) -> Result(#(tmono.TExpr, State), String) {
  case statements {
    [] -> Ok(#(tmono.TBlock(list.reverse(acc), ast.TNil), state))
    [Stmt(expr)] -> {
      use #(expr2, state) <- result_try(mono_expr_ex(
        state,
        locals,
        expected,
        expr,
      ))
      let statements2 = list.reverse([tmono.TStmt(expr2), ..acc])
      Ok(#(tmono.TBlock(statements2, block_ty(statements2)), state))
    }
    [Stmt(expr), ..rest] -> {
      use #(expr2, state) <- result_try(mono_expr(state, locals, expr))
      mono_block_ex_acc(state, locals, expected, rest, [
        tmono.TStmt(expr2),
        ..acc
      ])
    }
    [Let(pattern, value), ..rest] -> {
      let #(declared_ty, state) = type_of(state, locals, value)
      use #(value2, state) <- result_try(mono_expr_ex(
        state,
        locals,
        Some(declared_ty),
        value,
      ))
      let #(value_ty, state) = type_of(state, locals, value)
      use #(pattern2, bindings, state) <- result_try(mono_pattern(
        state,
        locals,
        pattern,
        value_ty,
      ))
      let locals = merge_dicts(locals, bindings)
      mono_block_ex_acc(state, locals, expected, rest, [
        tmono.TLet(pattern2, value2),
        ..acc
      ])
    }
  }
}

fn mono_exprs(
  state: State,
  locals: Dict(String, Scheme),
  exprs: List(Expr),
) -> Result(#(List(tmono.TExpr), State), String) {
  mono_exprs_acc(state, locals, exprs, [])
}

/// Tail-recursive (`list.reverse` at the end) so monomorphising a long list of
/// expressions runs in constant stack.
fn mono_exprs_acc(
  state,
  locals,
  exprs,
  acc,
) -> Result(#(List(tmono.TExpr), State), String) {
  case exprs {
    [] -> Ok(#(list.reverse(acc), state))
    [expr, ..rest] -> {
      use #(expr2, state) <- result_try(mono_expr(state, locals, expr))
      mono_exprs_acc(state, locals, rest, [expr2, ..acc])
    }
  }
}

fn mono_call(
  state: State,
  locals: Dict(String, Scheme),
  fun,
  args,
  expected_opt,
) -> Result(#(tmono.TExpr, State), String) {
  case fun {
    EVar(name) ->
      case dict.get(state.globals, name) {
        Error(_) ->
          case dict.get(locals, name) {
            Error(_) -> {
              use #(args2, state) <- result_try(mono_exprs(state, locals, args))
              Ok(#(
                tmono.TCall(tmono.TVar(name, ast.TNil), args2, ast.TNil),
                state,
              ))
            }
            Ok(scheme) -> {
              // Calling a local function value: use its parameter types as
              // expected types so its arguments resolve (e.g. `None`).
              let #(_, local_ty, counter) =
                types.instantiate_vars(scheme, state.counter)
              let state = State(..state, counter: counter)
              // Resolve the variable first: a function value bound by a
              // pattern carries a unification variable here, and `fun_parts`
              // on the unresolved variable would return the whole type.
              let local_ty = types.zonk(local_ty, state.subst)
              let #(param_tys, local_ret) = fun_parts(local_ty)
              let expected =
                list.map(param_tys, fn(param_ty) {
                  types.zonk(param_ty, state.subst)
                })
              use #(args2, state) <- result_try(mono_args_expect(
                state,
                locals,
                expected,
                args,
              ))
              let #(fn_ty, state) =
                specialised(state, types.zonk(local_ty, state.subst))
              let #(ret_ty, state) =
                specialised(state, types.zonk(local_ret, state.subst))
              Ok(#(tmono.TCall(tmono.TVar(name, fn_ty), args2, ret_ty), state))
            }
          }
        Ok(scheme) -> {
          use #(type_args, state) <- result_try(callee_type_args(
            state,
            locals,
            scheme,
            args,
            expected_opt,
          ))
          let state = request_fn(state, name, type_args)
          let specialized = fn_specialised_name(state, name, type_args)
          let expected = expected_param_tys(state, name, type_args)
          use #(final_args, state) <- result_try(mono_args_expect(
            state,
            locals,
            expected,
            args,
          ))
          let #(fn_ty, state) = fn_specialised_ty(state, name, type_args)
          let ret_ty = case fn_ty {
            ast.TFun(_, ret) -> ret
            _ -> ast.TNil
          }
          Ok(#(
            tmono.TCall(tmono.TVar(specialized, fn_ty), final_args, ret_ty),
            state,
          ))
        }
      }
    _ ->
      case builtin_expect_scheme(state, fun) {
        Ok(scheme) -> {
          let #(_, ty, counter) = types.instantiate_vars(scheme, state.counter)
          let state = State(..state, counter: counter)
          let #(param_tys, ret_t) = fun_parts(ty)
          let expected =
            list.map(param_tys, fn(t) { types.zonk(t, state.subst) })
          use #(args2, state) <- result_try(mono_args_expect(
            state,
            locals,
            expected,
            args,
          ))
          let #(ret_ty, state) =
            specialised(state, types.zonk(ret_t, state.subst))
          use #(callee, state) <- result_try(callee_texpr(state, locals, fun))
          Ok(#(tmono.TCall(callee, args2, ret_ty), state))
        }
        Error(_) -> {
          use #(args2, state) <- result_try(mono_exprs(state, locals, args))
          let arg_tys =
            list.map(args2, fn(arg) { ty_of_surface(tmono.type_of(arg)) })
          let ret_ty = global_call_ret_ty(state, fun, arg_tys, expected_opt)
          use #(callee, state) <- result_try(callee_texpr(state, locals, fun))
          Ok(#(tmono.TCall(callee, args2, ret_ty), state))
        }
      }
  }
}

/// A dotted builtin whose arguments need an expected type (a lambda passed to
/// `process.spawn` / `task.async`), so mono lifts it correctly.
fn builtin_expect_scheme(state: State, fun: Expr) -> Result(Scheme, Nil) {
  case fun {
    EField(EVar(module), name) ->
      case module, name {
        "process", "spawn" -> dict.get(state.globals, "process.spawn")
        "process", "spawn_unlinked" ->
          dict.get(state.globals, "process.spawn_unlinked")
        "task", "async" -> dict.get(state.globals, "task.async")
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// Expected types of a specialised function's parameters, used to resolve
/// constructors that carry no arguments (e.g. `Empty`).
fn expected_param_tys(state: State, name, type_args) -> List(types.Ty) {
  case dict.get(state.surface_fns, name) {
    Error(_) -> []
    Ok(function) -> {
      let Function(_, _, params, _, _, _) = function
      let var_names = function_type_vars(function)
      let surface_map =
        list.fold(list.zip(var_names, type_args), dict.new(), fn(acc, pair) {
          let #(var_name, arg) = pair
          dict.insert(acc, var_name, arg)
        })
      list.map(params, fn(param) {
        let #(_, ty) = param
        ty_of_surface(subst_surface(surface_map, ty))
      })
    }
  }
}

fn mono_args_expect(
  state: State,
  locals: Dict(String, Scheme),
  expected_list: List(types.Ty),
  args: List(Expr),
) {
  // Infer and unify every argument's type with its parameter first, so a
  // nullary constructor or empty collection among the arguments is
  // specialised with a resolved expected type (e.g. `Some(None, 42)`).
  use #(state, _) <- result_try(unify_arg_types(
    state,
    locals,
    expected_list,
    args,
  ))
  mono_args_expect_go(state, locals, expected_list, args, [])
}

fn unify_arg_types(state: State, locals, expected_list, args) {
  case args, expected_list {
    [], _ -> Ok(#(state, Nil))
    [arg, ..rest], [expected, ..rest_expected] -> {
      let #(arg_ty, state) = type_of(state, locals, arg)
      use subst <- result_try(map_unify(
        expected,
        unspecialize_internal(state, arg_ty),
        state.subst,
      ))
      let state = State(..state, subst: subst)
      unify_arg_types(state, locals, rest_expected, rest)
    }
    [arg, ..rest], [] -> {
      let #(_arg_ty, state) = type_of(state, locals, arg)
      unify_arg_types(state, locals, [], rest)
    }
  }
}

fn mono_args_expect_go(state, locals, expected_list, args, acc) {
  case args, expected_list {
    [], _ -> Ok(#(list.reverse(acc), state))
    [arg, ..rest], [expected, ..rest_expected] -> {
      use #(arg2, state) <- result_try(mono_arg_expect(
        state,
        locals,
        expected,
        arg,
      ))
      mono_args_expect_go(state, locals, rest_expected, rest, [arg2, ..acc])
    }
    [arg, ..rest], [] -> {
      use #(arg2, state) <- result_try(mono_expr(state, locals, arg))
      mono_args_expect_go(state, locals, [], rest, [arg2, ..acc])
    }
  }
}

fn mono_arg_expect(
  state: State,
  locals: Dict(String, Scheme),
  expected: types.Ty,
  arg: Expr,
) {
  case arg {
    ECtor(name, ctor_args) ->
      mono_ctor_ex(state, locals, name, ctor_args, Some(expected))
    _ -> mono_expr_ex(state, locals, Some(expected), arg)
  }
}

fn mono_ctor(state: State, locals: Dict(String, Scheme), name, args) {
  mono_ctor_ex(state, locals, name, args, None)
}

fn mono_ctor_ex(state, locals, name, args, expected_opt) {
  case dict.get(state.ctors, name) {
    Error(_) -> Error("unknown constructor `" <> name <> "`")
    Ok(def) -> {
      let infer.CtorDef(type_name, _, scheme) = def
      let #(fresh_vars, fresh_ty, counter) =
        types.instantiate_vars(scheme, state.counter)
      let state = State(..state, counter: counter)
      let #(param_tys, ret) = fun_parts(fresh_ty)
      let subst0 = case expected_opt {
        Some(expected) ->
          case map_unify(ret, expected, state.subst) {
            Ok(subst) -> subst
            Error(_) -> state.subst
          }
        None -> state.subst
      }
      use #(args2, state, subst) <- result_try(mono_ctor_args(
        State(..state, subst: subst0),
        locals,
        param_tys,
        args,
        subst0,
      ))
      let state = State(..state, subst: subst)
      let type_args =
        list.map(fresh_vars, fn(fv) { surface_of(types.zonk(fv, subst)) })
      let #(specialized_type, state) = request_type(state, type_name, type_args)
      let state =
        State(
          ..state,
          ctor_names: dict.insert(
            state.ctor_names,
            ctor_key(type_name, name, type_args),
            ctor_specialised(type_name, name, type_args),
          ),
        )
      let specialized = ctor_specialised_name(state, type_name, name, type_args)
      Ok(#(tmono.TCtor(specialized, args2, ast.TNamed(specialized_type)), state))
    }
  }
}

/// Lowers constructor arguments left to right, propagating the (resolved)
/// expected type of each parameter so nested nullary constructors resolve.
fn mono_ctor_args(state, locals, param_tys, args, subst) {
  mono_ctor_args_acc(state, locals, param_tys, args, subst, [])
}

fn mono_ctor_args_acc(
  state,
  locals,
  param_tys,
  args,
  subst,
  acc,
) -> Result(#(List(tmono.TExpr), State, types.Subst), String) {
  case args, param_tys {
    [], _ -> Ok(#(list.reverse(acc), state, subst))
    [arg, ..rest_args], [param_ty, ..rest_params] -> {
      let expected = types.zonk(param_ty, subst)
      use #(arg2, state) <- result_try(mono_arg_expect(
        state,
        locals,
        expected,
        arg,
      ))
      let #(arg_ty, state) = type_of(state, locals, arg)
      use subst <- result_try(map_unify(
        param_ty,
        unspecialize_internal(state, arg_ty),
        state.subst,
      ))
      let state = State(..state, subst: subst)
      mono_ctor_args_acc(state, locals, rest_params, rest_args, subst, [
        arg2,
        ..acc
      ])
    }
    [arg, ..rest_args], [] -> {
      use #(arg2, state) <- result_try(mono_expr(state, locals, arg))
      mono_ctor_args_acc(state, locals, [], rest_args, subst, [arg2, ..acc])
    }
  }
}

/// Maps a specialised named type back to its generic internal form, so a
/// captured value (an `EEnvGet` carrying a concrete type) can still be unified
/// with a generic callee's parameters.
fn unspecialize_internal(state: State, ty) -> types.Ty {
  case ty {
    Con(name, []) ->
      case dict.get(state.type_generics, name) {
        Ok(surface) -> ty_of_surface(surface)
        Error(_) -> ty
      }
    Con(name, args) ->
      Con(name, list.map(args, fn(arg) { unspecialize_internal(state, arg) }))
    Fun(params, ret) ->
      Fun(
        list.map(params, fn(param) { unspecialize_internal(state, param) }),
        unspecialize_internal(state, ret),
      )
    Tup(items) ->
      Tup(list.map(items, fn(item) { unspecialize_internal(state, item) }))
    _ -> ty
  }
}

fn ctor_specialised(type_name, name, type_args) -> String {
  // `name` is a canonical `alias.Ctor`; the C identifier uses the bare part.
  let base = base_ctor_name(name)
  case type_args {
    [] -> base <> "_" <> type_name
    _ -> base <> "_" <> type_name <> "_" <> mangle_args(type_args)
  }
}

fn base_ctor_name(name) -> String {
  case list.last(string.split(name, ".")) {
    Ok(last) -> last
    Error(_) -> name
  }
}

/// Instantiates a callee scheme and unifies its parameters with the argument
/// types to recover the concrete type arguments.
fn callee_type_args(
  state: State,
  locals: Dict(String, Scheme),
  scheme,
  args,
  expected_opt,
) -> Result(#(List(Type), State), String) {
  let Scheme(vars, _) = scheme
  case vars {
    [] -> Ok(#([], state))
    _ -> {
      let #(fresh_vars, fresh_ty, counter) =
        types.instantiate_vars(scheme, state.counter)
      let #(param_tys, ret) = fun_parts(fresh_ty)
      let state = State(..state, counter: counter)
      let #(arg_tys, state) = arg_types(state, locals, args)
      use subst <- result_try(unify_seq(param_tys, arg_tys, state.subst))
      // The expected return type (when known) helps resolve type arguments
      // that only appear in the result, e.g. `then(.., fn(_) { None })`.
      let subst = case expected_opt {
        Some(expected) ->
          case map_unify(ret, expected, subst) {
            Ok(updated) -> updated
            Error(_) -> subst
          }
        None -> subst
      }
      let state = State(..state, subst: subst)
      let type_args =
        list.map(fresh_vars, fn(fresh_var) { types.zonk(fresh_var, subst) })
      Ok(#(list.map(type_args, surface_of), state))
    }
  }
}

fn arg_types(
  state: State,
  locals: Dict(String, Scheme),
  args,
) -> #(List(types.Ty), State) {
  case args {
    [] -> #([], state)
    [arg, ..rest] -> {
      let #(ty, state) = type_of(state, locals, arg)
      let #(tys, state) = arg_types(state, locals, rest)
      #([unspecialize_internal(state, ty), ..tys], state)
    }
  }
}

fn unify_seq(a, b, subst) {
  case a, b {
    [], [] -> Ok(subst)
    [x, ..xr], [y, ..yr] -> {
      use subst <- result_try(map_unify(x, y, subst))
      unify_seq(xr, yr, subst)
    }
    _, _ -> Error("arity mismatch")
  }
}

fn mono_block(state: State, locals: Dict(String, Scheme), statements) {
  mono_block_acc(state, locals, statements, [])
}

fn mono_block_acc(
  state,
  locals,
  statements,
  acc,
) -> Result(#(tmono.TExpr, State), String) {
  case statements {
    [] -> Ok(#(tmono.TBlock(list.reverse(acc), ast.TNil), state))
    [Stmt(expr)] -> {
      use #(expr2, state) <- result_try(mono_expr(state, locals, expr))
      let statements2 = list.reverse([tmono.TStmt(expr2), ..acc])
      Ok(#(tmono.TBlock(statements2, block_ty(statements2)), state))
    }
    [Stmt(expr), ..rest] -> {
      use #(expr2, state) <- result_try(mono_expr(state, locals, expr))
      mono_block_acc(state, locals, rest, [tmono.TStmt(expr2), ..acc])
    }
    [Let(pattern, value), ..rest] -> {
      let #(declared_ty, state) = type_of(state, locals, value)
      use #(value2, state) <- result_try(mono_expr_ex(
        state,
        locals,
        Some(declared_ty),
        value,
      ))
      let #(value_ty, state) = type_of(state, locals, value)
      use #(pattern2, bindings, state) <- result_try(mono_pattern(
        state,
        locals,
        pattern,
        value_ty,
      ))
      let locals = merge_dicts(locals, bindings)
      mono_block_acc(state, locals, rest, [tmono.TLet(pattern2, value2), ..acc])
    }
  }
}

fn mono_case(
  state: State,
  locals: Dict(String, Scheme),
  subject,
  arms,
) -> Result(#(tmono.TExpr, State), String) {
  use #(subject2, state) <- result_try(mono_expr(state, locals, subject))
  let #(subject_ty, state) = type_of(state, locals, subject)
  use #(arms2, state) <- result_try(mono_arms(state, locals, subject_ty, arms))
  let ty = arms_result_ty(arms2)
  Ok(#(tmono.TCase(subject2, arms2, ty), state))
}

fn mono_arms(state: State, locals: Dict(String, Scheme), subject_ty, arms) {
  mono_arms_acc(state, locals, subject_ty, arms, [])
}

fn mono_arms_acc(
  state,
  locals,
  subject_ty,
  arms,
  acc,
) -> Result(#(List(tmono.TArm), State), String) {
  case arms {
    [] -> Ok(#(list.reverse(acc), state))
    [Arm(pattern, guard, body), ..rest] -> {
      use #(pattern2, bindings, state) <- result_try(mono_pattern(
        state,
        locals,
        pattern,
        subject_ty,
      ))
      let arm_locals = merge_dicts(locals, bindings)
      use #(guard2, state) <- result_try(mono_guard(state, arm_locals, guard))
      use #(body2, state) <- result_try(mono_expr(state, arm_locals, body))
      mono_arms_acc(state, locals, subject_ty, rest, [
        tmono.TArm(pattern2, guard2, body2),
        ..acc
      ])
    }
  }
}

fn mono_guard(state: State, locals: Dict(String, Scheme), guard) {
  case guard {
    None -> Ok(#(None, state))
    Some(expr) -> {
      use #(expr2, state) <- result_try(mono_expr(state, locals, expr))
      Ok(#(Some(expr2), state))
    }
  }
}

/// Rewrites a pattern and returns the local bindings it introduces.
fn mono_pattern(
  state: State,
  locals: Dict(String, Scheme),
  pattern,
  ty,
) -> Result(#(Pattern, Dict(String, Scheme), State), String) {
  case pattern {
    PWildcard | PNil | PInt(_) | PFloat(_) | PString(_) | PBool(_) ->
      Ok(#(pattern, dict.new(), state))
    PVar(name) ->
      Ok(#(pattern, dict.insert(dict.new(), name, Scheme([], ty)), state))
    PAs(inner, name) -> {
      use #(inner2, bindings, state) <- result_try(mono_pattern(
        state,
        locals,
        inner,
        ty,
      ))
      Ok(#(
        PAs(inner2, name),
        dict.insert(bindings, name, Scheme([], ty)),
        state,
      ))
    }
    PTuple(patterns) -> {
      let item_tys = case types.resolve(ty, state.subst) {
        Tup(items) -> items
        _ -> []
      }
      use #(patterns2, bindings, state) <- result_try(mono_patterns(
        state,
        locals,
        patterns,
        item_tys,
      ))
      Ok(#(PTuple(patterns2), bindings, state))
    }
    PCtor(name, args) ->
      case dict.get(state.ctors, name) {
        Error(_) -> Error("unknown constructor `" <> name <> "`")
        Ok(def) -> {
          let infer.CtorDef(type_name, field_names, scheme) = def
          use ordered <- result_try(order_pattern(field_names, name, args))
          let #(fresh_vars, fresh_ty, counter) =
            types.instantiate_vars(scheme, state.counter)
          let state = State(..state, counter: counter)
          let #(param_tys, ret) = fun_parts(fresh_ty)
          use subst <- result_try(map_unify(ret, ty, state.subst))
          let state = State(..state, subst: subst)
          let type_args =
            list.map(fresh_vars, fn(fv) { surface_of(types.zonk(fv, subst)) })
          let #(_specialized_type, state) =
            request_type(state, type_name, type_args)
          let state =
            State(
              ..state,
              ctor_names: dict.insert(
                state.ctor_names,
                ctor_key(type_name, name, type_args),
                ctor_specialised(type_name, name, type_args),
              ),
            )
          let specialized =
            ctor_specialised_name(state, type_name, name, type_args)
          use #(args2, bindings, state) <- result_try(mono_patterns(
            state,
            locals,
            ordered,
            param_tys,
          ))
          Ok(#(PCtor(specialized, args2), bindings, state))
        }
      }
    PLabelled(_, inner) -> mono_pattern(state, locals, inner, ty)
    PBitArray(patterns) -> {
      use #(patterns2, bindings, state) <- result_try(mono_patterns(
        state,
        locals,
        patterns,
        list.repeat(Con("Int", []), list.length(patterns)),
      ))
      Ok(#(PBitArray(patterns2), bindings, state))
    }
  }
}

fn order_pattern(field_names, ctx, args) -> Result(List(Pattern), String) {
  infer.order_pattern(field_names, ctx, args)
}

fn mono_patterns(
  state: State,
  locals: Dict(String, Scheme),
  patterns: List(Pattern),
  tys: List(types.Ty),
) {
  mono_patterns_acc(state, locals, patterns, tys, [], dict.new())
}

fn mono_patterns_acc(
  state: State,
  locals: Dict(String, Scheme),
  patterns: List(Pattern),
  tys: List(types.Ty),
  acc: List(Pattern),
  bindings_acc: Dict(String, Scheme),
) -> Result(#(List(Pattern), Dict(String, Scheme), State), String) {
  case patterns, tys {
    [], _ -> Ok(#(list.reverse(acc), bindings_acc, state))
    [pattern, ..rest_patterns], [ty, ..rest_tys] -> {
      use #(pattern2, bindings1, state) <- result_try(mono_pattern(
        state,
        locals,
        pattern,
        ty,
      ))
      mono_patterns_acc(
        state,
        locals,
        rest_patterns,
        rest_tys,
        [pattern2, ..acc],
        merge_dicts(bindings_acc, bindings1),
      )
    }
    [pattern, ..rest_patterns], [] -> {
      use #(pattern2, bindings1, state) <- result_try(mono_pattern(
        state,
        locals,
        pattern,
        Con("?", []),
      ))
      mono_patterns_acc(
        state,
        locals,
        rest_patterns,
        [],
        [pattern2, ..acc],
        merge_dicts(bindings_acc, bindings1),
      )
    }
  }
}

// ---------------------------------------------------------------------------
// type computation via the HM checker
// ---------------------------------------------------------------------------

fn type_of(
  state: State,
  locals: Dict(String, Scheme),
  expr,
) -> #(types.Ty, State) {
  let env = infer.Env(state.globals, locals, state.ctors, state.types)
  let st = infer.St(state.subst, state.counter)
  case infer.infer(env, st, expr) {
    Ok(#(ty, st2)) -> #(
      types.zonk(ty, st2.subst),
      State(..state, subst: st2.subst, counter: st2.counter),
    )
    Error(_) -> #(Con("?", []), state)
  }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn map_check(result) {
  case result {
    Ok(program) -> Ok(program)
    Error(err) -> Error(describe_infer_error(err))
  }
}

fn describe_infer_error(err) -> String {
  let infer.InferError(message) = err
  message
}

fn order_of(state: State, name: String) -> Int {
  case dict.get(state.type_order, name) {
    Ok(index) -> index
    Error(_) -> 9999
  }
}

fn type_rank(state: State, custom: CustomType) -> Int {
  let CustomType(_, name, _, _, _) = custom
  case dict.get(state.type_rank, name) {
    Ok(rank) -> rank
    Error(_) -> 9999
  }
}

fn map_unify(a, b, subst) {
  case types.unify(a, b, subst) {
    Ok(s) -> Ok(s)
    Error(message) -> Error(message)
  }
}

fn fun_parts(ty) {
  case ty {
    Fun(args, ret) -> #(args, ret)
    _ -> #([], ty)
  }
}

fn ty_of_surface(surface: Type) -> types.Ty {
  case surface {
    ast.TInt -> Con("Int", [])
    ast.TFloat -> Con("Float", [])
    ast.TBool -> Con("Bool", [])
    ast.TString -> Con("String", [])
    ast.TNil -> Con("Nil", [])
    TVar(name) -> Con(name, [])
    TNamed(name) -> Con(name, [])
    TApp(name, args) -> Con(name, list.map(args, ty_of_surface))
    TTuple(items) -> Tup(list.map(items, ty_of_surface))
    TFun(params, ret) ->
      Fun(list.map(params, ty_of_surface), ty_of_surface(ret))
  }
}

fn surface_of(ty: types.Ty) -> Type {
  case ty {
    Con("Int", []) -> ast.TInt
    Con("Float", []) -> ast.TFloat
    Con("Bool", []) -> ast.TBool
    Con("String", []) -> ast.TString
    Con("Nil", []) -> ast.TNil
    Con(name, []) -> TNamed(name)
    Con(name, args) -> TApp(name, list.map(args, surface_of))
    Var(_) -> ast.TNil
    types.Rig(_) -> ast.TNil
    Fun(params, ret) -> TFun(list.map(params, surface_of), surface_of(ret))
    Tup(items) -> TTuple(list.map(items, surface_of))
  }
}

fn mangle_args(args) -> String {
  string.join(list.map(args, mangle_type), "_")
}

fn mangle_type(ty: Type) -> String {
  case ty {
    ast.TInt -> "Int"
    ast.TFloat -> "Float"
    ast.TBool -> "Bool"
    ast.TString -> "String"
    ast.TNil -> "Nil"
    TVar(name) -> name
    TNamed(name) -> name
    TApp(name, args) -> name <> "_" <> mangle_args(args)
    TTuple(items) -> "t" <> mangle_args(items)
    TFun(params, ret) -> "fn_" <> mangle_args(params) <> "_" <> mangle_type(ret)
  }
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

fn type_vars_in(surface: Type) -> List(String) {
  case surface {
    TVar(name) -> [name]
    TApp(_, args) -> list.flat_map(args, type_vars_in)
    TTuple(items) -> list.flat_map(items, type_vars_in)
    TFun(params, ret) ->
      list.append(list.flat_map(params, type_vars_in), type_vars_in(ret))
    _ -> []
  }
}

fn merge_dicts(a, b) {
  dict.fold(b, a, fn(acc, k, v) { dict.insert(acc, k, v) })
}

fn result_try(result, next) {
  case result {
    Ok(value) -> next(value)
    Error(err) -> Error(err)
  }
}

// ---------------------------------------------------------------------------
// paired walk: call / argument / constructor / case
//
// These mirror the surface helpers exactly, but read subexpression types from
// the typed companion (`read_ty`) instead of re-inferring them.
// ---------------------------------------------------------------------------

fn mono_exprs_pair(
  state: State,
  locals: Dict(String, Scheme),
  exprs: List(Expr),
  typed_exprs: List(texpr.TExpr),
) -> Result(#(List(tmono.TExpr), State), String) {
  case list.length(exprs) == list.length(typed_exprs) {
    True -> mono_exprs_pair_zip(state, locals, exprs, typed_exprs, [])
    False -> mono_exprs(state, locals, exprs)
  }
}

fn mono_exprs_pair_zip(
  state: State,
  locals: Dict(String, Scheme),
  exprs: List(Expr),
  typed_exprs: List(texpr.TExpr),
  acc: List(tmono.TExpr),
) -> Result(#(List(tmono.TExpr), State), String) {
  case exprs, typed_exprs {
    [], _ -> Ok(#(list.reverse(acc), state))
    [expr, ..rest], [typed, ..typed_rest] -> {
      use #(expr2, state) <- result_try(mono_expr_pair(
        state,
        locals,
        expr,
        Some(typed),
      ))
      mono_exprs_pair_zip(state, locals, rest, typed_rest, [expr2, ..acc])
    }
    _, _ -> mono_exprs(state, locals, exprs)
  }
}

fn mono_call_pair(
  state: State,
  locals: Dict(String, Scheme),
  fun: Expr,
  args: List(Expr),
  args_t: List(texpr.TExpr),
  expected_opt,
) -> Result(#(tmono.TExpr, State), String) {
  case fun {
    EVar(name) ->
      case dict.get(state.globals, name) {
        Error(_) ->
          case dict.get(locals, name) {
            Error(_) -> {
              use #(args2, state) <- result_try(mono_exprs_pair(
                state,
                locals,
                args,
                args_t,
              ))
              Ok(#(
                tmono.TCall(tmono.TVar(name, ast.TNil), args2, ast.TNil),
                state,
              ))
            }
            Ok(scheme) -> {
              let #(_, local_ty, counter) =
                types.instantiate_vars(scheme, state.counter)
              let state = State(..state, counter: counter)
              // Resolve the variable first: a function value bound by a
              // pattern carries a unification variable here, and `fun_parts`
              // on the unresolved variable would return the whole type.
              let local_ty = types.zonk(local_ty, state.subst)
              let #(param_tys, local_ret) = fun_parts(local_ty)
              let expected =
                list.map(param_tys, fn(param_ty) {
                  types.zonk(param_ty, state.subst)
                })
              use #(args2, state) <- result_try(mono_args_expect_pair(
                state,
                locals,
                expected,
                args,
                args_t,
              ))
              let #(fn_ty, state) =
                specialised(state, types.zonk(local_ty, state.subst))
              let #(ret_ty, state) =
                specialised(state, types.zonk(local_ret, state.subst))
              Ok(#(tmono.TCall(tmono.TVar(name, fn_ty), args2, ret_ty), state))
            }
          }
        Ok(scheme) -> {
          use #(type_args, state) <- result_try(callee_type_args_pair(
            state,
            locals,
            scheme,
            args,
            args_t,
            expected_opt,
          ))
          let state = request_fn(state, name, type_args)
          let specialized = fn_specialised_name(state, name, type_args)
          let expected = expected_param_tys(state, name, type_args)
          use #(final_args, state) <- result_try(mono_args_expect_pair(
            state,
            locals,
            expected,
            args,
            args_t,
          ))
          let #(fn_ty, state) = fn_specialised_ty(state, name, type_args)
          let ret_ty = case fn_ty {
            ast.TFun(_, ret) -> ret
            _ -> ast.TNil
          }
          Ok(#(
            tmono.TCall(tmono.TVar(specialized, fn_ty), final_args, ret_ty),
            state,
          ))
        }
      }
    _ ->
      case builtin_expect_scheme(state, fun) {
        Ok(scheme) -> {
          let #(_, ty, counter) = types.instantiate_vars(scheme, state.counter)
          let state = State(..state, counter: counter)
          let #(param_tys, ret_t) = fun_parts(ty)
          let expected =
            list.map(param_tys, fn(t) { types.zonk(t, state.subst) })
          use #(args2, state) <- result_try(mono_args_expect_pair(
            state,
            locals,
            expected,
            args,
            args_t,
          ))
          let #(ret_ty, state) =
            specialised(state, types.zonk(ret_t, state.subst))
          use #(callee, state) <- result_try(callee_texpr(state, locals, fun))
          Ok(#(tmono.TCall(callee, args2, ret_ty), state))
        }
        Error(_) -> {
          use #(args2, state) <- result_try(mono_exprs_pair(
            state,
            locals,
            args,
            args_t,
          ))
          let arg_tys =
            list.map(args2, fn(arg) { ty_of_surface(tmono.type_of(arg)) })
          let ret_ty = global_call_ret_ty(state, fun, arg_tys, expected_opt)
          use #(callee, state) <- result_try(callee_texpr(state, locals, fun))
          Ok(#(tmono.TCall(callee, args2, ret_ty), state))
        }
      }
  }
}

fn mono_args_expect_pair(
  state: State,
  locals: Dict(String, Scheme),
  expected_list: List(types.Ty),
  args: List(Expr),
  typed_args: List(texpr.TExpr),
) -> Result(#(List(tmono.TExpr), State), String) {
  use #(state, _) <- result_try(unify_arg_types_pair(
    state,
    locals,
    expected_list,
    args,
    typed_args,
  ))
  mono_args_expect_go_pair(state, locals, expected_list, args, typed_args, [])
}

fn unify_arg_types_pair(
  state: State,
  locals: Dict(String, Scheme),
  expected_list: List(types.Ty),
  args: List(Expr),
  typed_args: List(texpr.TExpr),
) {
  case args, expected_list, typed_args {
    [], _, _ -> Ok(#(state, Nil))
    [arg, ..rest], [expected, ..rest_expected], [typed, ..typed_rest] -> {
      let #(arg_ty, state) = read_ty(state, locals, arg, typed)
      use subst <- result_try(map_unify(
        expected,
        unspecialize_internal(state, arg_ty),
        state.subst,
      ))
      let state = State(..state, subst: subst)
      unify_arg_types_pair(state, locals, rest_expected, rest, typed_rest)
    }
    [_arg, ..rest], [], [_, ..typed_rest] ->
      unify_arg_types_pair(state, locals, [], rest, typed_rest)
    _, _, _ -> unify_arg_types(state, locals, expected_list, args)
  }
}

fn mono_args_expect_go_pair(
  state: State,
  locals: Dict(String, Scheme),
  expected_list: List(types.Ty),
  args: List(Expr),
  typed_args: List(texpr.TExpr),
  acc: List(tmono.TExpr),
) -> Result(#(List(tmono.TExpr), State), String) {
  case args, expected_list, typed_args {
    [], _, _ -> Ok(#(list.reverse(acc), state))
    [arg, ..rest], [expected, ..rest_expected], [typed, ..typed_rest] -> {
      use #(arg2, state) <- result_try(mono_arg_expect_pair(
        state,
        locals,
        expected,
        arg,
        typed,
      ))
      mono_args_expect_go_pair(state, locals, rest_expected, rest, typed_rest, [
        arg2,
        ..acc
      ])
    }
    [arg, ..rest], [], [typed, ..typed_rest] -> {
      use #(arg2, state) <- result_try(mono_expr_pair(
        state,
        locals,
        arg,
        Some(typed),
      ))
      mono_args_expect_go_pair(state, locals, [], rest, typed_rest, [
        arg2,
        ..acc
      ])
    }
    _, _, _ -> mono_args_expect_go(state, locals, expected_list, args, acc)
  }
}

fn mono_arg_expect_pair(
  state: State,
  locals: Dict(String, Scheme),
  expected: types.Ty,
  arg: Expr,
  typed: texpr.TExpr,
) {
  case arg, typed {
    ECtor(name, ctor_args), texpr.TCtor(_, ctor_args_t, _) ->
      mono_ctor_ex_pair(
        state,
        locals,
        name,
        ctor_args,
        ctor_args_t,
        Some(expected),
      )
    _, _ -> mono_expr_ex_pair(state, locals, Some(expected), arg, Some(typed))
  }
}

fn callee_type_args_pair(
  state: State,
  locals: Dict(String, Scheme),
  scheme: Scheme,
  args: List(Expr),
  typed_args: List(texpr.TExpr),
  expected_opt,
) {
  let Scheme(vars, _) = scheme
  case vars {
    [] -> Ok(#([], state))
    _ -> {
      let #(fresh_vars, fresh_ty, counter) =
        types.instantiate_vars(scheme, state.counter)
      let #(param_tys, ret) = fun_parts(fresh_ty)
      let state = State(..state, counter: counter)
      let #(arg_tys, state) = arg_types_pair(state, locals, args, typed_args)
      use subst <- result_try(unify_seq(param_tys, arg_tys, state.subst))
      let subst = case expected_opt {
        Some(expected) ->
          case map_unify(ret, expected, subst) {
            Ok(updated) -> updated
            Error(_) -> subst
          }
        None -> subst
      }
      let state = State(..state, subst: subst)
      let type_args =
        list.map(fresh_vars, fn(fresh_var) { types.zonk(fresh_var, subst) })
      Ok(#(list.map(type_args, surface_of), state))
    }
  }
}

fn arg_types_pair(
  state: State,
  locals: Dict(String, Scheme),
  args: List(Expr),
  typed_args: List(texpr.TExpr),
) {
  case args, typed_args {
    [], _ -> #([], state)
    [arg, ..rest], [typed, ..typed_rest] -> {
      let #(arg_ty, state) = read_ty(state, locals, arg, typed)
      let #(tys, state) = arg_types_pair(state, locals, rest, typed_rest)
      #([unspecialize_internal(state, arg_ty), ..tys], state)
    }
    _, _ -> arg_types(state, locals, args)
  }
}

fn mono_ctor_ex_pair(
  state,
  locals,
  name,
  args,
  args_t,
  expected_opt,
) -> Result(#(tmono.TExpr, State), String) {
  case dict.get(state.ctors, name) {
    Error(_) -> Error("unknown constructor `" <> name <> "`")
    Ok(def) -> {
      let infer.CtorDef(type_name, _, scheme) = def
      let #(fresh_vars, fresh_ty, counter) =
        types.instantiate_vars(scheme, state.counter)
      let state = State(..state, counter: counter)
      let #(param_tys, ret) = fun_parts(fresh_ty)
      let subst0 = case expected_opt {
        Some(expected) ->
          case map_unify(ret, expected, state.subst) {
            Ok(subst) -> subst
            Error(_) -> state.subst
          }
        None -> state.subst
      }
      use #(args2, state, subst) <- result_try(mono_ctor_args_pair(
        State(..state, subst: subst0),
        locals,
        param_tys,
        args,
        args_t,
        subst0,
      ))
      let state = State(..state, subst: subst)
      let type_args =
        list.map(fresh_vars, fn(fv) { surface_of(types.zonk(fv, subst)) })
      let #(specialized_type, state) = request_type(state, type_name, type_args)
      let state =
        State(
          ..state,
          ctor_names: dict.insert(
            state.ctor_names,
            ctor_key(type_name, name, type_args),
            ctor_specialised(type_name, name, type_args),
          ),
        )
      let specialized = ctor_specialised_name(state, type_name, name, type_args)
      Ok(#(tmono.TCtor(specialized, args2, ast.TNamed(specialized_type)), state))
    }
  }
}

fn mono_ctor_args_pair(state, locals, param_tys, args, args_t, subst) {
  mono_ctor_args_pair_acc(state, locals, param_tys, args, args_t, subst, [])
}

fn mono_ctor_args_pair_acc(
  state,
  locals,
  param_tys,
  args,
  typed_args,
  subst,
  acc,
) -> Result(#(List(tmono.TExpr), State, types.Subst), String) {
  case args, param_tys, typed_args {
    [], _, _ -> Ok(#(list.reverse(acc), state, subst))
    [arg, ..rest_args], [param_ty, ..rest_params], [typed, ..typed_rest] -> {
      let expected = types.zonk(param_ty, subst)
      use #(arg2, state) <- result_try(mono_arg_expect_pair(
        state,
        locals,
        expected,
        arg,
        typed,
      ))
      let #(arg_ty, state) = read_ty(state, locals, arg, typed)
      use subst <- result_try(map_unify(
        param_ty,
        unspecialize_internal(state, arg_ty),
        state.subst,
      ))
      let state = State(..state, subst: subst)
      mono_ctor_args_pair_acc(
        state,
        locals,
        rest_params,
        rest_args,
        typed_rest,
        subst,
        [arg2, ..acc],
      )
    }
    [arg, ..rest_args], [], [typed, ..typed_rest] -> {
      use #(arg2, state) <- result_try(mono_expr_pair(
        state,
        locals,
        arg,
        Some(typed),
      ))
      mono_ctor_args_pair_acc(state, locals, [], rest_args, typed_rest, subst, [
        arg2,
        ..acc
      ])
    }
    _, _, _ -> mono_ctor_args(state, locals, param_tys, args, subst)
  }
}

/// `case` reached from `mono_expr` (no expected result type): arm bodies use
/// `mono_expr`, exactly like `mono_arms`.
fn mono_case_pair(
  state,
  locals,
  subject,
  arms,
  subject_t,
  arms_t,
  _ty,
) -> Result(#(tmono.TExpr, State), String) {
  use #(subject2, state) <- result_try(mono_expr_pair(
    state,
    locals,
    subject,
    Some(subject_t),
  ))
  let #(subject_ty, state) = read_ty(state, locals, subject, subject_t)
  use #(arms2, state) <- result_try(mono_arms_pair(
    state,
    locals,
    subject_ty,
    arms,
    arms_t,
  ))
  Ok(#(tmono.TCase(subject2, arms2, arms_result_ty(arms2)), state))
}

fn mono_arms_pair(state, locals, subject_ty, arms, typed_arms) {
  mono_arms_pair_acc(state, locals, subject_ty, arms, typed_arms, [])
}

fn mono_arms_pair_acc(state, locals, subject_ty, arms, typed_arms, acc) {
  case arms, typed_arms {
    [], _ -> Ok(#(list.reverse(acc), state))
    [Arm(pattern, guard, body), ..rest],
      [texpr.TArm(_, guard_t, body_t), ..typed_rest]
    -> {
      use #(pattern2, bindings, state) <- result_try(mono_pattern(
        state,
        locals,
        pattern,
        subject_ty,
      ))
      let arm_locals = merge_dicts(locals, bindings)
      use #(guard2, state) <- result_try(mono_guard_pair(
        state,
        arm_locals,
        guard,
        guard_t,
      ))
      use #(body2, state) <- result_try(mono_expr_pair(
        state,
        arm_locals,
        body,
        Some(body_t),
      ))
      mono_arms_pair_acc(state, locals, subject_ty, rest, typed_rest, [
        tmono.TArm(pattern2, guard2, body2),
        ..acc
      ])
    }
    _, _ -> mono_arms(state, locals, subject_ty, arms)
  }
}

/// `case` reached from `mono_expr_ex` (with the case's result expected type):
/// arm bodies use `mono_expr_ex`, exactly like `mono_arms_ex`.
fn mono_case_ex_pair(
  state,
  locals,
  subject,
  arms,
  subject_t,
  arms_t,
  _ty,
  expected,
) -> Result(#(tmono.TExpr, State), String) {
  use #(subject2, state) <- result_try(mono_expr_pair(
    state,
    locals,
    subject,
    Some(subject_t),
  ))
  let #(subject_ty, state) = read_ty(state, locals, subject, subject_t)
  use #(arms2, state) <- result_try(mono_arms_ex_pair(
    state,
    locals,
    subject_ty,
    expected,
    arms,
    arms_t,
  ))
  Ok(#(tmono.TCase(subject2, arms2, arms_result_ty(arms2)), state))
}

fn mono_arms_ex_pair(
  state,
  locals,
  subject_ty,
  result_expected,
  arms,
  typed_arms,
) {
  mono_arms_ex_pair_acc(
    state,
    locals,
    subject_ty,
    result_expected,
    arms,
    typed_arms,
    [],
  )
}

fn mono_arms_ex_pair_acc(
  state,
  locals,
  subject_ty,
  result_expected,
  arms,
  typed_arms,
  acc,
) {
  case arms, typed_arms {
    [], _ -> Ok(#(list.reverse(acc), state))
    [Arm(pattern, guard, body), ..rest],
      [texpr.TArm(_, guard_t, body_t), ..typed_rest]
    -> {
      use #(pattern2, bindings, state) <- result_try(mono_pattern(
        state,
        locals,
        pattern,
        subject_ty,
      ))
      let arm_locals = merge_dicts(locals, bindings)
      use #(guard2, state) <- result_try(mono_guard_pair(
        state,
        arm_locals,
        guard,
        guard_t,
      ))
      use #(body2, state) <- result_try(mono_expr_ex_pair(
        state,
        arm_locals,
        result_expected,
        body,
        Some(body_t),
      ))
      mono_arms_ex_pair_acc(
        state,
        locals,
        subject_ty,
        result_expected,
        rest,
        typed_rest,
        [tmono.TArm(pattern2, guard2, body2), ..acc],
      )
    }
    _, _ -> mono_arms_ex(state, locals, subject_ty, result_expected, arms)
  }
}

fn mono_guard_pair(state, locals, guard, typed_guard) {
  case guard, typed_guard {
    None, _ -> Ok(#(None, state))
    Some(expr), Some(expr_t) -> {
      use #(expr2, state) <- result_try(mono_expr_pair(
        state,
        locals,
        expr,
        Some(expr_t),
      ))
      Ok(#(Some(expr2), state))
    }
    _, _ -> mono_guard(state, locals, guard)
  }
}
