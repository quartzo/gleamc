//// Type checker for the M1/M2 subset.
////
//// Monomorphic by design: function signatures and custom types come fully
//// annotated, and local `let` types are inferred. There are no type
//// variables or generics yet.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleamc/ast.{
  type Expr, type Module, type Pattern, type Type, Arm, CustomType, DConst,
  DCustomType, DExternal, DFunction, DImport, DTypeAlias, EBinop, EBitArray,
  EBlock, EBool, External,
  ECall, ECase, EClosure, ECtor, EEnvGet, EField, EFloat, EInt, ELabelled,
  ELambda, ENil, EPanic, EString, ETuple, EUnop, EUpdate, EVar, Function, Let,
  Module, PAs, PBitArray, PBool, PCtor, PFloat, PInt, PLabelled, PNil, PString,
  PTuple, PVar, PWildcard, Stmt, TApp, TBool, TFloat, TFun, TInt, TNamed, TNil,
  TString, TTuple, TVar, Variant, buffer_elem_name, subject_elem_name,
  task_elem_name, type_of_mangled,
}
import gleamc/tmono

pub type Signature {
  Signature(params: List(#(String, Type)), ret: Type)
}

pub type CtorInfo {
  CtorInfo(type_name: String, fields: List(#(String, Type)))
}

pub type Checked {
  Checked(
    /// The typed monomorphic module produced by the monomorphiser, so
    /// downstream passes read types instead of re-inferring.
    typed: tmono.TModule,
    signatures: Dict(String, Signature),
    ctors: Dict(String, CtorInfo),
  )
}

pub type CheckError {
  CheckError(message: String)
}

pub fn describe_error(err: CheckError) -> String {
  let CheckError(message) = err
  "type error: " <> message
}

/// Elaborate a monomorphic surface module into the typed monomorphic AST.
///
/// This is the single elaboration of the monomorphised program; the
/// monomorphiser calls it and owns the resulting `tmono.TModule`. The
/// pipeline's `check` then only consumes that typed module.
pub fn elaborate(module: Module) -> Result(tmono.TModule, CheckError) {
  let Module(defs) = module
  let #(signatures, ctors) = collect(defs, dict.new(), dict.new())
  case check_defs(defs, signatures, ctors) {
    Ok(typed_defs) -> Ok(tmono.TModule(typed_defs))
    Error(err) -> Error(err)
  }
}

/// Consume an already-typed monomorphic module: collect its signatures and
/// constructors, and check that every `case` is exhaustive. No inference is
/// performed here — every node already carries its type.
pub fn check(module: tmono.TModule) -> Result(Checked, CheckError) {
  let tmono.TModule(defs) = module
  let #(signatures, ctors) = collect_typed(defs, dict.new(), dict.new())
  use _ <- result.try(check_exhaustive_module(defs, ctors))
  Ok(Checked(module, signatures, ctors))
}

fn collect_typed(defs, signatures, ctors) {
  case defs {
    [] -> #(signatures, ctors)
    [tmono.TDFunction(tmono.TFunction(_, name, params, ret, _, _)), ..rest] -> {
      let signatures = dict.insert(signatures, name, Signature(params, ret))
      collect_typed(rest, signatures, ctors)
    }
    [tmono.TDExternal(External(_, name, params, ret, _, _, _)), ..rest] -> {
      let signatures = dict.insert(signatures, name, Signature(params, ret))
      collect_typed(rest, signatures, ctors)
    }
    [tmono.TDCustomType(custom), ..rest] -> {
      let CustomType(_, name, _generics, variants, _) = custom
      let ctors = add_variants(variants, name, ctors)
      collect_typed(rest, signatures, ctors)
    }
    [_, ..rest] -> collect_typed(rest, signatures, ctors)
  }
}

fn check_exhaustive_module(defs, ctors) {
  case defs {
    [] -> Ok(Nil)
    [tmono.TDFunction(function), ..rest] -> {
      use _ <- result.try(check_exhaustive_expr(function.body, ctors))
      check_exhaustive_module(rest, ctors)
    }
    [_, ..rest] -> check_exhaustive_module(rest, ctors)
  }
}

fn check_exhaustive_expr(expr, ctors) -> Result(Nil, CheckError) {
  case expr {
    tmono.TCase(subject, arms, _) -> {
      use _ <- result.try(check_exhaustive_expr(subject, ctors))
      let unguarded =
        list.filter_map(arms, fn(arm) {
          let tmono.TArm(pattern, guard, _) = arm
          case is_none(guard) {
            True -> Ok(pattern)
            False -> Error(Nil)
          }
        })
      use _ <- result.try(exhaustive_patterns(
        tmono.type_of(subject),
        unguarded,
        ctors,
      ))
      check_exhaustive_arms(arms, ctors)
    }
    tmono.TField(obj, _, _) -> check_exhaustive_expr(obj, ctors)
    tmono.TCtor(_, args, _) -> check_exhaustive_exprs(args, ctors)
    tmono.TCall(fun, args, _) -> {
      use _ <- result.try(check_exhaustive_expr(fun, ctors))
      check_exhaustive_exprs(args, ctors)
    }
    tmono.TBinop(_, left, right, _) -> {
      use _ <- result.try(check_exhaustive_expr(left, ctors))
      check_exhaustive_expr(right, ctors)
    }
    tmono.TUnop(_, operand, _) -> check_exhaustive_expr(operand, ctors)
    tmono.TBlock(statements, _) -> check_exhaustive_statements(statements, ctors)
    tmono.TTuple(elements, _) -> check_exhaustive_exprs(elements, ctors)
    tmono.TLabelled(_, value, _) -> check_exhaustive_expr(value, ctors)
    tmono.TLambda(_, body, _) -> check_exhaustive_expr(body, ctors)
    tmono.TClosure(_, captures, _, _, _) -> check_exhaustive_exprs(captures, ctors)
    tmono.TUpdate(_, base, fields, _) -> {
      use _ <- result.try(check_exhaustive_expr(base, ctors))
      check_exhaustive_fields(fields, ctors)
    }
    tmono.TBitArray(elements, _) -> check_exhaustive_exprs(elements, ctors)
    _ -> Ok(Nil)
  }
}

fn check_exhaustive_exprs(exprs, ctors) -> Result(Nil, CheckError) {
  case exprs {
    [] -> Ok(Nil)
    [expr, ..rest] -> {
      use _ <- result.try(check_exhaustive_expr(expr, ctors))
      check_exhaustive_exprs(rest, ctors)
    }
  }
}

fn check_exhaustive_fields(fields, ctors) -> Result(Nil, CheckError) {
  case fields {
    [] -> Ok(Nil)
    [#(_, value), ..rest] -> {
      use _ <- result.try(check_exhaustive_expr(value, ctors))
      check_exhaustive_fields(rest, ctors)
    }
  }
}

fn check_exhaustive_statements(statements, ctors) -> Result(Nil, CheckError) {
  case statements {
    [] -> Ok(Nil)
    [tmono.TLet(_, value), ..rest] -> {
      use _ <- result.try(check_exhaustive_expr(value, ctors))
      check_exhaustive_statements(rest, ctors)
    }
    [tmono.TStmt(expr), ..rest] -> {
      use _ <- result.try(check_exhaustive_expr(expr, ctors))
      check_exhaustive_statements(rest, ctors)
    }
  }
}

fn check_exhaustive_arms(arms, ctors) -> Result(Nil, CheckError) {
  case arms {
    [] -> Ok(Nil)
    [tmono.TArm(_, guard, body), ..rest] -> {
      use _ <- result.try(case guard {
        Some(expr) -> check_exhaustive_expr(expr, ctors)
        None -> Ok(Nil)
      })
      use _ <- result.try(check_exhaustive_expr(body, ctors))
      check_exhaustive_arms(rest, ctors)
    }
  }
}

fn collect(defs, signatures, ctors) {
  case defs {
    [] -> #(signatures, ctors)
    [DFunction(Function(_, name, params, ret, _, _)), ..rest] -> {
      let signatures = dict.insert(signatures, name, Signature(params, ret))
      collect(rest, signatures, ctors)
    }
    [DExternal(External(_, name, params, ret, _, _, _)), ..rest] -> {
      let signatures = dict.insert(signatures, name, Signature(params, ret))
      collect(rest, signatures, ctors)
    }
    [DCustomType(custom), ..rest] -> {
      let CustomType(_, name, _generics, variants, _) = custom
      let ctors = add_variants(variants, name, ctors)
      collect(rest, signatures, ctors)
    }
    [DImport(_), ..rest] -> collect(rest, signatures, ctors)
    [DTypeAlias(_, _, _, _), ..rest] -> collect(rest, signatures, ctors)
    [DConst(_, _), ..rest] -> collect(rest, signatures, ctors)
  }
}

fn check_defs(defs, signatures, ctors) {
  case defs {
    [] -> Ok([])
    [DFunction(function), ..rest] -> {
      use typed <- result.try(check_function(function, signatures, ctors))
      use rest_typed <- result.try(check_defs(rest, signatures, ctors))
      Ok([tmono.TDFunction(typed), ..rest_typed])
    }
    [DExternal(external), ..rest] -> {
      use rest_typed <- result.try(check_defs(rest, signatures, ctors))
      Ok([tmono.TDExternal(external), ..rest_typed])
    }
    [DConst(name, value), ..rest] -> {
      use rest_typed <- result.try(check_defs(rest, signatures, ctors))
      Ok([tmono.TDConst(name, value), ..rest_typed])
    }
    [DCustomType(custom), ..rest] -> {
      use rest_typed <- result.try(check_defs(rest, signatures, ctors))
      Ok([tmono.TDCustomType(custom), ..rest_typed])
    }
    [DTypeAlias(is_pub, name, generics, ty), ..rest] -> {
      use rest_typed <- result.try(check_defs(rest, signatures, ctors))
      Ok([tmono.TDTypeAlias(is_pub, name, generics, ty), ..rest_typed])
    }
    [DImport(imp), ..rest] -> {
      use rest_typed <- result.try(check_defs(rest, signatures, ctors))
      Ok([tmono.TDImport(imp), ..rest_typed])
    }
  }
}

fn add_variants(variants, ctorname, acc) {
  case variants {
    [] -> acc
    [Variant(variant_name, fields), ..rest] ->
      add_variants(
        rest,
        ctorname,
        dict.insert(acc, variant_name, CtorInfo(ctorname, fields)),
      )
  }
}

fn check_function(function, signatures, ctors) -> Result(tmono.TFunction, CheckError) {
  let Function(is_pub, name, params, ret, body, line) = function
  let env =
    list.map(params, fn(param) {
      let #(param_name, ty) = param
      #(param_name, ty)
    })
  use body_t <- result.try(with_function(
    name,
    line,
    elaborate_t(env, signatures, ctors, body),
  ))
  use _ <- result.try(unify(
    ret,
    tmono.type_of(body_t),
    "in function `" <> name <> "`",
  ))
  Ok(tmono.TFunction(is_pub, name, params, ret, body_t, line))
}

fn with_function(name, line, result) {
  case result {
    Error(CheckError(message)) -> Error(CheckError(locate(line, name, message)))
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
// expression inference
// ---------------------------------------------------------------------------

pub type Env =
  List(#(String, Type))

/// Thin wrapper preserving the original `infer` interface: elaborate to a
/// typed monomorphic expression, then project its type.
pub fn infer(
  env: Env,
  signatures: Dict(String, Signature),
  ctors: Dict(String, CtorInfo),
  expr: Expr,
) -> Result(Type, CheckError) {
  use typed <- result.try(elaborate_t(env, signatures, ctors, expr))
  Ok(tmono.type_of(typed))
}

/// Compatibility wrapper around `elaborate_t` for callers that still use the
/// historical name. The monomorphiser's elaboration and the pipeline use
/// `elaborate_t` directly.
pub fn infer_t(
  env: Env,
  signatures: Dict(String, Signature),
  ctors: Dict(String, CtorInfo),
  expr: Expr,
) -> Result(tmono.TExpr, CheckError) {
  elaborate_t(env, signatures, ctors, expr)
}

/// Type-check an expression, elaborating it into a typed monomorphic AST.
fn elaborate_t(
  env: Env,
  signatures: Dict(String, Signature),
  ctors: Dict(String, CtorInfo),
  expr: Expr,
) -> Result(tmono.TExpr, CheckError) {
  case expr {
    EInt(n) -> Ok(tmono.TInt(n, TInt))
    EFloat(f) -> Ok(tmono.TFloat(f, TFloat))
    EString(s) -> Ok(tmono.TString(s, TString))
    EBool(b) -> Ok(tmono.TBool(b, TBool))
    ENil -> Ok(tmono.TNil(TNil))
    EVar(name) ->
      case lookup(env, name) {
        Ok(ty) -> Ok(tmono.TVar(name, ty))
        Error(_) ->
          case dict.get(signatures, name) {
            Ok(Signature(params, ret)) ->
              Ok(tmono.TVar(name, fn_type_of(params, ret)))
            Error(_) -> Error(CheckError("unknown variable `" <> name <> "`"))
          }
      }
    ETuple(elements) -> {
      use typed <- result.try(infer_all(env, signatures, ctors, elements))
      let types = list.map(typed, tmono.type_of)
      Ok(tmono.TTuple(typed, TTuple(types)))
    }
    EUnop(op, operand) -> infer_unop(env, signatures, ctors, op, operand)
    EBinop(op, left, right) ->
      infer_binop(env, signatures, ctors, op, left, right)
    EBlock(statements) -> infer_block(env, signatures, ctors, statements)
    ECase(subject, arms) -> infer_case(env, signatures, ctors, subject, arms)
    ECtor(name, args) -> infer_ctor(env, signatures, ctors, name, args)
    ECall(fun, args) -> infer_call(env, signatures, ctors, fun, args)
    EField(obj, name) -> {
      use obj_t <- result.try(elaborate_t(env, signatures, ctors, obj))
      use field_ty <- result.try(infer_field(tmono.type_of(obj_t), name, ctors))
      Ok(tmono.TField(obj_t, name, field_ty))
    }
    ELabelled(name, value) -> {
      use value_t <- result.try(elaborate_t(env, signatures, ctors, value))
      Ok(tmono.TLabelled(name, value_t, tmono.type_of(value_t)))
    }
    ELambda(_, _) -> Error(CheckError("lambda not lifted before lowering"))
    EClosure(code, captures, env_ty, fn_ty) -> {
      use typed_captures <- result.try(infer_all(
        env,
        signatures,
        ctors,
        captures,
      ))
      Ok(tmono.TClosure(code, typed_captures, env_ty, fn_ty, fn_ty))
    }
    EEnvGet(env_ty, index, ty) -> Ok(tmono.TEnvGet(env_ty, index, ty))
    EPanic(message, ty) -> Ok(tmono.TPanic(message, ty))
    EUpdate(_, _, _) ->
      Error(CheckError("record update must be desugared before checking"))
    EBitArray(elements) -> {
      use typed <- result.try(infer_all(env, signatures, ctors, elements))
      use _ <- result.try(check_types(
        list.repeat(TInt, list.length(typed)),
        list.map(typed, tmono.type_of),
        "bit array segment",
      ))
      Ok(tmono.TBitArray(typed, TNamed("BitArray")))
    }
  }
}

fn infer_field(obj_ty, field_name, ctors) -> Result(Type, CheckError) {
  case obj_ty {
    TNamed(type_name) -> {
      let matches =
        list.filter_map(dict.to_list(ctors), fn(entry) {
          let #(_, info) = entry
          let CtorInfo(name, fields) = info
          case name == type_name {
            True -> list.key_find(fields, field_name)
            False -> Error(Nil)
          }
        })
      case matches {
        [field_ty, ..] -> Ok(field_ty)
        [] ->
          Error(CheckError(
            "type `" <> type_name <> "` has no field `" <> field_name <> "`",
          ))
      }
    }
    _ -> Error(CheckError("field access on `" <> describe_type(obj_ty) <> "`"))
  }
}

fn infer_all(env, signatures, ctors, exprs) {
  case exprs {
    [] -> Ok([])
    [expr, ..rest] -> {
      use typed <- result.try(elaborate_t(env, signatures, ctors, expr))
      use typed_rest <- result.try(infer_all(env, signatures, ctors, rest))
      Ok([typed, ..typed_rest])
    }
  }
}

/// Like `infer_all` but each expression is inferred against the corresponding
/// expected type. Used for labelled constructor fields so a result-polymorphic
/// builtin (`buffer.new`) can adopt its element type from the field.
fn infer_all_expect(env, signatures, ctors, expected, exprs) {
  case expected, exprs {
    [], [] -> Ok([])
    [ty, ..tys], [expr, ..rest] -> {
      use inferred <- result.try(infer_expect(env, signatures, ctors, ty, expr))
      use types <- result.try(infer_all_expect(
        env,
        signatures,
        ctors,
        tys,
        rest,
      ))
      Ok([inferred, ..types])
    }
    _, _ -> infer_all(env, signatures, ctors, exprs)
  }
}

fn infer_expect(env, signatures, ctors, expected, expr) {
  case expr {
    ECall(EField(EVar("buffer"), "new"), args) ->
      case buffer_elem_type(expected) {
        Ok(_) -> {
          use typed_args <- result.try(infer_all(env, signatures, ctors, args))
          use _ <- result.try(check_types(
            [TInt],
            list.map(typed_args, tmono.type_of),
            "in `buffer.new`",
          ))
          Ok(builtin_call("buffer", "new", [TInt], expected, typed_args))
        }
        Error(_) -> elaborate_t(env, signatures, ctors, expr)
      }
    // `process_ffi.new_subject()` is polymorphic; the expected `Subject(elem)` at
    // the call site pins the message type.
    ECall(EField(EVar("process_ffi"), "new_subject"), args) ->
      case subject_elem_type(expected) {
        Ok(_) -> {
          use typed_args <- result.try(infer_all(env, signatures, ctors, args))
          Ok(builtin_call("process_ffi", "new_subject", [], expected, typed_args))
        }
        Error(_) -> elaborate_t(env, signatures, ctors, expr)
      }
    _ -> elaborate_t(env, signatures, ctors, expr)
  }
}

/// The element type of a `Buffer`, in either the surface (`Buffer(a)`) or the
/// monomorphised (`TNamed("Buffer_Int")`) representation.
pub fn buffer_elem_type(ty: Type) -> Result(Type, Nil) {
  case ty {
    TApp("Buffer", [elem]) -> Ok(elem)
    TNamed(name) ->
      case buffer_elem_name(name) {
        Ok(mangled) -> Ok(type_of_mangled(mangled))
        Error(_) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// The message type of a `Subject`, in either the surface (`Subject(a)`) or the
/// monomorphised (`TNamed("Subject_Int")`) representation.
pub fn subject_elem_type(ty: Type) -> Result(Type, Nil) {
  case ty {
    TApp("Subject", [elem]) -> Ok(elem)
    TNamed(name) ->
      case subject_elem_name(name) {
        Ok(mangled) -> Ok(type_of_mangled(mangled))
        Error(_) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// The result type of a `Task`, in either representation.
pub fn task_elem_type(ty: Type) -> Result(Type, Nil) {
  case ty {
    TApp("Task", [elem]) -> Ok(elem)
    TNamed(name) ->
      case task_elem_name(name) {
        Ok(mangled) -> Ok(type_of_mangled(mangled))
        Error(_) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn infer_unop(env, signatures, ctors, op, operand) {
  use operand_t <- result.try(elaborate_t(env, signatures, ctors, operand))
  let ty = tmono.type_of(operand_t)
  case op {
    "-" ->
      case ty {
        TInt -> Ok(tmono.TUnop(op, operand_t, TInt))
        TFloat -> Ok(tmono.TUnop(op, operand_t, TFloat))
        _ ->
          Error(CheckError(
            "`-` expects Int or Float, found `" <> describe_type(ty) <> "`",
          ))
      }
    "-." ->
      case ty {
        TFloat -> Ok(tmono.TUnop(op, operand_t, TFloat))
        _ ->
          Error(CheckError(
            "`-.` expects Float, found `" <> describe_type(ty) <> "`",
          ))
      }
    "!" ->
      case ty {
        TBool -> Ok(tmono.TUnop(op, operand_t, TBool))
        _ ->
          Error(CheckError(
            "`!` expects Bool, found `" <> describe_type(ty) <> "`",
          ))
      }
    _ -> Error(CheckError("unknown unary operator `" <> op <> "`"))
  }
}

fn infer_binop(env, signatures, ctors, op, left, right) {
  use left_t <- result.try(elaborate_t(env, signatures, ctors, left))
  use right_t <- result.try(elaborate_t(env, signatures, ctors, right))
  let left_ty = tmono.type_of(left_t)
  let right_ty = tmono.type_of(right_t)
  let wrap = fn(ty) { tmono.TBinop(op, left_t, right_t, ty) }
  case op {
    "+" | "-" | "*" | "/" | "%" ->
      case left_ty, right_ty {
        TInt, TInt -> Ok(wrap(TInt))
        _, _ ->
          Error(binary_error(op, left_ty, right_ty, "expects Int on both sides"))
      }
    "+." | "-." | "*." | "/." ->
      case left_ty, right_ty {
        TFloat, TFloat -> Ok(wrap(TFloat))
        _, _ ->
          Error(binary_error(
            op,
            left_ty,
            right_ty,
            "expects Float on both sides",
          ))
      }
    "==" | "!=" ->
      case type_equal(left_ty, right_ty) {
        True -> Ok(wrap(TBool))
        False ->
          Error(binary_error(op, left_ty, right_ty, "expects matching sides"))
      }
    "<" | "<=" | ">" | ">=" ->
      case left_ty, right_ty {
        TInt, TInt -> Ok(wrap(TBool))
        _, _ ->
          Error(binary_error(op, left_ty, right_ty, "expects Int on both sides"))
      }
    "<." | "<=." | ">." | ">=." ->
      case left_ty, right_ty {
        TFloat, TFloat -> Ok(wrap(TBool))
        _, _ ->
          Error(binary_error(
            op,
            left_ty,
            right_ty,
            "expects Float on both sides",
          ))
      }
    "<>" ->
      case left_ty, right_ty {
        TString, TString -> Ok(wrap(TString))
        _, _ ->
          Error(binary_error(
            op,
            left_ty,
            right_ty,
            "expects String on both sides",
          ))
      }
    "&&" | "||" ->
      case left_ty, right_ty {
        TBool, TBool -> Ok(wrap(TBool))
        _, _ ->
          Error(binary_error(
            op,
            left_ty,
            right_ty,
            "expects Bool on both sides",
          ))
      }
    _ -> Error(CheckError("unknown operator `" <> op <> "`"))
  }
}

fn binary_error(op, left_ty, right_ty, hint) {
  CheckError(
    "operator `"
    <> op
    <> "` "
    <> hint
    <> ", found `"
    <> describe_type(left_ty)
    <> "` and `"
    <> describe_type(right_ty)
    <> "`",
  )
}

fn infer_block(env, signatures, ctors, statements) {
  case statements {
    [] -> Ok(tmono.TBlock([], TNil))
    [Stmt(expr)] -> {
      use expr_t <- result.try(elaborate_t(env, signatures, ctors, expr))
      Ok(tmono.TBlock([tmono.TStmt(expr_t)], tmono.type_of(expr_t)))
    }
    [Let(pattern, value), ..rest] -> {
      use value_t <- result.try(elaborate_t(env, signatures, ctors, value))
      use bindings <- result.try(bind_pattern(pattern, tmono.type_of(value_t), ctors))
      infer_block_prepend(
        tmono.TLet(pattern, value_t),
        list.append(bindings, env),
        signatures,
        ctors,
        rest,
      )
    }
    [Stmt(expr), ..rest] -> {
      use expr_t <- result.try(elaborate_t(env, signatures, ctors, expr))
      infer_block_prepend(
        tmono.TStmt(expr_t),
        env,
        signatures,
        ctors,
        rest,
      )
    }
  }
}

fn infer_block_prepend(statement, env, signatures, ctors, rest) {
  use rest_t <- result.try(infer_block(env, signatures, ctors, rest))
  let assert tmono.TBlock(statements, ty) = rest_t
  Ok(tmono.TBlock([statement, ..statements], ty))
}

fn infer_case(env, signatures, ctors, subject, arms) {
  use subject_t <- result.try(elaborate_t(env, signatures, ctors, subject))
  let subject_ty = tmono.type_of(subject_t)
  use inferred <- result.try(infer_arms(
    env,
    signatures,
    ctors,
    subject_ty,
    arms,
    None,
  ))
  let #(typed_arms, result_ty) = inferred
  Ok(tmono.TCase(subject_t, typed_arms, result_ty))
}

// ---------------------------------------------------------------------------
// exhaustiveness
// ---------------------------------------------------------------------------

fn exhaustive_patterns(subject_ty, unguarded, ctors) {
  case patterns_exhaustive(subject_ty, unguarded, ctors) {
    True -> Ok(Nil)
    False -> Error(CheckError("non-exhaustive `case` (add a `_` arm)"))
  }
}

fn strip_as(pattern) {
  case pattern {
    PAs(inner, _) -> strip_as(inner)
    _ -> pattern
  }
}

fn patterns_exhaustive(ty, patterns, ctors) -> Bool {
  let patterns = list.map(patterns, strip_as)
  case list.any(patterns, pattern_irrefutable) {
    True -> True
    False ->
      case ty {
        TNamed(name) -> type_exhaustive(name, patterns, ctors)
        TBool -> has_bool(patterns, True) && has_bool(patterns, False)
        TTuple(types) -> tuple_exhaustive(types, patterns, ctors)
        _ -> False
      }
  }
}

/// A tuple case is exhaustive only if each column is exhaustive: projecting a
/// cover of the product onto a coordinate always covers that coordinate, so
/// this never rejects a truly exhaustive case (it may accept some that are).
fn tuple_exhaustive(types, patterns, ctors) -> Bool {
  list.all(types |> list.index_map(fn(ty, index) { #(ty, index) }), fn(pair) {
    let #(ty, index) = pair
    let column =
      list.map(patterns, fn(pattern) { column_pattern(pattern, index) })
    patterns_exhaustive(ty, column, ctors)
  })
}

fn column_pattern(pattern, index) -> Pattern {
  case pattern {
    PAs(inner, _) -> column_pattern(inner, index)
    PTuple(items) ->
      case list_at(items, index) {
        Ok(inner) -> inner
        Error(_) -> PWildcard
      }
    _ -> PWildcard
  }
}

fn list_at(items, index) {
  case items, index {
    [], _ -> Error(Nil)
    [item, ..], 0 -> Ok(item)
    [_, ..rest], n -> list_at(rest, n - 1)
  }
}

fn type_exhaustive(name, patterns, ctors) -> Bool {
  let variants = variants_of(name, ctors)
  list.all(variants, fn(variant) {
    let #(variant_name, field_types) = variant
    let args_of =
      list.filter_map(patterns, fn(pattern) {
        case strip_as(pattern) {
          PCtor(ctor, args) ->
            case ctor == variant_name {
              True -> Ok(args)
              False -> Error(Nil)
            }
          _ -> Error(Nil)
        }
      })
    variant_covered(args_of, field_types, ctors)
  })
}

fn variant_covered(args_of, field_types, ctors) -> Bool {
  case args_of {
    [] -> False
    _ ->
      case field_types {
        [] -> True
        _ ->
          // Column-wise, like tuples: each field must be exhaustive across
          // the constructor's argument patterns. Conservative (may accept
          // some non-exhaustive cases) but never rejects an exhaustive one.
          list.all(
            list.index_map(field_types, fn(ty, index) { #(ty, index) }),
            fn(pair) {
              let #(ty, index) = pair
              patterns_exhaustive(
                ty,
                list.map(args_of, fn(args) { arg_at(args, index) }),
                ctors,
              )
            },
          )
      }
  }
}

fn arg_at(args, index) {
  case list_at(args, index) {
    Ok(pattern) -> pattern
    Error(_) -> PWildcard
  }
}

fn variants_of(name, ctors) -> List(#(String, List(Type))) {
  list.filter_map(dict.to_list(ctors), fn(entry) {
    let #(ctor, info) = entry
    let CtorInfo(type_name, fields) = info
    case type_name == name {
      True ->
        Ok(#(
          ctor,
          list.map(fields, fn(field) {
            let #(_, field_ty) = field
            field_ty
          }),
        ))
      False -> Error(Nil)
    }
  })
}

fn has_bool(patterns, value) -> Bool {
  list.any(patterns, fn(pattern) { is_bool_pattern(pattern, value) })
}

fn is_bool_pattern(pattern, value) {
  case strip_as(pattern) {
    PBool(v) -> v == value
    _ -> False
  }
}

fn is_none(option) {
  case option {
    None -> True
    Some(_) -> False
  }
}

fn pattern_irrefutable(pattern) -> Bool {
  case pattern {
    PWildcard -> True
    PVar(_) -> True
    PNil -> True
    PTuple(patterns) -> list.all(patterns, pattern_irrefutable)
    PLabelled(_, inner) -> pattern_irrefutable(inner)
    PAs(inner, _) -> pattern_irrefutable(inner)
    _ -> False
  }
}

fn infer_arms(env, signatures, ctors, subject_ty, arms, acc) {
  case arms {
    [] ->
      case acc {
        None -> Error(CheckError("`case` with no arms"))
        Some(#(typed_arms, ty)) -> Ok(#(list.reverse(typed_arms), ty))
      }
    [Arm(pattern, guard, body), ..rest] -> {
      use bindings <- result.try(bind_pattern(pattern, subject_ty, ctors))
      let arm_env = list.append(bindings, env)
      use guard_t <- result.try(check_guard(guard, arm_env, signatures, ctors))
      use body_t <- result.try(elaborate_t(arm_env, signatures, ctors, body))
      let arm = tmono.TArm(pattern, guard_t, body_t)
      let body_ty = tmono.type_of(body_t)
      case acc {
        None ->
          infer_arms(
            env,
            signatures,
            ctors,
            subject_ty,
            rest,
            Some(#([arm], body_ty)),
          )
        Some(#(typed_arms, ty)) -> {
          use _ <- result.try(unify(ty, body_ty, "in `case` arm"))
          infer_arms(
            env,
            signatures,
            ctors,
            subject_ty,
            rest,
            Some(#([arm, ..typed_arms], ty)),
          )
        }
      }
    }
  }
}

fn check_guard(guard, env, signatures, ctors) {
  case guard {
    None -> Ok(None)
    Some(expr) -> {
      use expr_t <- result.try(elaborate_t(env, signatures, ctors, expr))
      use _ <- result.try(unify(TBool, tmono.type_of(expr_t), "in `case` guard"))
      Ok(Some(expr_t))
    }
  }
}

fn infer_ctor(env, signatures, ctors, name, args) {
  case dict.get(ctors, name) {
    Error(_) -> Error(CheckError("unknown constructor `" <> name <> "`"))
    Ok(CtorInfo(type_name, fields)) -> {
      let field_names =
        list.map(fields, fn(field) {
          let #(field_name, _) = field
          field_name
        })
      let field_types =
        list.map(fields, fn(field) {
          let #(_, field_ty) = field
          field_ty
        })
      use ordered <- result.try(order_args(field_names, name, args))
      use typed_args <- result.try(infer_all_expect(
        env,
        signatures,
        ctors,
        field_types,
        ordered,
      ))
      use _ <- result.try(check_types(
        field_types,
        list.map(typed_args, tmono.type_of),
        "in `" <> name <> "`",
      ))
      Ok(tmono.TCtor(name, typed_args, TNamed(type_name)))
    }
  }
}

fn infer_call(env, signatures, ctors, fun, args) {
  case fun {
    EVar(name) ->
      case lookup(env, name) {
        Ok(TFun(param_types, ret)) -> {
          use typed_args <- result.try(infer_all_expect(
            env,
            signatures,
            ctors,
            param_types,
            args,
          ))
          use _ <- result.try(check_types(
            param_types,
            list.map(typed_args, tmono.type_of),
            "in indirect call to `" <> name <> "`",
          ))
          Ok(tmono.TCall(
            tmono.TVar(name, TFun(param_types, ret)),
            typed_args,
            ret,
          ))
        }
        _ -> infer_named_call(env, signatures, ctors, name, args)
      }
    EField(EVar(module), name) ->
      infer_builtin(env, signatures, ctors, module, name, args)
    _ -> {
      use fun_t <- result.try(elaborate_t(env, signatures, ctors, fun))
      case tmono.type_of(fun_t) {
        TFun(param_types, ret) -> {
          use typed_args <- result.try(infer_all(env, signatures, ctors, args))
          use _ <- result.try(check_types(
            param_types,
            list.map(typed_args, tmono.type_of),
            "in indirect call",
          ))
          Ok(tmono.TCall(fun_t, typed_args, ret))
        }
        _ -> Error(CheckError("callee is not a function"))
      }
    }
  }
}

fn fn_type_of(params, ret) -> Type {
  TFun(
    list.map(params, fn(param) {
      let #(_, param_ty) = param
      param_ty
    }),
    ret,
  )
}

fn infer_named_call(env, signatures, ctors, name, args) {
  case dict.get(signatures, name) {
    Error(_) -> Error(CheckError("unknown function `" <> name <> "`"))
    Ok(Signature(params, ret)) -> {
      let param_names =
        list.map(params, fn(param) {
          let #(param_name, _) = param
          param_name
        })
      let param_types =
        list.map(params, fn(param) {
          let #(_, param_ty) = param
          param_ty
        })
      use ordered <- result.try(order_args(param_names, name, args))
      use typed_args <- result.try(infer_all_expect(
        env,
        signatures,
        ctors,
        param_types,
        ordered,
      ))
      use _ <- result.try(check_types(
        param_types,
        list.map(typed_args, tmono.type_of),
        "in call to `" <> name <> "`",
      ))
      Ok(tmono.TCall(tmono.TVar(name, fn_type_of(params, ret)), typed_args, ret))
    }
  }
}

// ---------------------------------------------------------------------------
// labelled arguments: positional args fill the next free slot, labelled args
// match by name. Returns the arguments in formal order.
// ---------------------------------------------------------------------------

fn empty_expr_slots(names: List(String)) -> List(Option(Expr)) {
  list.map(names, fn(_) { None })
}

fn empty_pattern_slots(names: List(String)) -> List(Option(Pattern)) {
  list.map(names, fn(_) { None })
}

fn order_args(
  names: List(String),
  ctx: String,
  args: List(Expr),
) -> Result(List(Expr), CheckError) {
  let slots = empty_expr_slots(names)
  use filled <- result.try(fill_args(names, ctx, args, slots, 0))
  collect_slots(filled, ctx, [])
}

fn fill_args(
  names: List(String),
  ctx: String,
  args: List(Expr),
  slots: List(Option(Expr)),
  next_pos: Int,
) {
  case args {
    [] -> Ok(slots)
    [arg, ..rest] ->
      case arg {
        ELabelled(label, value) ->
          case index_of(names, label) {
            Error(_) ->
              Error(CheckError("unknown argument `" <> label <> "` in " <> ctx))
            Ok(index) ->
              case nth(slots, index) {
                Ok(Some(_)) ->
                  Error(CheckError(
                    "duplicate argument `" <> label <> "` in " <> ctx,
                  ))
                _ ->
                  fill_args(
                    names,
                    ctx,
                    rest,
                    set_slot(slots, index, Some(value)),
                    next_pos,
                  )
              }
          }
        _ ->
          case next_empty(slots, next_pos) {
            Error(_) -> Error(CheckError("too many arguments in " <> ctx))
            Ok(index) ->
              fill_args(
                names,
                ctx,
                rest,
                set_slot(slots, index, Some(arg)),
                index + 1,
              )
          }
      }
  }
}

fn collect_slots(slots, ctx, acc) -> Result(List(Expr), CheckError) {
  case slots {
    [] -> Ok(list.reverse(acc))
    [None, ..] -> Error(CheckError("missing argument in " <> ctx))
    [Some(value), ..rest] -> collect_slots(rest, ctx, [value, ..acc])
  }
}

fn next_empty(slots, from) -> Result(Int, Nil) {
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

fn index_of(items, target) {
  index_of_loop(items, target, 0)
}

fn index_of_loop(items, target, index) {
  case items {
    [] -> Error(Nil)
    [item, ..rest] ->
      case item == target {
        True -> Ok(index)
        False -> index_of_loop(rest, target, index + 1)
      }
  }
}

fn nth(items, index) {
  case items {
    [] -> Error(Nil)
    [item, ..rest] ->
      case index == 0 {
        True -> Ok(item)
        False -> nth(rest, index - 1)
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

fn infer_builtin(env, signatures, ctors, module, name, args) {
  case module, name {
    // `Buffer(a)`: the element type flows from the operand (`get`/`set`/`len`)
    // or from the expected type at the call site (`new`, via `infer_expect`).
    "buffer", "new" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      use _ <- result.try(check_types(
        [TInt],
        list.map(typed_args, tmono.type_of),
        "in `buffer.new`",
      ))
      Ok(builtin_call(
        "buffer",
        "new",
        [TInt],
        TApp("Buffer", [TVar("__buffer_elem")]),
        typed_args,
      ))
    }
    "buffer", "len" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      case typed_args {
        [buf] ->
          case buffer_elem_type(tmono.type_of(buf)) {
            Ok(_) ->
              Ok(builtin_call(
                "buffer",
                "len",
                [tmono.type_of(buf)],
                TInt,
                typed_args,
              ))
            Error(_) -> Error(CheckError("buffer.len expects a Buffer"))
          }
        _ -> Error(CheckError("buffer.len expects a Buffer"))
      }
    }
    "buffer", "get" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      case typed_args {
        [buf, index] ->
          case tmono.type_of(index) {
            TInt ->
              case buffer_elem_type(tmono.type_of(buf)) {
                Ok(elem) ->
                  Ok(builtin_call(
                    "buffer",
                    "get",
                    [tmono.type_of(buf), TInt],
                    elem,
                    typed_args,
                  ))
                Error(_) ->
                  Error(CheckError("buffer.get expects (Buffer(a), Int)"))
              }
            _ -> Error(CheckError("buffer.get expects (Buffer(a), Int)"))
          }
        _ -> Error(CheckError("buffer.get expects (Buffer(a), Int)"))
      }
    }
    "buffer", "set" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      case typed_args {
        [buf, index, value] ->
          case tmono.type_of(index) {
            TInt ->
              case buffer_elem_type(tmono.type_of(buf)) {
                Ok(elem) -> {
                  use _ <- result.try(expect_ty(
                    tmono.type_of(value),
                    elem,
                    "in `buffer.set`",
                  ))
                  Ok(builtin_call(
                    "buffer",
                    "set",
                    [tmono.type_of(buf), TInt, elem],
                    tmono.type_of(buf),
                    typed_args,
                  ))
                }
                Error(_) ->
                  Error(CheckError("buffer.set expects (Buffer(a), Int, a)"))
              }
            _ -> Error(CheckError("buffer.set expects (Buffer(a), Int, a)"))
          }
        _ -> Error(CheckError("buffer.set expects (Buffer(a), Int, a)"))
      }
    }
    "buffer", "is_null" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      case typed_args {
        [buf] ->
          case buffer_elem_type(tmono.type_of(buf)) {
            Ok(_) ->
              Ok(builtin_call("buffer", "is_null", [tmono.type_of(buf)], TBool, typed_args))
            Error(_) -> Error(CheckError("buffer.is_null expects a Buffer"))
          }
        _ -> Error(CheckError("buffer.is_null expects a Buffer"))
      }
    }
    "buffer", "take" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      case typed_args {
        [buf, index] ->
          case tmono.type_of(index) {
            TInt ->
              case buffer_elem_type(tmono.type_of(buf)) {
                Ok(elem) ->
                  Ok(builtin_call(
                    "buffer",
                    "take",
                    [tmono.type_of(buf), TInt],
                    elem,
                    typed_args,
                  ))
                Error(_) ->
                  Error(CheckError("buffer.take expects (Buffer(a), Int)"))
              }
            _ -> Error(CheckError("buffer.take expects (Buffer(a), Int)"))
          }
        _ -> Error(CheckError("buffer.take expects (Buffer(a), Int)"))
      }
    }
    "io", "println" ->
      check_builtin(env, signatures, ctors, args, [TString], TNil, "io.println")
    "io", "print" ->
      check_builtin(env, signatures, ctors, args, [TString], TNil, "io.print")
    // Async base (Vesper `std::time`): `timer(ms)` yields a `Future(())`
    // internally; the caller sees `Nil` (the future is awaited by the
    // scheduler loop, never exposed to Gleam).
    "time", "timer" ->
      check_builtin(env, signatures, ctors, args, [TInt], TNil, "time.timer")
    "time", "timer_count" ->
      check_builtin(env, signatures, ctors, args, [TInt], TInt, "time.timer_count")
    // Async I/O surface (Vesper `std::uv`): the host returns a `Future<T>`
    // which the caller sees unwrapped (implicit await).
    "uv", "fs_open" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString, TInt, TInt],
        TInt,
        "uv.fs_open",
      )
    "uv", "fs_fstat" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TInt],
        TInt,
        "uv.fs_fstat",
      )
    "uv", "fs_read" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TInt, TInt],
        TNamed("BitArray"),
        "uv.fs_read",
      )
    "uv", "fs_close" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TInt],
        TInt,
        "uv.fs_close",
      )
    "uv", "fs_write" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TInt, TNamed("BitArray")],
        TInt,
        "uv.fs_write",
      )
    "uv", "fs_unlink" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString],
        TInt,
        "uv.fs_unlink",
      )
    "uv", "fs_mkdir" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString, TInt],
        TInt,
        "uv.fs_mkdir",
      )
    "uv", "fs_rmdir" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString],
        TInt,
        "uv.fs_rmdir",
      )
    "uv", "fs_rename" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString, TString],
        TInt,
        "uv.fs_rename",
      )
    "uv", "fs_symlink" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString, TString],
        TInt,
        "uv.fs_symlink",
      )
    "uv", "fs_link" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString, TString],
        TInt,
        "uv.fs_link",
      )
    "uv", "fs_chmod" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString, TInt],
        TInt,
        "uv.fs_chmod",
      )
    "uv", "fs_stat" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString, TInt],
        TNamed("BitArray"),
        "uv.fs_stat",
      )
    "uv", "fs_realpath" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString],
        TNamed("BitArray"),
        "uv.fs_realpath",
      )
    "uv", "fs_readdir" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString],
        TNamed("BitArray"),
        "uv.fs_readdir",
      )
    "uv", "fs_cwd" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [],
        TNamed("BitArray"),
        "uv.fs_cwd",
      )
    "int", "to_string" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TInt],
        TString,
        "int.to_string",
      )
    "float", "to_string" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TFloat],
        TString,
        "float.to_string",
      )
    "bool", "to_string" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TBool],
        TString,
        "bool.to_string",
      )
    "int", "min" ->
      check_builtin(env, signatures, ctors, args, [TInt, TInt], TInt, "int.min")
    "int", "max" ->
      check_builtin(env, signatures, ctors, args, [TInt, TInt], TInt, "int.max")
    "int", "absolute_value" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TInt],
        TInt,
        "int.absolute_value",
      )
    "float", "raw_power" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TFloat, TFloat],
        TFloat,
        "float.raw_power",
      )
    "float", "raw_square_root" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TFloat],
        TFloat,
        "float.raw_square_root",
      )
    "int", "raw_to_base_string" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TInt, TInt],
        TString,
        "int.raw_to_base_string",
      )
    "int", "to_float" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TInt],
        TFloat,
        "int.to_float",
      )
    "string", "raw_codepoint_at" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString, TInt],
        TInt,
        "string.raw_codepoint_at",
      )
    "string", "raw_codepoint_to_string" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TInt],
        TString,
        "string.raw_codepoint_to_string",
      )
    "string", "compare_bytes" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString, TString],
        TInt,
        "string.compare_bytes",
      )
    "float", "min" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TFloat, TFloat],
        TFloat,
        "float.min",
      )
    "float", "max" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TFloat, TFloat],
        TFloat,
        "float.max",
      )
    "float", "absolute_value" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TFloat],
        TFloat,
        "float.absolute_value",
      )
    "float", "floor" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TFloat],
        TFloat,
        "float.floor",
      )
    "float", "ceiling" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TFloat],
        TFloat,
        "float.ceiling",
      )
    "float", "round" ->
      check_builtin(env, signatures, ctors, args, [TFloat], TInt, "float.round")
    "float", "truncate" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TFloat],
        TInt,
        "float.truncate",
      )
    "string", "contains" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString, TString],
        TBool,
        "string.contains",
      )
    "string", "starts_with" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString, TString],
        TBool,
        "string.starts_with",
      )
    "string", "ends_with" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString, TString],
        TBool,
        "string.ends_with",
      )
    "string", "trim_start" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString],
        TString,
        "string.trim_start",
      )
    "string", "trim_end" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString],
        TString,
        "string.trim_end",
      )
    "string", "trim" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString],
        TString,
        "string.trim",
      )
    "string", "replace" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString, TString, TString],
        TString,
        "string.replace",
      )
    "gleamc", "show" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      case args {
        [_] ->
          Ok(builtin_call(
            "gleamc",
            "show",
            list.map(typed_args, tmono.type_of),
            TString,
            typed_args,
          ))
        _ -> Error(CheckError("gleamc.show expects 1 argument"))
      }
    }
    "gleamc", "hash" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      case args {
        [_] ->
          Ok(builtin_call(
            "gleamc",
            "hash",
            list.map(typed_args, tmono.type_of),
            TInt,
            typed_args,
          ))
        _ -> Error(CheckError("gleamc.hash expects 1 argument"))
      }
    }
    "io", "debug" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      case args {
        [_] ->
          Ok(builtin_call(
            "io",
            "debug",
            list.map(typed_args, tmono.type_of),
            TNil,
            typed_args,
          ))
        _ -> Error(CheckError("io.debug expects 1 argument"))
      }
    }
    "gleamc", "key_compare" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      case typed_args {
        [a, b] ->
          case type_equal(tmono.type_of(a), tmono.type_of(b)) {
            True ->
              Ok(builtin_call(
                "gleamc",
                "key_compare",
                [tmono.type_of(a), tmono.type_of(b)],
                TInt,
                typed_args,
              ))
            False ->
              Error(CheckError("gleamc.key_compare expects matching types"))
          }
        _ -> Error(CheckError("gleamc.key_compare expects 2 arguments"))
      }
    }
    "bit_array", "from_string" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString],
        TNamed("BitArray"),
        "bit_array.from_string",
      )
    "bit_array", "raw_to_string" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TNamed("BitArray")],
        TString,
        "bit_array.raw_to_string",
      )
    "bit_array", "byte_size" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TNamed("BitArray")],
        TInt,
        "bit_array.byte_size",
      )
    "bit_array", "int64_at" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TNamed("BitArray"), TInt],
        TInt,
        "bit_array.int64_at",
      )
    "bit_array", "byte" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TNamed("BitArray"), TInt],
        TInt,
        "bit_array.byte",
      )
    "bit_array", "append" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TNamed("BitArray"), TNamed("BitArray")],
        TNamed("BitArray"),
        "bit_array.append",
      )
    "bit_array", "bit_size" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TNamed("BitArray")],
        TInt,
        "bit_array.bit_size",
      )
    "string", "byte_size" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString],
        TInt,
        "string.byte_size",
      )
    "string", "slice" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString, TInt, TInt],
        TString,
        "string.slice",
      )
    "string", "length" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString],
        TInt,
        "string.length",
      )
    "string", "append" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString, TString],
        TString,
        "string.append",
      )
    "string", "uppercase" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString],
        TString,
        "string.uppercase",
      )
    "string", "lowercase" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString],
        TString,
        "string.lowercase",
      )
    "float", "raw_exponential" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TFloat],
        TFloat,
        "float.raw_exponential",
      )
    "float", "raw_logarithm" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TFloat],
        TFloat,
        "float.raw_logarithm",
      )
    "int", "bitwise_and" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TInt, TInt],
        TInt,
        "int.bitwise_and",
      )
    "int", "bitwise_or" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TInt, TInt],
        TInt,
        "int.bitwise_or",
      )
    "int", "bitwise_exclusive_or" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TInt, TInt],
        TInt,
        "int.bitwise_exclusive_or",
      )
    "int", "bitwise_not" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TInt],
        TInt,
        "int.bitwise_not",
      )
    "int", "bitwise_shift_left" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TInt, TInt],
        TInt,
        "int.bitwise_shift_left",
      )
    "int", "bitwise_shift_right" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TInt, TInt],
        TInt,
        "int.bitwise_shift_right",
      )
    "string", "reverse" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString],
        TString,
        "string.reverse",
      )
    "bit_array", "is_utf8" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TNamed("BitArray")],
        TBool,
        "bit_array.is_utf8",
      )
    "host", "run" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString],
        TNamed("BitArray"),
        "host.run",
      )
    "host", "char_code_at" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString, TInt],
        TInt,
        "host.char_code_at",
      )
    "host", "char_byte_len" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString, TInt],
        TInt,
        "host.char_byte_len",
      )
    "host", "byte_slice" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString, TInt, TInt],
        TString,
        "host.byte_slice",
      )
    "host", "argv" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [],
        TNamed("BitArray"),
        "host.argv",
      )
    "host", "get_env" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString],
        TString,
        "host.get_env",
      )
    "host", "which" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TString],
        TString,
        "host.which",
      )
    "host", "now_ms" ->
      check_builtin(env, signatures, ctors, args, [], TInt, "host.now_ms")
    "host", "blob_slice" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TNamed("BitArray"), TInt],
        TNamed("BitArray"),
        "host.blob_slice",
      )
    "host", "int64_at" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TNamed("BitArray"), TInt],
        TInt,
        "host.int64_at",
      )
    // Cooperative processes and tasks. Message/result types are generic; the
    // `Subject(a)` / `Task(a)` handles carry the type (the backend boxes the
    // concrete value at the boundary).
    "process_ffi", "new_subject" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      Ok(builtin_call(
        "process_ffi",
        "new_subject",
        [],
        TApp("Subject", [TVar("__subject_elem")]),
        typed_args,
      ))
    }
    "process_ffi", "send" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      case typed_args {
        [subject, message] ->
          case subject_elem_type(tmono.type_of(subject)) {
            Ok(elem) ->
              case elem == tmono.type_of(message) {
                True ->
                  Ok(builtin_call(
                    "process_ffi",
                    "send",
                    [tmono.type_of(subject), elem],
                    TNil,
                    typed_args,
                  ))
                False ->
                  Error(CheckError(
                    "process_ffi.send: message type does not match the Subject",
                  ))
              }
            Error(_) -> Error(CheckError("process_ffi.send expects (Subject(a), a)"))
          }
        _ -> Error(CheckError("process_ffi.send expects (Subject(a), a)"))
      }
    }
    "process_ffi", "receive" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      case typed_args {
        [subject] ->
          case subject_elem_type(tmono.type_of(subject)) {
            Ok(elem) ->
              Ok(builtin_call(
                "process_ffi",
                "receive",
                [tmono.type_of(subject)],
                elem,
                typed_args,
              ))
            Error(_) ->
              Error(CheckError("process_ffi.receive expects a Subject(a)"))
          }
        _ -> Error(CheckError("process_ffi.receive expects a Subject(a)"))
      }
    }
    "process", "spawn" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      case typed_args {
        [worker] ->
          case tmono.type_of(worker) {
            TFun([], TNil) ->
              Ok(builtin_call(
                "process",
                "spawn",
                [tmono.type_of(worker)],
                TNamed("Pid"),
                typed_args,
              ))
            _ -> Error(CheckError("process.spawn expects fn() -> Nil"))
          }
        _ -> Error(CheckError("process.spawn expects fn() -> Nil"))
      }
    }
    "process", "spawn_unlinked" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      case typed_args {
        [worker] ->
          case tmono.type_of(worker) {
            TFun([], TNil) ->
              Ok(builtin_call(
                "process",
                "spawn_unlinked",
                [tmono.type_of(worker)],
                TNamed("Pid"),
                typed_args,
              ))
            _ -> Error(CheckError("process.spawn_unlinked expects fn() -> Nil"))
          }
        _ -> Error(CheckError("process.spawn_unlinked expects fn() -> Nil"))
      }
    }
    "task", "async" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      case typed_args {
        [worker] ->
          case tmono.type_of(worker) {
            TFun([], ret_ty) ->
              Ok(builtin_call(
                "task",
                "async",
                [tmono.type_of(worker)],
                TApp("Task", [ret_ty]),
                typed_args,
              ))
            _ -> Error(CheckError("task.async expects fn() -> a"))
          }
        _ -> Error(CheckError("task.async expects fn() -> a"))
      }
    }
    "process_ffi", "wait_any" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      case typed_args {
        [subject, timeout] ->
          case subject_elem_type(tmono.type_of(subject)) {
            Ok(_) ->
              case tmono.type_of(timeout) {
                TInt ->
                  Ok(builtin_call(
                    "process_ffi",
                    "wait_any",
                    [tmono.type_of(subject), TInt],
                    TInt,
                    typed_args,
                  ))
                _ -> Error(CheckError("process_ffi.wait_any expects an Int timeout"))
              }
            Error(_) ->
              Error(CheckError("process_ffi.wait_any expects a Subject(a)"))
          }
        _ -> Error(CheckError("process_ffi.wait_any expects (Subject(a), Int)"))
      }
    }
    "task_ffi", "await_timeout" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      case typed_args {
        [task, timeout] ->
          case task_elem_type(tmono.type_of(task)) {
            Ok(_) ->
              case tmono.type_of(timeout) {
                TInt ->
                  Ok(builtin_call(
                    "task_ffi",
                    "await_timeout",
                    [tmono.type_of(task), TInt],
                    TInt,
                    typed_args,
                  ))
                _ ->
                  Error(CheckError(
                    "task_ffi.await_timeout expects an Int timeout",
                  ))
              }
            Error(_) ->
              Error(CheckError("task_ffi.await_timeout expects a Task(a)"))
          }
        _ ->
          Error(CheckError("task_ffi.await_timeout expects (Task(a), Int)"))
      }
    }
    "task_ffi", "await" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      case typed_args {
        [task] ->
          case task_elem_type(tmono.type_of(task)) {
            Ok(elem) ->
              Ok(builtin_call(
                "task_ffi",
                "await",
                [tmono.type_of(task)],
                elem,
                typed_args,
              ))
            Error(_) -> Error(CheckError("task_ffi.await expects a Task(a)"))
          }
        _ -> Error(CheckError("task_ffi.await expects a Task(a)"))
      }
    }
    "process_ffi", "self" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [],
        TNamed("Pid"),
        "process_ffi.self",
      )
    "process_ffi", "is_alive" ->
      check_builtin(
        env,
        signatures,
        ctors,
        args,
        [TNamed("Pid")],
        TBool,
        "process_ffi.is_alive",
      )
    "task_ffi", "pid" -> {
      use typed_args <- result.try(infer_all(env, signatures, ctors, args))
      case typed_args {
        [task] ->
          case task_elem_type(tmono.type_of(task)) {
            Ok(_) ->
              Ok(builtin_call(
                "task_ffi",
                "pid",
                [tmono.type_of(task)],
                TNamed("Pid"),
                typed_args,
              ))
            Error(_) -> Error(CheckError("task_ffi.pid expects a Task(a)"))
          }
        _ -> Error(CheckError("task_ffi.pid expects a Task(a)"))
      }
    }
    _, _ ->
      Error(CheckError(
        "unknown module function `" <> module <> "." <> name <> "`",
      ))
  }
}

