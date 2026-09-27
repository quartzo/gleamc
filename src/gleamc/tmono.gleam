//// The typed monomorphic AST: the product of the monomorphic type layer.
////
//// After monomorphisation the AST is monomorphic, so a node's type is a
//// surface `ast.Type` (no unification variables). The checker elaborates the
//// monomorphic `Expr` into a `TExpr` where every node carries its type;
//// `lower` reads those types instead of re-running `checker.infer`, so the
//// monomorphic module is type-checked exactly once.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleamc/ast

/// A typed monomorphic expression: `expr` plus its `ast.Type`.
pub type TExpr {
  TInt(Int, ast.Type)
  TFloat(Float, ast.Type)
  TString(String, ast.Type)
  TBool(Bool, ast.Type)
  TNil(ast.Type)
  TVar(String, ast.Type)
  TField(TExpr, String, ast.Type)
  TCtor(String, List(TExpr), ast.Type)
  TCall(TExpr, List(TExpr), ast.Type)
  TBinop(String, TExpr, TExpr, ast.Type)
  TUnop(String, TExpr, ast.Type)
  TBlock(List(TStatement), ast.Type)
  TCase(TExpr, List(TArm), ast.Type)
  TTuple(List(TExpr), ast.Type)
  TLabelled(String, TExpr, ast.Type)
  TLambda(List(String), TExpr, ast.Type)
  TClosure(String, List(TExpr), String, ast.Type, ast.Type)
  TEnvGet(String, Int, ast.Type)
  TPanic(String, ast.Type)
  TUpdate(String, TExpr, List(#(String, TExpr)), ast.Type)
  TBitArray(List(TExpr), ast.Type)
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

pub type TModule {
  TModule(List(TDefinition))
}

pub type TDefinition {
  TDFunction(TFunction)
  TDExternal(ast.External)
  TDConst(String, ast.Expr)
  TDCustomType(ast.CustomType)
  TDTypeAlias(Bool, String, List(String), ast.Type)
  TDImport(ast.Import)
}

/// The type carried by a typed expression.
pub fn type_of(expr: TExpr) -> ast.Type {
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

/// Rebuild the surface `Expr` (discarding the types).
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
    TBinop(op, left, right, _) -> ast.EBinop(op, to_expr(left), to_expr(right))
    TUnop(op, operand, _) -> ast.EUnop(op, to_expr(operand))
    TBlock(statements, _) -> ast.EBlock(list.map(statements, to_stmt))
    TCase(subject, arms, _) ->
      ast.ECase(to_expr(subject), list.map(arms, to_arm))
    TTuple(elements, _) -> ast.ETuple(list.map(elements, to_expr))
    TLabelled(name, value, _) -> ast.ELabelled(name, to_expr(value))
    TLambda(names, body, _) -> ast.ELambda(names, to_expr(body))
    TClosure(code, captures, env_ty, fn_ty, _) ->
      ast.EClosure(code, list.map(captures, to_expr), env_ty, fn_ty)
    TEnvGet(env_ty, index, ty) -> ast.EEnvGet(env_ty, index, ty)
    TPanic(message, ty) -> ast.EPanic(message, ty)
    TUpdate(name, base, fields, _) ->
      ast.EUpdate(
        name,
        to_expr(base),
        list.map(fields, fn(field) {
          let #(label, value) = field
          #(label, to_expr(value))
        }),
      )
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
