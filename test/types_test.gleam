import gleamc/types

pub fn unify_same_test() {
  let assert Ok(_) = types.unify(types.int_ty(), types.int_ty(), types.empty())
}

pub fn unify_mismatch_test() {
  let assert Error(_) =
    types.unify(types.int_ty(), types.float_ty(), types.empty())
}

pub fn unify_var_test() {
  let assert Ok(subst) =
    types.unify(types.Var(0), types.int_ty(), types.empty())
  assert types.describe(types.resolve(types.Var(0), subst)) == "Int"
}

pub fn unify_list_test() {
  let assert Ok(subst) =
    types.unify(
      types.list_ty(types.Var(0)),
      types.list_ty(types.int_ty()),
      types.empty(),
    )
  assert types.describe(types.resolve(types.Var(0), subst)) == "Int"
}

pub fn unify_nested_test() {
  let a = types.Con("Result", [types.Var(0), types.Var(1)])
  let b = types.Con("Result", [types.int_ty(), types.string_ty()])
  let assert Ok(subst) = types.unify(a, b, types.empty())
  assert types.describe(types.resolve(types.Var(0), subst)) == "Int"
  assert types.describe(types.resolve(types.Var(1), subst)) == "String"
}

pub fn occurs_check_test() {
  let self = types.Fun([types.Var(0)], types.int_ty())
  let assert Error(_) = types.unify(types.Var(0), self, types.empty())
}

pub fn instantiate_independent_test() {
  // forall a. fn(a) -> a
  let scheme = types.Scheme([0], types.Fun([types.Var(0)], types.Var(0)))
  let #(one, counter) = types.instantiate(scheme, 1)
  let #(two, _) = types.instantiate(scheme, counter)

  let assert Ok(subst1) =
    types.unify(one, types.Fun([types.int_ty()], types.int_ty()), types.empty())
  let assert Ok(subst2) =
    types.unify(
      two,
      types.Fun([types.string_ty()], types.string_ty()),
      types.empty(),
    )
  // both instantiations unified independently, no cross-talk
  assert types.describe(types.zonk(one, subst1)) == "fn(Int) -> Int"
  assert types.describe(types.zonk(two, subst2)) == "fn(String) -> String"
}

pub fn generalize_test() {
  let scheme = types.generalize([], types.Fun([types.Var(0)], types.Var(0)))
  let types.Scheme(vars, _) = scheme
  assert vars == [0]
}

pub fn generalize_respects_env_test() {
  // variable 0 is free in the environment, so it is not generalised
  let scheme = types.generalize([0], types.Fun([types.Var(0)], types.int_ty()))
  let types.Scheme(vars, _) = scheme
  assert vars == []
}

pub fn describe_tuple_test() {
  assert types.describe(types.Tup([types.int_ty(), types.string_ty()]))
    == "#(Int, String)"
}

pub fn free_vars_test() {
  let ty = types.Fun([types.Con("List", [types.Var(0)])], types.Var(1))
  assert types.free_vars(ty) == [0, 1]
}

pub fn rigid_only_matches_itself_test() {
  let assert Ok(_) = types.unify(types.Rig(0), types.Rig(0), types.empty())
}

pub fn rigid_not_concrete_test() {
  // a declared type parameter must not unify with Int
  let assert Error(_) = types.unify(types.Rig(0), types.int_ty(), types.empty())
}

pub fn fresh_var_may_bind_to_rigid_test() {
  let assert Ok(subst) = types.unify(types.Var(5), types.Rig(0), types.empty())
  assert types.describe(types.resolve(types.Var(5), subst)) == "a"
}

pub fn generalize_rigs_test() {
  let scheme = types.generalize_rigs(types.Fun([types.Rig(0)], types.Rig(0)))
  let types.Scheme(vars, _) = scheme
  assert vars == [0]
}
