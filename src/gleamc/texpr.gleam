//// The typed AST: the product of the type layer.
////
//// `infer` elaborates the surface `ast.Expr` into a `TExpr` where every node
//// carries its inferred type (`types.Ty`). Downstream passes (`mono`, `dce`,
//// `lower`) read those types instead of re-running inference, so type inference
//// happens once. The surface `Expr` stays as-is for the front-end passes
//// (consts, merge, qualify, aliases) that run before types exist.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleamc/ast
import gleamc/types

/// A typed expression: `expr` plus its inferred type.
pub type TExpr {
  TInt(Int, types.Ty)
  TFloat(Float, types.Ty)
  TString(String, types.Ty)
  TBool(Bool, types.Ty)
  TNil(types.Ty)
  TVar(String, types.Ty)
  TField(TExpr, String, types.Ty)
  TCtor(String, List(TExpr), types.Ty)
  TCall(TExpr, List(TExpr), types.Ty)
  TBinop(String, TExpr, TExpr, types.Ty)
  TUnop(String, TExpr, types.Ty)
  TBlock(List(TStatement), types.Ty)
  TCase(TExpr, List(TArm), types.Ty)
  TTuple(List(TExpr), types.Ty)
  TLabelled(String, TExpr, types.Ty)
  TLambda(List(String), TExpr, types.Ty)
  /// `EClosure(code, captures, env_ty, fn_ty)`.
  TClosure(String, List(TExpr), String, types.Ty, types.Ty)
  /// `EEnvGet(env_ty, index, ty)`.
  TEnvGet(String, Int, types.Ty)
  TPanic(String, types.Ty)
  TUpdate(String, TExpr, List(#(String, TExpr)), types.Ty)
  TBitArray(List(TExpr), types.Ty)
}

pub type TStatement {
  TLet(ast.Pattern, TExpr)
  TStmt(TExpr)
}

pub type TArm {
  TArm(ast.Pattern, Option(TExpr), TExpr)
}

pub type TFunction {
  TFunction(
    is_pub: Bool,
    name: String,
    params: List(#(String, ast.Type)),
    ret: ast.Type,
    body: TExpr,
    line: Int,
  )
}

/// The inferred type of a typed expression.
pub fn type_of(expr: TExpr) -> types.Ty {
  case expr {
    TInt(_, ty) | TFloat(_, ty) | TString(_, ty) | TBool(_, ty) -> ty
    TNil(ty) -> ty
    TVar(_, ty) -> ty
    TField(_, _, ty) -> ty
    TCtor(_, _, ty) -> ty
    TCall(_, _, ty) -> ty
    TBinop(_, _, _, ty) -> ty
    TUnop(_, _, ty) -> ty
    TBlock(_, ty) -> ty
    TCase(_, _, ty) -> ty
    TTuple(_, ty) -> ty
    TLabelled(_, _, ty) -> ty
    TLambda(_, _, ty) -> ty
    TClosure(_, _, _, _, ty) -> ty
    TEnvGet(_, _, ty) -> ty
    TPanic(_, ty) -> ty
    TUpdate(_, _, _, ty) -> ty
    TBitArray(_, ty) -> ty
  }
}

/// Rebuild a surface `Expr` from a typed expression, discarding the types.
pub fn to_expr(expr: TExpr) -> ast.Expr {
  case expr {
    TInt(n, _) -> ast.EInt(n)
    TFloat(f, _) -> ast.EFloat(f)
    TString(s, _) -> ast.EString(s)
    TBool(b, _) -> ast.EBool(b)
    TNil(_) -> ast.ENil
    TVar(name, _) -> ast.EVar(name)
    TField(obj, name, _) -> ast.EField(to_expr(obj), name)
    TCtor(name, args, _) -> ast.ECtor(name, list.map(args, to_expr))
    TCall(fun, args, _) -> ast.ECall(to_expr(fun), list.map(args, to_expr))
    TBinop(op, left, right, _) ->
      ast.EBinop(op, to_expr(left), to_expr(right))
    TUnop(op, operand, _) -> ast.EUnop(op, to_expr(operand))
    TBlock(statements, _) -> ast.EBlock(list.map(statements, to_stmt))
    TCase(subject, arms, _) ->
      ast.ECase(to_expr(subject), list.map(arms, to_arm))
    TTuple(elements, _) -> ast.ETuple(list.map(elements, to_expr))
    TLabelled(name, value, _) -> ast.ELabelled(name, to_expr(value))
    TLambda(names, body, _) -> ast.ELambda(names, to_expr(body))
    TClosure(code, captures, env_ty, fn_ty, _) ->
      ast.EClosure(
        code,
        list.map(captures, to_expr),
        env_ty,
        types_to_surface(fn_ty),
      )
    TEnvGet(env_ty, index, ty) ->
      ast.EEnvGet(env_ty, index, types_to_surface(ty))
    TPanic(message, ty) -> ast.EPanic(message, types_to_surface(ty))
    TUpdate(name, base, fields, _) ->
      ast.EUpdate(name, to_expr(base), list.map(fields, fn(field) {
        let #(label, value) = field
        #(label, to_expr(value))
      }))
    TBitArray(elements, _) -> ast.EBitArray(list.map(elements, to_expr))
  }
}

fn to_stmt(statement: TStatement) -> ast.Statement {
  case statement {
    TLet(pattern, value) -> ast.Let(pattern, to_expr(value))
    TStmt(expr) -> ast.Stmt(to_expr(expr))
  }
}

fn to_arm(arm: TArm) -> ast.Arm {
  let TArm(pattern, guard, body) = arm
  let guard = case guard {
    None -> None
    Some(expr) -> Some(to_expr(expr))
  }
  ast.Arm(pattern, guard, to_expr(body))
}

/// A surface `Type` from an inferred `Ty` (best effort; unresolved variables
/// become `Nil`, matching the monomorphiser's default).
pub fn types_to_surface(ty: types.Ty) -> ast.Type {
  case ty {
    types.Con("Int", []) -> ast.TInt
    types.Con("Float", []) -> ast.TFloat
    types.Con("Bool", []) -> ast.TBool
    types.Con("String", []) -> ast.TString
    types.Con("Nil", []) -> ast.TNil
    types.Con(name, []) -> ast.TNamed(name)
    types.Con(name, args) -> ast.TApp(name, list.map(args, types_to_surface))
    types.Var(_) -> ast.TNil
    types.Rig(_) -> ast.TNil
    types.Fun(params, ret) ->
      ast.TFun(list.map(params, types_to_surface), types_to_surface(ret))
    types.Tup(items) -> ast.TTuple(list.map(items, types_to_surface))
  }
}
