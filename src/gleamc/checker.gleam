//// Type checker for the M1/M2 subset.
////
//// Monomorphic by design: function signatures and custom types come fully
//// annotated, and local `let` types are inferred. There are no type
//// variables or generics yet.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleamc/ast.{
  type Expr, type Module, type Pattern, type Type, Arm, CustomType, DCustomType,
  DFunction, DImport, EBinop, EBlock, EBool, ECall, ECase, EClosure, ECtor,
  EEnvGet, EField, EFloat, EInt, ELabelled, ELambda, ENil, EString, ETuple,
  EUnop, EVar, Function, Let, Module, PBool, PCtor, PFloat, PInt, PLabelled,
  PNil, PString, PTuple, PVar, PWildcard, Stmt, TApp, TBool, TFloat, TFun, TInt,
  TNamed, TNil, TString, TTuple, TVar, Variant,
}

pub type Signature {
  Signature(params: List(#(String, Type)), ret: Type)
}

pub type CtorInfo {
  CtorInfo(type_name: String, fields: List(#(String, Type)))
}

pub type Checked {
  Checked(
    module: Module,
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

pub fn check(module: Module) -> Result(Checked, CheckError) {
  let Module(defs) = module
  let #(signatures, ctors) = collect(defs, dict.new(), dict.new())
  case check_defs(defs, signatures, ctors) {
    Ok(_) -> Ok(Checked(module, signatures, ctors))
    Error(err) -> Error(err)
  }
}

fn collect(defs, signatures, ctors) {
  case defs {
    [] -> #(signatures, ctors)
    [DFunction(Function(_, name, params, ret, _)), ..rest] -> {
      let signatures = dict.insert(signatures, name, Signature(params, ret))
      collect(rest, signatures, ctors)
    }
    [DCustomType(custom), ..rest] -> {
      let CustomType(_, name, _generics, variants) = custom
      let ctors =
        list.fold(variants, ctors, fn(acc, variant) {
          let Variant(variant_name, fields) = variant
          dict.insert(acc, variant_name, CtorInfo(name, fields))
        })
      collect(rest, signatures, ctors)
    }
    [DImport(_), ..rest] -> collect(rest, signatures, ctors)
  }
}

fn check_defs(defs, signatures, ctors) {
  case defs {
    [] -> Ok(Nil)
    [DFunction(function), ..rest] -> {
      use _ <- result.try(check_function(function, signatures, ctors))
      check_defs(rest, signatures, ctors)
    }
    [_, ..rest] -> check_defs(rest, signatures, ctors)
  }
}

fn check_function(function, signatures, ctors) {
  let Function(_, name, params, ret, body) = function
  let env =
    list.map(params, fn(param) {
      let #(param_name, ty) = param
      #(param_name, ty)
    })
  use body_ty <- result.try(infer(env, signatures, ctors, body))
  use _ <- result.try(unify(ret, body_ty, "in function `" <> name <> "`"))
  Ok(Nil)
}

// ---------------------------------------------------------------------------
// expression inference
// ---------------------------------------------------------------------------

pub type Env =
  List(#(String, Type))

pub fn infer(
  env: Env,
  signatures: Dict(String, Signature),
  ctors: Dict(String, CtorInfo),
  expr: Expr,
) -> Result(Type, CheckError) {
  case expr {
    EInt(_) -> Ok(TInt)
    EFloat(_) -> Ok(TFloat)
    EString(_) -> Ok(TString)
    EBool(_) -> Ok(TBool)
    ENil -> Ok(TNil)
    EVar(name) ->
      case lookup(env, name) {
        Ok(ty) -> Ok(ty)
        Error(_) ->
          case dict.get(signatures, name) {
            Ok(Signature(params, ret)) -> Ok(fn_type_of(params, ret))
            Error(_) -> Error(CheckError("unknown variable `" <> name <> "`"))
          }
      }
    ETuple(elements) -> {
      use types <- result.try(infer_all(env, signatures, ctors, elements))
      Ok(TTuple(types))
    }
    EUnop(op, operand) -> infer_unop(env, signatures, ctors, op, operand)
    EBinop(op, left, right) ->
      infer_binop(env, signatures, ctors, op, left, right)
    EBlock(statements) -> infer_block(env, signatures, ctors, statements)
    ECase(subject, arms) -> infer_case(env, signatures, ctors, subject, arms)
    ECtor(name, args) -> infer_ctor(env, signatures, ctors, name, args)
    ECall(fun, args) -> infer_call(env, signatures, ctors, fun, args)
    EField(obj, name) -> {
      use obj_ty <- result.try(infer(env, signatures, ctors, obj))
      infer_field(obj_ty, name, ctors)
    }
    ELabelled(_, value) -> infer(env, signatures, ctors, value)
    ELambda(_, _) -> Error(CheckError("lambda not lifted before codegen"))
    EClosure(_, _, _, fn_ty) -> Ok(fn_ty)
    EEnvGet(_, _, ty) -> Ok(ty)
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
      use ty <- result.try(infer(env, signatures, ctors, expr))
      use types <- result.try(infer_all(env, signatures, ctors, rest))
      Ok([ty, ..types])
    }
  }
}

fn infer_unop(env, signatures, ctors, op, operand) {
  use ty <- result.try(infer(env, signatures, ctors, operand))
  case op {
    "-" ->
      case ty {
        TInt -> Ok(TInt)
        TFloat -> Ok(TFloat)
        _ ->
          Error(CheckError(
            "`-` expects Int or Float, found `" <> describe_type(ty) <> "`",
          ))
      }
    "-." ->
      case ty {
        TFloat -> Ok(TFloat)
        _ ->
          Error(CheckError(
            "`-.` expects Float, found `" <> describe_type(ty) <> "`",
          ))
      }
    "!" ->
      case ty {
        TBool -> Ok(TBool)
        _ ->
          Error(CheckError(
            "`!` expects Bool, found `" <> describe_type(ty) <> "`",
          ))
      }
    _ -> Error(CheckError("unknown unary operator `" <> op <> "`"))
  }
}

fn infer_binop(env, signatures, ctors, op, left, right) {
  use left_ty <- result.try(infer(env, signatures, ctors, left))
  use right_ty <- result.try(infer(env, signatures, ctors, right))
  case op {
    "+" | "-" | "*" | "/" | "%" ->
      case left_ty, right_ty {
        TInt, TInt -> Ok(TInt)
        _, _ ->
          Error(binary_error(op, left_ty, right_ty, "expects Int on both sides"))
      }
    "+." | "-." | "*." | "/." ->
      case left_ty, right_ty {
        TFloat, TFloat -> Ok(TFloat)
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
        True -> Ok(TBool)
        False ->
          Error(binary_error(op, left_ty, right_ty, "expects matching sides"))
      }
    "<" | "<=" | ">" | ">=" ->
      case left_ty, right_ty {
        TInt, TInt -> Ok(TBool)
        _, _ ->
          Error(binary_error(op, left_ty, right_ty, "expects Int on both sides"))
      }
    "<." | "<=." | ">." | ">=." ->
      case left_ty, right_ty {
        TFloat, TFloat -> Ok(TBool)
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
        TString, TString -> Ok(TString)
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
        TBool, TBool -> Ok(TBool)
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
    [] -> Ok(TNil)
    [Stmt(expr)] -> infer(env, signatures, ctors, expr)
    [Let(pattern, value), ..rest] -> {
      use ty <- result.try(infer(env, signatures, ctors, value))
      use bindings <- result.try(bind_pattern(pattern, ty, ctors))
      infer_block(list.append(bindings, env), signatures, ctors, rest)
    }
    [Stmt(expr), ..rest] -> {
      use _ <- result.try(infer(env, signatures, ctors, expr))
      infer_block(env, signatures, ctors, rest)
    }
  }
}

fn infer_case(env, signatures, ctors, subject, arms) {
  use subject_ty <- result.try(infer(env, signatures, ctors, subject))
  use _ <- result.try(check_exhaustive(subject_ty, arms, ctors))
  infer_arms(env, signatures, ctors, subject_ty, arms, None)
}

// ---------------------------------------------------------------------------
// exhaustiveness
// ---------------------------------------------------------------------------

fn check_exhaustive(subject_ty, arms, ctors) {
  let unguarded =
    list.filter_map(arms, fn(arm) {
      let Arm(pattern, guard, _) = arm
      case is_none(guard) {
        True -> Ok(pattern)
        False -> Error(Nil)
      }
    })
  case patterns_exhaustive(subject_ty, unguarded, ctors) {
    True -> Ok(Nil)
    False -> Error(CheckError("non-exhaustive `case` (add a `_` arm)"))
  }
}

fn patterns_exhaustive(ty, patterns, ctors) -> Bool {
  case list.any(patterns, pattern_irrefutable) {
    True -> True
    False ->
      case ty {
        TNamed(name) -> type_exhaustive(name, patterns, ctors)
        TBool -> has_bool(patterns, True) && has_bool(patterns, False)
        _ -> False
      }
  }
}

fn type_exhaustive(name, patterns, ctors) -> Bool {
  let variants = variants_of(name, ctors)
  list.all(variants, fn(variant) {
    let #(variant_name, field_types) = variant
    let args_of =
      list.filter_map(patterns, fn(pattern) {
        case pattern {
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
          case
            list.any(args_of, fn(args) { list.all(args, pattern_irrefutable) })
          {
            True -> True
            False ->
              case field_types {
                [single] ->
                  patterns_exhaustive(
                    single,
                    list.map(args_of, fn(args) { first_pattern(args) }),
                    ctors,
                  )
                _ -> False
              }
          }
      }
  }
}

fn first_pattern(args) {
  case args {
    [first, ..] -> first
    [] -> PWildcard
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
  case pattern {
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
    _ -> False
  }
}

fn infer_arms(env, signatures, ctors, subject_ty, arms, acc) {
  case arms {
    [] ->
      case acc {
        None -> Error(CheckError("`case` with no arms"))
        Some(ty) -> Ok(ty)
      }
    [Arm(pattern, guard, body), ..rest] -> {
      use bindings <- result.try(bind_pattern(pattern, subject_ty, ctors))
      let arm_env = list.append(bindings, env)
      use _ <- result.try(check_guard(guard, arm_env, signatures, ctors))
      use body_ty <- result.try(infer(arm_env, signatures, ctors, body))
      case acc {
        None ->
          infer_arms(env, signatures, ctors, subject_ty, rest, Some(body_ty))
        Some(ty) -> {
          use _ <- result.try(unify(ty, body_ty, "in `case` arm"))
          infer_arms(env, signatures, ctors, subject_ty, rest, Some(ty))
        }
      }
    }
  }
}

fn check_guard(guard, env, signatures, ctors) {
  case guard {
    None -> Ok(Nil)
    Some(expr) -> {
      use ty <- result.try(infer(env, signatures, ctors, expr))
      use _ <- result.try(unify(TBool, ty, "in `case` guard"))
      Ok(Nil)
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
      use arg_types <- result.try(infer_all(env, signatures, ctors, ordered))
      use _ <- result.try(check_types(
        field_types,
        arg_types,
        "in `" <> name <> "`",
      ))
      Ok(TNamed(type_name))
    }
  }
}

fn infer_call(env, signatures, ctors, fun, args) {
  case fun {
    EVar(name) ->
      case lookup(env, name) {
        Ok(TFun(param_types, ret)) -> {
          use arg_types <- result.try(infer_all(env, signatures, ctors, args))
          use _ <- result.try(check_types(
            param_types,
            arg_types,
            "in indirect call to `" <> name <> "`",
          ))
          Ok(ret)
        }
        _ -> infer_named_call(env, signatures, ctors, name, args)
      }
    EField(EVar(module), name) ->
      infer_builtin(env, signatures, ctors, module, name, args)
    _ -> {
      use fun_ty <- result.try(infer(env, signatures, ctors, fun))
      case fun_ty {
        TFun(param_types, ret) -> {
          use arg_types <- result.try(infer_all(env, signatures, ctors, args))
          use _ <- result.try(check_types(
            param_types,
            arg_types,
            "in indirect call",
          ))
          Ok(ret)
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
      use arg_types <- result.try(infer_all(env, signatures, ctors, ordered))
      use _ <- result.try(check_types(
        param_types,
        arg_types,
        "in call to `" <> name <> "`",
      ))
      Ok(ret)
    }
  }
}

// ---------------------------------------------------------------------------
// labelled arguments: positional args fill the next free slot, labelled args
// match by name. Returns the arguments in formal order.
// ---------------------------------------------------------------------------

fn order_args(names, ctx, args) -> Result(List(Expr), CheckError) {
  let slots = list.map(names, fn(_) { None })
  use filled <- result.try(fill_args(names, ctx, args, slots, 0))
  collect_slots(filled, ctx, [])
}

fn fill_args(names, ctx, args, slots, next_pos) {
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
    "io", "println" ->
      check_builtin(env, signatures, ctors, args, [TString], TNil, "io.println")
    "io", "print" ->
      check_builtin(env, signatures, ctors, args, [TString], TNil, "io.print")
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
    _, _ ->
      Error(CheckError(
        "unknown module function `" <> module <> "." <> name <> "`",
      ))
  }
}

fn check_builtin(env, signatures, ctors, args, params, ret, label) {
  use _ <- result.try(check_call_arity(label, params, args, label))
  use arg_types <- result.try(infer_all(env, signatures, ctors, args))
  use _ <- result.try(check_types(
    params,
    arg_types,
    "in call to `" <> label <> "`",
  ))
  Ok(ret)
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
  }
}

// ---------------------------------------------------------------------------
// labelled patterns (resolved to formal order)
// ---------------------------------------------------------------------------

fn order_patterns(names, ctx, args) -> Result(List(Pattern), CheckError) {
  let slots = list.map(names, fn(_) { None })
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