fn check_builtin(env, signatures, ctors, args, params, ret, label) {
  use _ <- result.try(check_call_arity(label, params, args, label))
  use typed_args <- result.try(infer_all(env, signatures, ctors, args))
  use _ <- result.try(check_types(
    params,
    list.map(typed_args, tmono.type_of),
    "in call to `" <> label <> "`",
  ))
  let #(module, name) = split_builtin_label(label)
  Ok(builtin_call(module, name, params, ret, typed_args))
}

fn split_builtin_label(label) {
  case string.split(label, ".") {
    [module, name] -> #(module, name)
    _ -> #(label, "")
  }
}

fn builtin_call(module, name, params, ret, typed_args) {
  tmono.TCall(
    tmono.TField(tmono.TVar(module, TNil), name, TFun(params, ret)),
    typed_args,
    ret,
  )
}

fn check_call_arity(label, params, args, ctx) {
  case list.length(params) == list.length(args) {
    True -> Ok(Nil)
    False ->
      Error(CheckError(
        ctx
        <> " expects "
        <> int.to_string(list.length(params))
        <> " argument(s), found "
        <> int.to_string(list.length(args))
        <> " ("
        <> label
        <> ")",
      ))
  }
}

// ---------------------------------------------------------------------------
// patterns
// ---------------------------------------------------------------------------

