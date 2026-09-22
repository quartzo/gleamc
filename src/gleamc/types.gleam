//// Real type system foundation: type variables, substitutions, unification
//// with occurs check, generalisation and instantiation. This is the core of
//// a proper Hindley–Milner style checker (generics included), kept separate
//// from the surface `ast.Type`.
////
//// A type is built from constructors (`Con`), unification variables (`Var`),
//// functions (`Fun`) and tuples (`Tup`). `Int`, `Float`, `Bool`, `String` and
//// `Nil` are nullary constructors; `List(a)`, `Result(a, e)` and user types
//// carry arguments.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/string

pub type Ty {
  Con(name: String, args: List(Ty))
  Var(id: Int)
  /// rigid (skolem) variable: a declared type parameter. Unifies only with
  /// itself, so `fn f(x: a) -> Int { x }` is rejected.
  Rig(id: Int)
  Fun(args: List(Ty), ret: Ty)
  Tup(items: List(Ty))
}

/// Substitution from unification variable id to type.
pub type Subst =
  Dict(Int, Ty)

/// A polymorphic type: `vars` are the quantified variable ids.
pub type Scheme {
  Scheme(vars: List(Int), ty: Ty)
}

pub fn empty() -> Subst {
  dict.new()
}

// ---------------------------------------------------------------------------
// concrete helpers
// ---------------------------------------------------------------------------

pub fn int_ty() -> Ty {
  Con("Int", [])
}

pub fn float_ty() -> Ty {
  Con("Float", [])
}

pub fn bool_ty() -> Ty {
  Con("Bool", [])
}

pub fn string_ty() -> Ty {
  Con("String", [])
}

pub fn nil_ty() -> Ty {
  Con("Nil", [])
}

pub fn list_ty(element: Ty) -> Ty {
  Con("List", [element])
}

pub fn con(name: String, args: List(Ty)) -> Ty {
  Con(name, args)
}

// ---------------------------------------------------------------------------
// variables
// ---------------------------------------------------------------------------

pub fn fresh(counter: Int) -> #(Ty, Int) {
  let t = Var(counter)
  #(t, counter + 1)
}

pub fn fresh_many(counter: Int, count: Int) -> #(List(Ty), Int) {
  case count <= 0 {
    True -> #([], counter)
    False -> {
      let #(ty, counter) = fresh(counter)
      let #(rest, counter) = fresh_many(counter, count - 1)
      #([ty, ..rest], counter)
    }
  }
}

/// Follows a variable to its resolved type, if any.
pub fn resolve(ty: Ty, subst: Subst) -> Ty {
  case ty {
    Var(id) ->
      case dict.get(subst, id) {
        Ok(bound) -> resolve(bound, subst)
        Error(_) -> ty
      }
    _ -> ty
  }
}

// ---------------------------------------------------------------------------
// unification
// ---------------------------------------------------------------------------

pub fn unify(a: Ty, b: Ty, subst: Subst) -> Result(Subst, String) {
  let a = resolve(a, subst)
  let b = resolve(b, subst)
  case a, b {
    Var(x), Var(y) ->
      case x == y {
        True -> Ok(subst)
        False -> bind(x, b, subst)
      }
    Var(x), _ -> bind(x, b, subst)
    _, Var(y) -> bind(y, a, subst)
    Rig(x), Rig(y) ->
      case x == y {
        True -> Ok(subst)
        False ->
          Error(
            "cannot unify `" <> describe(a) <> "` with `" <> describe(b) <> "`",
          )
      }
    Rig(_), _ ->
      Error("cannot unify `" <> describe(a) <> "` with `" <> describe(b) <> "`")
    _, Rig(_) ->
      Error("cannot unify `" <> describe(a) <> "` with `" <> describe(b) <> "`")
    Con(x, xs), Con(y, ys) ->
      case x == y {
        True -> unify_lists(xs, ys, subst, x)
        False ->
          Error(
            "cannot unify `" <> describe(a) <> "` with `" <> describe(b) <> "`",
          )
      }
    Fun(xs, xr), Fun(ys, yr) -> {
      use subst <- result_try(unify_lists(xs, ys, subst, "function"))
      unify(xr, yr, subst)
    }
    Tup(xs), Tup(ys) -> unify_lists(xs, ys, subst, "tuple")
    _, _ ->
      Error("cannot unify `" <> describe(a) <> "` with `" <> describe(b) <> "`")
  }
}

fn unify_lists(xs, ys, subst, context) -> Result(Subst, String) {
  case xs, ys {
    [], [] -> Ok(subst)
    [x, ..xr], [y, ..yr] -> {
      use subst <- result_try(unify(x, y, subst))
      unify_lists(xr, yr, subst, context)
    }
    _, _ -> Error("arity mismatch in `" <> context <> "`")
  }
}

fn bind(id: Int, ty: Ty, subst: Subst) -> Result(Subst, String) {
  case occurs(id, ty, subst) {
    True ->
      Error(
        "infinite type: variable `"
        <> describe(Var(id))
        <> "` occurs in `"
        <> describe(ty)
        <> "`",
      )
    False -> Ok(dict.insert(subst, id, ty))
  }
}

