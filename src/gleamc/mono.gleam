//// Monomorphisation (Stage 3): turns the generic AST into a monomorphic one.
////
//// Generic types and functions are specialised per concrete instantiation,
//// discovered from the entry points by a worklist that reuses the HM checker
//// for type computation. After this pass every `TApp`/`TVar` is gone and
//// constructors/functions have concrete, mangled names, so the existing
//// monomorphic backend (lower + ownership + codegen) can run unchanged.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleamc/ast.{
  type CustomType, type Expr, type Function, type Module, type Pattern,
  type Type, Arm, CustomType, DCustomType, DFunction, EBinop, EBlock, EBool,
  ECall, ECase, EClosure, ECtor, EEnvGet, EField, EFloat, EInt, ELabelled,
  ELambda, ENil, EPanic, EString, ETuple, EUnop, EUpdate, EVar, Function, Let,
  Module, PBool, PCtor, PFloat, PInt, PLabelled, PNil, PString, PTuple, PVar,
  PWildcard, Stmt, TApp, TFun, TNamed, TTuple, TVar, Variant,
}
import gleamc/infer
import gleamc/types.{type Scheme, Con, Fun, Scheme, Tup, Var}

pub fn monomorphize(module: Module) -> Result(Module, String) {
  use program <- result_try(map_check(infer.check(module)))
  let state = initial_state(module, program)
  use state <- result_try(seed(state))
  use state <- result_try(run(state))
  let sorted_types =
    list.sort(state.type_out, fn(a, b) {
      int.compare(type_rank(state, a), type_rank(state, b))
    })
  let type_defs = list.map(sorted_types, fn(custom) { DCustomType(custom) })
  let fn_defs = list.map(state.fn_out, fn(function) { DFunction(function) })
  Ok(Module(list.append(type_defs, list.reverse(fn_defs))))
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
    surface_fns: Dict(String, Function),
    surface_types: Dict(String, CustomType),
    type_order: Dict(String, Int),
    type_rank: Dict(String, Int),
    fn_names: Dict(String, String),
    type_names: Dict(String, String),
    ctor_names: Dict(String, String),
    pending_fn: List(#(String, List(Type))),
    pending_type: List(#(String, List(Type))),
    fn_out: List(Function),
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
          let CustomType(_, name, _, _) = custom
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
            let CustomType(_, name, _, _) = custom
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
    surface_fns: surface_fns,
    surface_types: surface_types,
    type_order: type_order,
    type_rank: dict.new(),
    fn_names: dict.new(),
    type_names: dict.new(),
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
            pending_fn: list.append(state.pending_fn, [#(name, args)]),
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
            pending_fn: list.append(state.pending_fn, [#(name, args)]),
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
        pending_type: list.append(state.pending_type, [#(name, args)]),
      ),
    )
  }
}

fn ctor_specialised_name(state: State, name, args) {
  case dict.get(state.ctor_names, key(name, args)) {
    Ok(specialized) -> specialized
    Error(_) -> name
  }
}

fn key(name, args) -> String {
  name <> "|" <> mangle_args(args)
}

// ---------------------------------------------------------------------------
// specialisation
// ---------------------------------------------------------------------------

/// Substitutes the enclosing type variables, keeping generic applications as
/// `TApp` (internal form used for inference). `mono_type` specialises after.
fn subst_surface(surface_map, ty) -> Type {
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
  case dict.get(state.surface_fns, name) {
    Error(_) -> Ok(state)
    Ok(function) -> {
      let Function(is_pub, _, params, ret, body) = function
      let var_names = function_type_vars(function)
      let surface_map =
        list.fold(list.zip(var_names, type_args), dict.new(), fn(acc, pair) {
          let #(var_name, arg) = pair
          dict.insert(acc, var_name, arg)
        })
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
      let state0 = State(..state, subst: types.empty())
      use #(body2, state1) <- result_try(mono_expr_ex(
        state0,
        locals,
        Some(internal_ret),
        body,
      ))
      let specialized = fn_specialised_name(state1, name, type_args)
      Ok(
        State(..state1, fn_out: [
          Function(is_pub, specialized, params2, ret2, body2),
          ..state1.fn_out
        ]),
      )
    }
  }
}

fn mono_params(state: State, surface_map, params) {
  case params {
    [] -> Ok(#([], state))
    [#(name, ty), ..rest] -> {
      use #(ty2, state) <- result_try(mono_type(state, surface_map, ty))
      use #(rest2, state) <- result_try(mono_params(state, surface_map, rest))
      Ok(#([#(name, ty2), ..rest2], state))
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
      let CustomType(is_pub, _, generics, variants) = custom
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
        type_args,
        surface_map,
        variants,
      ))
      Ok(
        State(..state, type_out: [
          CustomType(is_pub, specialized, [], variants2),
          ..state.type_out
        ]),
      )
    }
  }
}

fn mono_variants(state: State, type_args, surface_map, variants) {
  case variants {
    [] -> Ok(#([], state))
    [Variant(ctor, fields), ..rest] -> {
      let ctor_specialized = ctor_specialised_name(state, ctor, type_args)
      use #(fields2, state) <- result_try(mono_fields(
        state,
        surface_map,
        fields,
      ))
      use #(rest2, state) <- result_try(mono_variants(
        state,
        type_args,
        surface_map,
        rest,
      ))
      Ok(#([Variant(ctor_specialized, fields2), ..rest2], state))
    }
  }
}

fn mono_fields(state: State, surface_map, fields) {
  case fields {
    [] -> Ok(#([], state))
    [#(name, ty), ..rest] -> {
      use #(ty2, state) <- result_try(mono_type(state, surface_map, ty))
      use #(rest2, state) <- result_try(mono_fields(state, surface_map, rest))
      Ok(#([#(name, ty2), ..rest2], state))
    }
  }
}

/// Rewrites a surface type: substitutes the enclosing type variables and
/// specialises generic applications (`Option(Int)` -> `Option_Int`).
fn mono_type(state: State, surface_map, ty) -> Result(#(Type, State), String) {
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
    _ -> Ok(#(ty, state))
  }
}

fn mono_types(state: State, surface_map, types_list) {
  case types_list {
    [] -> Ok(#([], state))
    [ty, ..rest] -> {
      use #(ty2, state) <- result_try(mono_type(state, surface_map, ty))
      use #(rest2, state) <- result_try(mono_types(state, surface_map, rest))
      Ok(#([ty2, ..rest2], state))
    }
  }
}

// ---------------------------------------------------------------------------
// expression rewriting (type-directed)
// ---------------------------------------------------------------------------

fn mono_expr(
  state: State,
  locals: Dict(String, Scheme),
  expr,
) -> Result(#(Expr, State), String) {
  case expr {
    EInt(_) | EFloat(_) | EString(_) | EBool(_) | ENil | EVar(_) ->
      Ok(#(expr, state))
    ELabelled(label, value) -> {
      use #(value2, state) <- result_try(mono_expr(state, locals, value))
      Ok(#(ELabelled(label, value2), state))
    }
    ETuple(elements) -> {
      use #(elements2, state) <- result_try(mono_exprs(state, locals, elements))
      Ok(#(ETuple(elements2), state))
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
      Ok(#(EBinop(op, left2, right2), state))
    }
    EUnop(op, operand) -> {
      use #(operand2, state) <- result_try(mono_expr(state, locals, operand))
      Ok(#(EUnop(op, operand2), state))
    }
    EField(obj, name) -> {
      use #(obj2, state) <- result_try(mono_expr(state, locals, obj))
      Ok(#(EField(obj2, name), state))
    }
    EBlock(statements) -> mono_block(state, locals, statements)
    ECall(fun, args) -> mono_call(state, locals, fun, args, None)
    ECtor(name, args) -> mono_ctor(state, locals, name, args)
    ECase(subject, arms) -> mono_case(state, locals, subject, arms)
    ELambda(_, _) -> Error("lambda requires an expected function type")
    EClosure(_, _, _, _) -> Ok(#(expr, state))
    EEnvGet(_, _, _) -> Ok(#(expr, state))
    EPanic(_, _) -> Ok(#(expr, state))
    EUpdate(name, base, fields) ->
      mono_update(state, locals, None, name, base, fields)
  }
}

/// Like `mono_expr`, but with an expected type used to resolve constructors
/// that carry no arguments.
fn mono_expr_ex(state, locals, expected, expr) {
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
      Ok(#(ECase(subject2, arms2), state))
    }
    EBlock(statements) -> mono_block_ex(state, locals, expected, statements)
    ECall(fun, args) -> mono_call(state, locals, fun, args, expected)
    ELambda(names, body) -> lift_lambda(state, locals, names, body, expected)
    EClosure(_, _, _, _) -> Ok(#(expr, state))
    EEnvGet(_, _, _) -> Ok(#(expr, state))
    EPanic(message, _) -> {
      use #(ty, state) <- result_try(case expected {
        Some(expected_ty) ->
          mono_type(state, dict.new(), surface_of(expected_ty))
        None -> Ok(#(ast.TNil, state))
      })
      Ok(#(EPanic(message, ty), state))
    }
    _ -> mono_expr(state, locals, expr)
  }
}

/// Lifts a non-capturing lambda to a top-level function and returns a
/// reference to it (`EVar`). Capturing closures are rejected for now.
fn lift_lambda(
  state: State,
  locals: Dict(String, Scheme),
  names,
  body,
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
      use #(ret_surface, state) <- result_try(mono_type(
        state,
        dict.new(),
        surface_of(ret_ty),
      ))
      let fn_ty = TFun(param_surfaces, ret_surface)
      use #(body_caps, captures2, env_ty, state) <- result_try(prepare_captures(
        state,
        locals,
        fname,
        captured,
        body,
      ))
      let lam_locals =
        list.fold(list.zip(names, param_tys), dict.new(), fn(acc, pair) {
          let #(name, ty) = pair
          dict.insert(acc, name, Scheme([], ty))
        })
      use #(body2, state) <- result_try(mono_expr_ex(
        state,
        lam_locals,
        Some(ret_ty),
        body_caps,
      ))
      let env_param = #("__env", TNamed("void*"))
      let fn_def =
        Function(
          False,
          fname,
          [env_param, ..list.zip(names, param_surfaces)],
          ret_surface,
          body2,
        )
      Ok(#(
        EClosure("Gleamc_" <> fname, captures2, env_ty, fn_ty),
        State(..state, fn_out: [fn_def, ..state.fn_out]),
      ))
    }
    _ -> Error("lambda requires an expected function type")
  }
}

/// `Ctor(..base, field: value)` desugars to a block that evaluates `base` once
/// and reconstructs the constructor with the updated fields.
fn mono_update(state: State, locals, expected, name, base, fields) {
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

/// Builds the closure environment for the captured variables: allocates a
/// context, rewrites the body to read captures from `__env`, and returns the
/// captured operands plus the environment type name.
fn prepare_captures(state, locals, fname, captured, body) {
  case captured {
    [] -> Ok(#(body, [], "", state))
    _ -> {
      let env_ty = "__Env_" <> fname
      let with_types =
        list.map(captured, fn(name) {
          #(name, scheme_surface_type(locals, name))
        })
      let replacements =
        list.fold(
          list.index_map(with_types, fn(pair, index) {
            let #(name, ty) = pair
            #(name, EEnvGet(env_ty, index, ty))
          }),
          dict.new(),
          fn(acc, pair) {
            let #(name, expr) = pair
            dict.insert(acc, name, expr)
          },
        )
      let body2 = replace_vars(body, replacements)
      let captures =
        list.map(with_types, fn(pair) {
          let #(name, _) = pair
          EVar(name)
        })
      Ok(#(body2, captures, env_ty, state))
    }
  }
}

fn scheme_surface_type(locals, name) {
  case dict.get(locals, name) {
    Ok(scheme) -> {
      let Scheme(_, ty) = scheme
      surface_of(types.zonk(ty, types.empty()))
    }
    Error(_) -> ast.TNil
  }
}

/// Naive simultaneous substitution of variables by expressions (lambda
/// captures). Assumes captured names are not shadowed inside the body.
fn replace_vars(expr, replacements) {
  case expr {
    EVar(name) ->
      case dict.get(replacements, name) {
        Ok(replacement) -> replacement
        Error(_) -> expr
      }
    ETuple(elements) ->
      ETuple(list.map(elements, fn(e) { replace_vars(e, replacements) }))
    EClosure(code, captures, env_ty, fn_ty) ->
      EClosure(
        code,
        list.map(captures, fn(e) { replace_vars(e, replacements) }),
        env_ty,
        fn_ty,
      )
    ECtor(name, args) ->
      ECtor(name, list.map(args, fn(e) { replace_vars(e, replacements) }))
    ECall(fun, args) ->
      ECall(
        replace_vars(fun, replacements),
        list.map(args, fn(e) { replace_vars(e, replacements) }),
      )
    EBinop(op, l, r) ->
      EBinop(op, replace_vars(l, replacements), replace_vars(r, replacements))
    EUnop(op, e) -> EUnop(op, replace_vars(e, replacements))
    EBlock(statements) ->
      EBlock(list.map(statements, fn(s) { replace_stmt(s, replacements) }))
    ECase(subject, arms) ->
      ECase(
        replace_vars(subject, replacements),
        list.map(arms, fn(arm) {
          let Arm(pattern, guard, body) = arm
          Arm(
            pattern,
            replace_opt(guard, replacements),
            replace_vars(body, replacements),
          )
        }),
      )
    EField(obj, name) -> EField(replace_vars(obj, replacements), name)
    ELabelled(label, value) ->
      ELabelled(label, replace_vars(value, replacements))
    ELambda(names, body) -> ELambda(names, replace_vars(body, replacements))
    _ -> expr
  }
}

fn replace_stmt(statement, replacements) {
  case statement {
    Let(pattern, value) -> Let(pattern, replace_vars(value, replacements))
    Stmt(expr) -> Stmt(replace_vars(expr, replacements))
  }
}

fn replace_opt(opt, replacements) {
  case opt {
    Some(expr) -> Some(replace_vars(expr, replacements))
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
  case expr {
    EVar(name) -> [name]
    ETuple(elements) -> list.flat_map(elements, free_var_names)
    ECtor(_, args) -> list.flat_map(args, free_var_names)
    ECall(fun, args) ->
      list.append(free_var_names(fun), list.flat_map(args, free_var_names))
    EBinop(_, l, r) -> list.append(free_var_names(l), free_var_names(r))
    EUnop(_, e) -> free_var_names(e)
    EBlock(statements) -> list.flat_map(statements, free_var_names_stmt)
    ECase(subject, arms) ->
      list.append(
        free_var_names(subject),
        list.flat_map(arms, fn(arm) {
          let Arm(_, guard, body) = arm
          list.append(free_var_names_expr_opt(guard), free_var_names(body))
        }),
      )
    EField(obj, _) -> free_var_names(obj)
    ELabelled(_, value) -> free_var_names(value)
    ELambda(_, body) -> free_var_names(body)
    _ -> []
  }
}

fn free_var_names_stmt(statement) {
  case statement {
    Let(_, value) -> free_var_names(value)
    Stmt(expr) -> free_var_names(expr)
  }
}

fn free_var_names_expr_opt(opt) {
  case opt {
    Some(expr) -> free_var_names(expr)
    None -> []
  }
}

fn mono_arms_ex(state, locals, subject_ty, result_expected, arms) {
  case arms {
    [] -> Ok(#([], state))
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
      use #(rest2, state) <- result_try(mono_arms_ex(
        state,
        locals,
        subject_ty,
        result_expected,
        rest,
      ))
      Ok(#([Arm(pattern2, guard2, body2), ..rest2], state))
    }
  }
}

fn mono_block_ex(state, locals, expected, statements) {
  case statements {
    [] -> Ok(#(EBlock([]), state))
    [Stmt(expr)] -> {
      use #(expr2, state) <- result_try(mono_expr_ex(
        state,
        locals,
        expected,
        expr,
      ))
      Ok(#(EBlock([Stmt(expr2)]), state))
    }
    [Stmt(expr), ..rest] -> {
      use #(expr2, state) <- result_try(mono_expr(state, locals, expr))
      use #(rest2, state) <- result_try(mono_block_ex(
        state,
        locals,
        expected,
        rest,
      ))
      Ok(#(EBlock([Stmt(expr2), ..block_statements(rest2)]), state))
    }
    [Let(pattern, value), ..rest] -> {
      use #(value2, state) <- result_try(mono_expr(state, locals, value))
      let #(value_ty, state) = type_of(state, locals, value)
      use #(pattern2, bindings, state) <- result_try(mono_pattern(
        state,
        locals,
        pattern,
        value_ty,
      ))
      let locals = merge_dicts(locals, bindings)
      use #(rest2, state) <- result_try(mono_block_ex(
        state,
        locals,
        expected,
        rest,
      ))
      Ok(#(EBlock([Let(pattern2, value2), ..block_statements(rest2)]), state))
    }
  }
}

fn mono_exprs(state: State, locals: Dict(String, Scheme), exprs) {
  case exprs {
    [] -> Ok(#([], state))
    [expr, ..rest] -> {
      use #(expr2, state) <- result_try(mono_expr(state, locals, expr))
      use #(rest2, state) <- result_try(mono_exprs(state, locals, rest))
      Ok(#([expr2, ..rest2], state))
    }
  }
}

fn mono_call(
  state: State,
  locals: Dict(String, Scheme),
  fun,
  args,
  expected_opt,
) {
  case fun {
    EVar(name) ->
      case dict.get(state.globals, name) {
        Error(_) -> {
          use #(args2, state) <- result_try(mono_exprs(state, locals, args))
          Ok(#(ECall(EVar(name), args2), state))
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
          Ok(#(ECall(EVar(specialized), final_args), state))
        }
      }
    _ -> {
      use #(args2, state) <- result_try(mono_exprs(state, locals, args))
      Ok(#(ECall(fun, args2), state))
    }
  }
}

/// Expected types of a specialised function's parameters, used to resolve
/// constructors that carry no arguments (e.g. `Empty`).
fn expected_param_tys(state: State, name, type_args) -> List(types.Ty) {
  case dict.get(state.surface_fns, name) {
    Error(_) -> []
    Ok(function) -> {
      let Function(_, _, params, _, _) = function
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

fn mono_args_expect(state: State, locals, expected_list, args) {
  case args, expected_list {
    [], _ -> Ok(#([], state))
    [arg, ..rest], [expected, ..rest_expected] -> {
      use #(arg2, state) <- result_try(mono_arg_expect(
        state,
        locals,
        expected,
        arg,
      ))
      use #(rest2, state) <- result_try(mono_args_expect(
        state,
        locals,
        rest_expected,
        rest,
      ))
      Ok(#([arg2, ..rest2], state))
    }
    [arg, ..rest], [] -> {
      use #(arg2, state) <- result_try(mono_expr(state, locals, arg))
      use #(rest2, state) <- result_try(mono_args_expect(
        state,
        locals,
        [],
        rest,
      ))
      Ok(#([arg2, ..rest2], state))
    }
  }
}

fn mono_arg_expect(state: State, locals, expected, arg) {
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
      let #(_specialized_type, state) =
        request_type(state, type_name, type_args)
      let state =
        State(
          ..state,
          ctor_names: dict.insert(
            state.ctor_names,
            key(name, type_args),
            ctor_specialised(type_name, name, type_args),
          ),
        )
      let specialized = ctor_specialised_name(state, name, type_args)
      Ok(#(ECtor(specialized, args2), state))
    }
  }
}

/// Lowers constructor arguments left to right, propagating the (resolved)
/// expected type of each parameter so nested nullary constructors resolve.
fn mono_ctor_args(state, locals, param_tys, args, subst) {
  case args, param_tys {
    [], _ -> Ok(#([], state, subst))
    [arg, ..rest_args], [param_ty, ..rest_params] -> {
      let expected = types.zonk(param_ty, subst)
      use #(arg2, state) <- result_try(mono_arg_expect(
        state,
        locals,
        expected,
        arg,
      ))
      let #(arg_ty, state) = type_of(state, locals, arg)
      use subst <- result_try(map_unify(param_ty, arg_ty, state.subst))
      let state = State(..state, subst: subst)
      use #(rest2, state, subst) <- result_try(mono_ctor_args(
        state,
        locals,
        rest_params,
        rest_args,
        subst,
      ))
      Ok(#([arg2, ..rest2], state, subst))
    }
    [arg, ..rest_args], [] -> {
      use #(arg2, state) <- result_try(mono_expr(state, locals, arg))
      use #(rest2, state, subst) <- result_try(mono_ctor_args(
        state,
        locals,
        [],
        rest_args,
        subst,
      ))
      Ok(#([arg2, ..rest2], state, subst))
    }
  }
}

fn ctor_specialised(_type_name, name, type_args) -> String {
  case type_args {
    [] -> name
    _ -> name <> "_" <> mangle_args(type_args)
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
      #([ty, ..tys], state)
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
  case statements {
    [] -> Ok(#(EBlock([]), state))
    [Stmt(expr)] -> {
      use #(expr2, state) <- result_try(mono_expr(state, locals, expr))
      Ok(#(EBlock([Stmt(expr2)]), state))
    }
    [Stmt(expr), ..rest] -> {
      use #(expr2, state) <- result_try(mono_expr(state, locals, expr))
      use #(rest2, state) <- result_try(mono_block(state, locals, rest))
      Ok(#(EBlock([Stmt(expr2), ..block_statements(rest2)]), state))
    }
    [Let(pattern, value), ..rest] -> {
      use #(value2, state) <- result_try(mono_expr(state, locals, value))
      let #(value_ty, state) = type_of(state, locals, value)
      use #(pattern2, bindings, state) <- result_try(mono_pattern(
        state,
        locals,
        pattern,
        value_ty,
      ))
      let locals = merge_dicts(locals, bindings)
      use #(rest2, state) <- result_try(mono_block(state, locals, rest))
      Ok(#(EBlock([Let(pattern2, value2), ..block_statements(rest2)]), state))
    }
  }
}

fn block_statements(block) {
  case block {
    EBlock(statements) -> statements
    _ -> []
  }
}

fn mono_case(state: State, locals: Dict(String, Scheme), subject, arms) {
  use #(subject2, state) <- result_try(mono_expr(state, locals, subject))
  let #(subject_ty, state) = type_of(state, locals, subject)
  use #(arms2, state) <- result_try(mono_arms(state, locals, subject_ty, arms))
  Ok(#(ECase(subject2, arms2), state))
}

fn mono_arms(state: State, locals: Dict(String, Scheme), subject_ty, arms) {
  case arms {
    [] -> Ok(#([], state))
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
      use #(rest2, state) <- result_try(mono_arms(
        state,
        locals,
        subject_ty,
        rest,
      ))
      Ok(#([Arm(pattern2, guard2, body2), ..rest2], state))
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
                key(name, type_args),
                ctor_specialised(type_name, name, type_args),
              ),
            )
          let specialized = ctor_specialised_name(state, name, type_args)
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
  }
}

fn order_pattern(field_names, ctx, args) -> Result(List(Pattern), String) {
  infer.order_pattern(field_names, ctx, args)
}

fn mono_patterns(state: State, locals: Dict(String, Scheme), patterns, tys) {
  case patterns, tys {
    [], _ -> Ok(#([], dict.new(), state))
    [pattern, ..rest_patterns], [ty, ..rest_tys] -> {
      use #(pattern2, bindings1, state) <- result_try(mono_pattern(
        state,
        locals,
        pattern,
        ty,
      ))
      use #(rest2, bindings2, state) <- result_try(mono_patterns(
        state,
        locals,
        rest_patterns,
        rest_tys,
      ))
      Ok(#([pattern2, ..rest2], merge_dicts(bindings1, bindings2), state))
    }
    [pattern, ..rest_patterns], [] -> {
      use #(pattern2, bindings1, state) <- result_try(mono_pattern(
        state,
        locals,
        pattern,
        Con("?", []),
      ))
      use #(rest2, bindings2, state) <- result_try(
        mono_patterns(state, locals, rest_patterns, []),
      )
      Ok(#([pattern2, ..rest2], merge_dicts(bindings1, bindings2), state))
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
      ty,
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
  let CustomType(_, name, _, _) = custom
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