fn bind_pattern(pattern, subject_ty, ctors) -> Result(Env, CheckError) {
  case pattern {
    PWildcard -> Ok([])
    PVar(name) -> Ok([#(name, subject_ty)])
    PInt(_) -> literal_pattern(subject_ty, TInt, "integer pattern")
    PFloat(_) -> literal_pattern(subject_ty, TFloat, "float pattern")
    PString(_) -> literal_pattern(subject_ty, TString, "string pattern")
    PBool(_) -> literal_pattern(subject_ty, TBool, "bool pattern")
    PNil -> literal_pattern(subject_ty, TNil, "Nil pattern")
    PTuple(patterns) ->
      case subject_ty {
        TTuple(types) ->
          case list.length(patterns) == list.length(types) {
            True -> bind_patterns(patterns, types, ctors)
            False -> Error(CheckError("tuple pattern arity mismatch"))
          }
        _ ->
          Error(CheckError(
            "tuple pattern against `" <> describe_type(subject_ty) <> "`",
          ))
      }
    PCtor(name, args) ->
      case dict.get(ctors, name) {
        Error(_) -> Error(CheckError("unknown constructor `" <> name <> "`"))
        Ok(CtorInfo(type_name, fields)) -> {
          use _ <- result.try(expect_ty(
            subject_ty,
            TNamed(type_name),
            "pattern",
          ))
          let field_names =
            list.map(fields, fn(field) {
              let #(field_name, _) = field
              field_name
            })
          let field_types =
            list.map(fields, fn(field) {
              let #(_, field_ty) = field
              field_ty
            })
          use ordered <- result.try(order_patterns(field_names, name, args))
          case list.length(ordered) == list.length(field_types) {
            True -> bind_patterns(ordered, field_types, ctors)
            False ->
              Error(CheckError(
                "constructor `" <> name <> "` pattern arity mismatch",
              ))
          }
        }
      }
    PLabelled(_, inner) -> bind_pattern(inner, subject_ty, ctors)
    PAs(inner, name) -> {
      use bindings <- result.try(bind_pattern(inner, subject_ty, ctors))
      Ok([#(name, subject_ty), ..bindings])
    }
    PBitArray(patterns) -> {
      use _ <- result.try(expect_ty(subject_ty, TNamed("BitArray"), "pattern"))
      bind_patterns(patterns, list.repeat(TInt, list.length(patterns)), ctors)
    }
  }
}

// ---------------------------------------------------------------------------
// labelled patterns (resolved to formal order)
// ---------------------------------------------------------------------------

fn order_patterns(names, ctx, args) -> Result(List(Pattern), CheckError) {
  let slots = empty_pattern_slots(names)
  use filled <- result.try(fill_patterns(names, ctx, args, slots, 0))
  collect_patterns(filled, ctx, [])
}

fn fill_patterns(names, ctx, args, slots, next_pos) {
  case args {
    [] -> Ok(slots)
    [arg, ..rest] ->
      case arg {
        PLabelled(label, inner) ->
          case index_of(names, label) {
            Error(_) ->
              Error(CheckError("unknown argument `" <> label <> "` in " <> ctx))
            Ok(index) ->
              fill_patterns(
                names,
                ctx,
                rest,
                set_slot(slots, index, Some(inner)),
                next_pos,
              )
          }
        _ ->
          case next_empty(slots, next_pos) {
            Error(_) -> Error(CheckError("too many arguments in " <> ctx))
            Ok(index) ->
              fill_patterns(
                names,
                ctx,
                rest,
                set_slot(slots, index, Some(arg)),
                index + 1,
              )
          }
      }
  }
}

fn collect_patterns(slots, ctx, acc) -> Result(List(Pattern), CheckError) {
  case slots {
    [] -> Ok(list.reverse(acc))
    [None, ..] -> Error(CheckError("missing argument in " <> ctx))
    [Some(value), ..rest] -> collect_patterns(rest, ctx, [value, ..acc])
  }
}

fn bind_patterns(patterns, types, ctors) {
  case patterns, types {
    [], [] -> Ok([])
    [pattern, ..patterns], [ty, ..types] -> {
      use env1 <- result.try(bind_pattern(pattern, ty, ctors))
      use env2 <- result.try(bind_patterns(patterns, types, ctors))
      Ok(list.append(env1, env2))
    }
    _, _ -> Error(CheckError("pattern arity mismatch"))
  }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn lookup(env, name) {
  case env {
    [] -> Error(Nil)
    [#(bound, ty), ..rest] ->
      case bound == name {
        True -> Ok(ty)
        False -> lookup(rest, name)
      }
  }
}

fn check_types(expected, actual, ctx) {
  case expected, actual {
    [], [] -> Ok(Nil)
    [expected_ty, ..expected_rest], [actual_ty, ..actual_rest] -> {
      use _ <- result.try(unify(expected_ty, actual_ty, ctx))
      check_types(expected_rest, actual_rest, ctx)
    }
    _, _ -> Error(CheckError("arity mismatch " <> ctx))
  }
}

fn expect_ty(actual, expected, ctx) {
  use _ <- result.try(unify(expected, actual, ctx))
  Ok(Nil)
}

fn literal_pattern(actual, expected, ctx) -> Result(Env, CheckError) {
  use _ <- result.try(expect_ty(actual, expected, ctx))
  Ok([])
}

fn unify(expected, actual, ctx) {
  case type_equal(expected, actual) {
    True -> Ok(expected)
    False ->
      Error(CheckError(
        "expected `"
        <> describe_type(expected)
        <> "`, found `"
        <> describe_type(actual)
        <> "`"
        <> context_suffix(ctx),
      ))
  }
}

fn context_suffix(ctx) {
  case ctx {
    "" -> ""
    _ -> " " <> ctx
  }
}

pub fn describe_type(ty: Type) -> String {
  case ty {
    TInt -> "Int"
    TFloat -> "Float"
    TBool -> "Bool"
    TString -> "String"
    TNil -> "Nil"
    TVar(name) -> name
    TNamed(name) -> name
    TApp(name, args) ->
      name <> "(" <> string.join(list.map(args, describe_type), ", ") <> ")"
    TTuple(types) ->
      "#(" <> string.join(list.map(types, describe_type), ", ") <> ")"
    TFun(params, ret) ->
      "fn("
      <> string.join(list.map(params, describe_type), ", ")
      <> ") -> "
      <> describe_type(ret)
  }
}

fn type_equal(a: Type, b: Type) -> Bool {
  case a, b {
    TInt, TInt -> True
    TFloat, TFloat -> True
    TBool, TBool -> True
    TString, TString -> True
    TNil, TNil -> True
    TVar(name_a), TVar(name_b) -> name_a == name_b
    TNamed(name_a), TNamed(name_b) -> name_a == name_b
    TApp(name_a, args_a), TApp(name_b, args_b) ->
      name_a == name_b && types_equal(args_a, args_b)
    TTuple(types_a), TTuple(types_b) -> types_equal(types_a, types_b)
    TFun(params_a, ret_a), TFun(params_b, ret_b) ->
      types_equal(params_a, params_b) && type_equal(ret_a, ret_b)
    _, _ -> False
  }
}

fn types_equal(a, b) -> Bool {
  case a, b {
    [], [] -> True
    [type_a, ..rest_a], [type_b, ..rest_b] ->
      type_equal(type_a, type_b) && types_equal(rest_a, rest_b)
    _, _ -> False
  }
}
