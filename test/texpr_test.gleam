import gleam/dict
import gleamc/ast
import gleamc/infer
import gleamc/texpr
import gleamc/types

fn env() -> infer.Env {
  infer.Env(dict.new(), dict.new(), dict.new(), dict.new())
}

fn infer_expr(expr) {
  let assert Ok(#(typed, _)) =
    infer.infer_t(env(), infer.St(types.empty(), 0), expr)
  typed
}

/// Elaboration attaches the inferred type to every node, so consumers read it
/// instead of re-running inference.
pub fn texpr_binop_carries_types_test() {
  let typed = infer_expr(ast.EBinop("+", ast.EInt(1), ast.EInt(2)))
  let assert texpr.TBinop("+", texpr.TInt(_, left_ty), texpr.TInt(_, right_ty), result_ty) =
    typed
  assert left_ty == types.Con("Int", [])
  assert right_ty == types.Con("Int", [])
  assert result_ty == types.Con("Int", [])
}

/// A nested expression's type is stored at its own node, so no re-inference is
/// needed to recover it.
pub fn texpr_nested_types_test() {
  let typed =
    infer_expr(ast.EBinop("*", ast.EInt(2), ast.EBinop("+", ast.EInt(3), ast.EInt(4))))
  let assert texpr.TBinop(_, _, texpr.TBinop(_, _, _, inner_ty), outer_ty) = typed
  assert inner_ty == types.Con("Int", [])
  assert outer_ty == types.Con("Int", [])
}

/// Strings unify to `String`, evidence the type is inferred not hard-coded.
pub fn texpr_string_concat_test() {
  let typed =
    infer_expr(ast.EBinop("<>", ast.EString("a"), ast.EString("b")))
  assert texpr.type_of(typed) == types.Con("String", [])
}

/// `to_expr` round-trips the surface shape.
pub fn texpr_to_expr_roundtrip_test() {
  let expr = ast.EBinop("+", ast.EInt(1), ast.EInt(2))
  assert texpr.to_expr(infer_expr(expr)) == expr
}