fn occurs(id: Int, ty: Ty, subst: Subst) -> Bool {
  case resolve(ty, subst) {
    Var(other) -> other == id
    Rig(_) -> False
    Con(_, args) -> list.any(args, fn(arg) { occurs(id, arg, subst) })
    Fun(args, ret) ->
      list.any(args, fn(arg) { occurs(id, arg, subst) })
      || occurs(id, ret, subst)
    Tup(items) -> list.any(items, fn(item) { occurs(id, item, subst) })
  }
}

// ---------------------------------------------------------------------------
// generalisation / instantiation
// ---------------------------------------------------------------------------

pub fn free_vars(ty: Ty) -> List(Int) {
  case ty {
    Var(id) -> [id]
    Rig(id) -> [id]
    Con(_, args) -> list.flat_map(args, free_vars)
    Fun(args, ret) ->
      list.append(list.flat_map(args, free_vars), free_vars(ret))
    Tup(items) -> list.flat_map(items, free_vars)
  }
}

/// Free rigid variables (declared type parameters).
pub fn free_rigs(ty: Ty) -> List(Int) {
  case ty {
    Rig(id) -> [id]
    Var(_) -> []
    Con(_, args) -> list.flat_map(args, free_rigs)
    Fun(args, ret) ->
      list.append(list.flat_map(args, free_rigs), free_rigs(ret))
    Tup(items) -> list.flat_map(items, free_rigs)
  }
}

/// Quantifies over the rigid variables of a declaration.
pub fn generalize_rigs(ty: Ty) -> Scheme {
  Scheme(dedupe(free_rigs(ty)), ty)
}

/// Quantifies over the free variables of `ty` that are not free in `env`.
pub fn generalize(env_free: List(Int), ty: Ty) -> Scheme {
  let vars =
    list.filter(dedupe(free_vars(ty)), fn(id) { !list.contains(env_free, id) })
  Scheme(vars, ty)
}

/// Replaces each quantified variable with a fresh one.
pub fn instantiate(scheme: Scheme, counter: Int) -> #(Ty, Int) {
  let #(_fresh, ty, counter) = instantiate_vars(scheme, counter)
  #(ty, counter)
}

/// Like `instantiate`, but also returns the fresh variable created for each
/// quantified variable (in the scheme's variable order).
pub fn instantiate_vars(scheme: Scheme, counter: Int) -> #(List(Ty), Ty, Int) {
  let Scheme(vars, ty) = scheme
  let #(mapping, fresh_vars, counter) =
    list.fold(vars, #(dict.new(), [], counter), fn(acc, id) {
      let #(map, fresh_list, counter) = acc
      let #(fresh_ty, counter) = fresh(counter)
      #(
        dict.insert(map, id, fresh_ty),
        list.append(fresh_list, [fresh_ty]),
        counter,
      )
    })
  #(fresh_vars, subst_vars(ty, mapping), counter)
}

fn subst_vars(ty: Ty, mapping) -> Ty {
  case ty {
    Var(id) ->
      case dict.get(mapping, id) {
        Ok(replacement) -> replacement
        Error(_) -> ty
      }
    Rig(id) ->
      case dict.get(mapping, id) {
        Ok(replacement) -> replacement
        Error(_) -> ty
      }
    Con(name, args) ->
      Con(name, list.map(args, fn(arg) { subst_vars(arg, mapping) }))
    Fun(args, ret) ->
      Fun(
        list.map(args, fn(arg) { subst_vars(arg, mapping) }),
        subst_vars(ret, mapping),
      )
    Tup(items) -> Tup(list.map(items, fn(item) { subst_vars(item, mapping) }))
  }
}

/// Applies a substitution to a type (deep resolution).
pub fn zonk(ty: Ty, subst: Subst) -> Ty {
  case resolve(ty, subst) {
    Var(_) as var -> var
    Rig(_) as rig -> rig
    Con(name, args) -> Con(name, list.map(args, fn(arg) { zonk(arg, subst) }))
    Fun(args, ret) ->
      Fun(list.map(args, fn(arg) { zonk(arg, subst) }), zonk(ret, subst))
    Tup(items) -> Tup(list.map(items, fn(item) { zonk(item, subst) }))
  }
}

/// Free variables of every type in a scheme's environment (for generalise).
pub fn env_free_vars(schemes: List(Scheme)) -> List(Int) {
  list.flat_map(schemes, fn(scheme) {
    let Scheme(vars, ty) = scheme
    list.filter(free_vars(ty), fn(id) { !list.contains(vars, id) })
  })
}

// ---------------------------------------------------------------------------
// printing
// ---------------------------------------------------------------------------

pub fn describe(ty: Ty) -> String {
  case ty {
    Con(name, []) -> name
    Con(name, args) ->
      name <> "(" <> string.join(list.map(args, describe), ", ") <> ")"
    Var(id) -> var_name(id)
    Rig(id) -> var_name(id)
    Fun(args, ret) ->
      "fn("
      <> string.join(list.map(args, describe), ", ")
      <> ") -> "
      <> describe(ret)
    Tup(items) -> "#(" <> string.join(list.map(items, describe), ", ") <> ")"
  }
}

/// Human-friendly name for a unification variable (a, b, ..., z, a1, ...).
pub fn var_name(id: Int) -> String {
  let letters = "abcdefghijklmnopqrstuvwxyz"
  let base = case string.slice(letters, id % 26, 1) {
    "" -> "v"
    s -> s
  }
  case id / 26 {
    0 -> base
    n -> base <> int.to_string(n)
  }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

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
