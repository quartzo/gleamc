//// Lowering (M3): typed AST -> Core IR with a control-flow graph.
////
//// State is threaded through a `Builder` (in an immutable language this is
//// the monad-ish alternative to a mutable cursor). Every non-trivial
//// expression is materialized into a fresh local via an op, so the
//// ownership pass can reason about local identities.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleamc/ast.{
  type Pattern, type Type, PAs, PBitArray, PBool, PCtor, PFloat, PInt, PLabelled,
  PNil, PString, PTuple, PVar, PWildcard, TApp, TBool, TFun, TInt, TNamed, TNil,
  TString, TTuple, buffer_elem_name, subject_elem_name,
}
import gleamc/checker
import gleamc/infer
import gleamc/ir
import gleamc/tmono

pub type LowerError {
  LowerError(message: String)
}

pub fn describe_error(err: LowerError) -> String {
  let LowerError(message) = err
  "lowering error: " <> message
}

type Builder {
  Builder(
    blocks: List(ir.Block),
    ops: List(ir.Op),
    label: String,
    next_id: Int,
    locals_rev: List(ir.Local),
    env: List(#(String, ir.Operand, Type)),
    tenv: List(#(String, Type)),
    signatures: Dict(String, checker.Signature),
    ctors: Dict(String, checker.CtorInfo),
    /// Qualified name -> runtime symbol for `@external` declarations.
    externals: Dict(String, String),
  )
}

// ---------------------------------------------------------------------------
// builder helpers
// ---------------------------------------------------------------------------

fn fresh_local(b: Builder, prefix: String, ty: Type) -> #(String, Builder) {
  let id = b.next_id
  let name = prefix <> "__" <> int.to_string(id)
  #(
    name,
    Builder(..b, next_id: id + 1, locals_rev: [
      ir.Local(name, ty),
      ..b.locals_rev
    ]),
  )
}

fn new_label(b: Builder, prefix: String) -> #(String, Builder) {
  let id = b.next_id
  let name = prefix <> "_b" <> int.to_string(id)
  #(name, Builder(..b, next_id: id + 1))
}

fn emit(b: Builder, op: ir.Op) -> Builder {
  Builder(..b, ops: [op, ..b.ops])
}

fn end_block(b: Builder, term: ir.Terminator) -> Builder {
  let block = ir.Block(b.label, list.reverse(b.ops), term)
  Builder(..b, blocks: list.append(b.blocks, [block]), ops: [])
}

fn start_block(b: Builder, label: String) -> Builder {
  Builder(..b, label: label, ops: [])
}

fn bind_var(
  b: Builder,
  name: String,
  operand: ir.Operand,
  ty: Type,
) -> Builder {
  Builder(..b, env: [#(name, operand, ty), ..b.env], tenv: [
    #(name, ty),
    ..b.tenv
  ])
}

fn env_lookup(env, name) {
  case env {
    [] -> Error(Nil)
    [#(bound, operand, ty), ..rest] ->
      case bound == name {
        True -> Ok(#(operand, ty))
        False -> env_lookup(rest, name)
      }
  }
}

// ---------------------------------------------------------------------------
// module / functions
// ---------------------------------------------------------------------------

pub fn lower_module(
  module: tmono.TModule,
  signatures: Dict(String, checker.Signature),
  ctors: Dict(String, checker.CtorInfo),
) -> Result(ir.Module, LowerError) {
  let tmono.TModule(definitions) = module
  let externals =
    list.fold(definitions, dict.new(), fn(acc, definition) {
      case definition {
        tmono.TDExternal(external) ->
          dict.insert(acc, external.name, external.symbol)
        _ -> acc
      }
    })
  let functions =
    list.map(
      list.filter_map(definitions, fn(definition) {
        case definition {
          tmono.TDFunction(function) -> Ok(function)
          _ -> Error(Nil)
        }
      }),
      fn(function) { lower_function(function, signatures, ctors, externals) },
    )
  use functions <- result.try(sequence(functions))
  Ok(ir.Module(functions))
}

fn sequence(results) {
  sequence_loop(results, [])
}

fn sequence_loop(results, acc) {
  case results {
    [] -> Ok(list.reverse(acc))
    [result, ..rest] ->
      case result {
        Ok(value) -> sequence_loop(rest, [value, ..acc])
        Error(error) -> Error(error)
      }
  }
}

fn lower_function(
  function: tmono.TFunction,
  signatures,
  ctors,
  externals,
) -> Result(ir.Function, LowerError) {
  let param_names =
    list.map(function.params, fn(param) {
      let #(name, _) = param
      name
    })
  let initial_locals =
    list.map(function.params, fn(param) {
      let #(name, ty) = param
      ir.Local(name, ty)
    })
  let env =
    list.map(function.params, fn(param) {
      let #(name, ty) = param
      #(name, ir.Var(name), ty)
    })
  let tenv =
    list.map(function.params, fn(param) {
      let #(name, ty) = param
      #(name, ty)
    })
  let b =
    Builder(
      blocks: [],
      ops: [],
      label: "entry",
      next_id: 0,
      locals_rev: list.reverse(initial_locals),
      env: env,
      tenv: tenv,
      signatures: signatures,
      ctors: ctors,
      externals: externals,
    )
  use b2 <- result.try(lower_tail_block(b, body_statements(function.body)))
  Ok(ir.Function(
    function.name,
    param_names,
    function.ret,
    b2.blocks,
    list.reverse(b2.locals_rev),
  ))
}

fn body_statements(body: tmono.TExpr) -> List(tmono.TStatement) {
  case body {
    tmono.TBlock(statements, _) -> statements
    _ -> [tmono.TStmt(body)]
  }
}

// ---------------------------------------------------------------------------
// blocks and statements
// ---------------------------------------------------------------------------

fn lower_block(
  b: Builder,
  statements: List(tmono.TStatement),
) -> Result(#(ir.Operand, Builder), LowerError) {
  case statements {
    [] -> Ok(#(ir.Lit(ir.LUnit), b))
    [tmono.TStmt(expr)] -> lower_expr(b, expr)
    [tmono.TLet(pattern, value), ..rest] -> {
      use #(operand, b1) <- result.try(lower_expr(b, value))
      let ty = tmono.type_of(value)
      use b2 <- result.try(bind_let(b1, pattern, operand, ty))
      lower_block(b2, rest)
    }
    [tmono.TStmt(expr), ..rest] -> {
      use #(_, b1) <- result.try(lower_expr(b, expr))
      lower_block(b1, rest)
    }
  }
}

fn lower_tail_block(
  b: Builder,
  statements: List(tmono.TStatement),
) -> Result(Builder, LowerError) {
  case statements {
    [] -> Ok(end_block(b, ir.Ret(ir.Lit(ir.LUnit))))
    [tmono.TLet(pattern, value), ..rest] -> {
      use #(operand, b1) <- result.try(lower_expr(b, value))
      let ty = tmono.type_of(value)
      use b2 <- result.try(bind_let(b1, pattern, operand, ty))
      lower_tail_block(b2, rest)
    }
    [tmono.TStmt(expr)] -> lower_tail(b, expr)
    [tmono.TStmt(expr), ..rest] -> {
      use #(_, b1) <- result.try(lower_expr(b, expr))
      lower_tail_block(b1, rest)
    }
  }
}

/// Lowers an expression in tail position: a direct call becomes a `Tailcall`
/// (self or mutual); `case`/blocks recurse in tail position; anything else is
/// a normal expression + `Ret`.
fn lower_tail(b: Builder, expr: tmono.TExpr) -> Result(Builder, LowerError) {
  case expr {
    tmono.TCall(fun, args, _) ->
      case fun {
        tmono.TVar(name, _) ->
          case env_lookup(b.env, name) {
            // Direct call to a top-level function.
            Error(_) -> {
              use #(operands, b1) <- result.try(lower_args_expect(
                b,
                signature_param_types(b, name),
                order_by_params(b, name, args),
              ))
              Ok(end_block(b1, ir.Tailcall(name, operands)))
            }
            // Local function value: tail call through it.
            Ok(_) -> lower_tail_indirect(b, fun, args)
          }
        // A module function (`int.to_string`, ...) is a builtin, not a value.
        tmono.TField(tmono.TVar(_, _), _, _) -> lower_tail_ret(b, expr)
        // Any other callee is a function value: tail call it directly in the IR.
        _ -> lower_tail_indirect(b, fun, args)
      }
    tmono.TBlock(statements, _) -> lower_tail_block(b, statements)
    tmono.TCase(subject, arms, _) -> lower_tail_case(b, subject, arms)
    _ -> lower_tail_ret(b, expr)
  }
}

/// Tail call through a function value: the callee and arguments are evaluated,
/// then control leaves the function as an `ir.TailcallIndirect`. Creating this
/// here (where the tail position is known) keeps the tail call a first-class
/// terminator; it is never a generic `call; ret` that the ownership pass can
/// perturb.
fn lower_tail_indirect(b: Builder, fun, args) {
  use #(fval, b1) <- result.try(lower_expr(b, fun))
  use #(operands, b2) <- result.try(lower_args(b1, args))
  Ok(end_block(b2, ir.TailcallIndirect(fval, operands)))
}

fn lower_tail_ret(b: Builder, expr: tmono.TExpr) -> Result(Builder, LowerError) {
  use #(value, b1) <- result.try(lower_expr(b, expr))
  Ok(end_block(b1, ir.Ret(value)))
}

fn lower_tail_case(
  b: Builder,
  subject: tmono.TExpr,
  arms: List(tmono.TArm),
) -> Result(Builder, LowerError) {
  let subject_ty = tmono.type_of(subject)
  let case_env = b.env
  let case_tenv = b.tenv
  use #(subject_op, b0) <- result.try(lower_expr(b, subject))
  let #(fail_label, b1) = new_label(b0, "case_fail")
  use #(arm_labels, b2) <- result.try(make_arm_labels(b1, arms, []))
  case arm_labels {
    [] -> Error(LowerError("`case` with no arms"))
    [#(first_label, _), ..] -> {
      let b3 = end_block(b2, ir.Jmp(first_label))
      use b4 <- result.try(lower_tail_arms(
        b3,
        subject_op,
        subject_ty,
        fail_label,
        arm_labels,
        arms,
        case_env,
        case_tenv,
      ))
      let b5 = start_block(b4, fail_label)
      Ok(end_block(b5, ir.Unreachable))
    }
  }
}

fn lower_tail_arms(
  b,
  subject_op,
  subject_ty,
  fail_label,
  labels,
  arms,
  case_env,
  case_tenv,
) -> Result(Builder, LowerError) {
  case arms, labels {
    [], _ -> Ok(b)
    [tmono.TArm(pattern, guard, body), ..rest_arms],
      [#(test_label, body_label), ..rest_labels]
    -> {
      let next = case rest_labels {
        [#(next_label, _), ..] -> next_label
        [] -> fail_label
      }
      let b_reset = Builder(..b, env: case_env, tenv: case_tenv)
      let b1 = start_block(b_reset, test_label)
      let #(match_success, b1) = case guard {
        Some(_) -> {
          let #(guard_label, bb) = new_label(b1, "arm_guard")
          #(guard_label, bb)
        }
        None -> #(body_label, b1)
      }
      use b2 <- result.try(match_pattern(
        b1,
        subject_op,
        subject_ty,
        pattern,
        match_success,
        next,
      ))
      let b_guard = case guard {
        Some(_) -> start_block(b2, match_success)
        None -> b2
      }
      use b4 <- result.try(emit_guard(b_guard, guard, body_label, next))
      let b3 = start_block(b4, body_label)
      use b5 <- result.try(lower_tail(b3, body))
      lower_tail_arms(
        b5,
        subject_op,
        subject_ty,
        fail_label,
        rest_labels,
        rest_arms,
        case_env,
        case_tenv,
      )
    }
    _, _ -> Error(LowerError("case arm/label mismatch"))
  }
}

fn bind_let(
  b: Builder,
  pattern: Pattern,
  operand: ir.Operand,
  ty: Type,
) -> Result(Builder, LowerError) {
  case pattern {
    PWildcard -> Ok(b)
    PNil -> Ok(b)
    PVar(name) -> Ok(bind_var(b, name, operand, ty))
    PLabelled(_, inner) -> bind_let(b, inner, operand, ty)
    PTuple(patterns) ->
      case ty {
        TTuple(types) -> bind_tuple_let(b, patterns, types, operand, 0)
        _ -> Error(LowerError("tuple pattern against non-tuple"))
      }
    PCtor(name, patterns) ->
      case single_variant(b, name) {
        False ->
          Error(LowerError(
            "constructor pattern in `let` is not irrefutable: `" <> name <> "`",
          ))
        True -> bind_ctor_let(b, operand, name, patterns, 0)
      }
    _ -> Error(LowerError("unsupported let pattern"))
  }
}

/// Binds an irrefutable constructor pattern (single-variant type) by reading
/// each field into a fresh local. Labelled fields are matched by name.
fn bind_ctor_let(
  b,
  operand,
  ctor,
  patterns,
  fallback_index,
) -> Result(Builder, LowerError) {
  case patterns {
    [] -> Ok(b)
    [pattern, ..rest] -> {
      let fields = ctor_fields_named(b, ctor)
      let index = case pattern {
        PLabelled(label, _) ->
          case field_index(fields, label) {
            Ok(found) -> found
            Error(_) -> fallback_index
          }
        _ -> fallback_index
      }
      let field_ty = field_type_at(fields, index)
      let #(dest, b1) = fresh_local(b, "field", field_ty)
      let b2 = emit(b1, ir.OpField(dest, operand, ctor, index, field_ty))
      use b3 <- result.try(bind_let(b2, pattern, ir.Var(dest), field_ty))
      bind_ctor_let(b3, operand, ctor, rest, index + 1)
    }
  }
}

fn ctor_fields_named(b: Builder, name: String) -> List(#(String, Type)) {
  case dict.get(b.ctors, name) {
    Ok(checker.CtorInfo(_, fields)) -> fields
    Error(_) -> []
  }
}

fn field_index(fields, label) -> Result(Int, Nil) {
  fields
  |> list.index_map(fn(field, index) {
    let #(name, _) = field
    #(name, index)
  })
  |> list.find(fn(pair) {
    let #(name, _) = pair
    name == label
  })
  |> result.map(fn(pair) {
    let #(_, index) = pair
    index
  })
}

fn field_type_at(fields, index) -> Type {
  case
    fields
    |> list.index_map(fn(field, i) { #(i, field) })
    |> list.find(fn(pair) {
      let #(i, _) = pair
      i == index
    })
  {
    Ok(pair) -> {
      let #(_, field) = pair
      let #(_, ty) = field
      ty
    }
    Error(_) -> TNil
  }
}

/// Whether the constructor's type has a single variant (so a `let` pattern is
/// irrefutable).
fn single_variant(b: Builder, name: String) -> Bool {
  case dict.get(b.ctors, name) {
    Error(_) -> False
    Ok(checker.CtorInfo(type_name, _)) ->
      list.length(
        list.filter(dict.keys(b.ctors), fn(key) {
          case dict.get(b.ctors, key) {
            Ok(checker.CtorInfo(other, _)) -> other == type_name
            Error(_) -> False
          }
        }),
      )
      == 1
  }
}

fn bind_tuple_let(
  b,
  patterns,
  types,
  operand,
  index,
) -> Result(Builder, LowerError) {
  case patterns, types {
    [], _ -> Ok(b)
    [pattern, ..rest_patterns], [ty, ..rest_types] -> {
      let #(dest, b1) = fresh_local(b, "tget", ty)
      let b2 = emit(b1, ir.OpTupleGet(dest, operand, index, ty))
      use b3 <- result.try(bind_let(b2, pattern, ir.Var(dest), ty))
      bind_tuple_let(b3, rest_patterns, rest_types, operand, index + 1)
    }
    _, _ -> Error(LowerError("tuple pattern arity mismatch"))
  }
}

// ---------------------------------------------------------------------------
// expressions
// ---------------------------------------------------------------------------

fn lower_expr(
  b: Builder,
  expr: tmono.TExpr,
) -> Result(#(ir.Operand, Builder), LowerError) {
  case expr {
    tmono.TInt(value, _) -> Ok(#(ir.Lit(ir.LInt(value)), b))
    tmono.TFloat(value, _) -> Ok(#(ir.Lit(ir.LFloat(value)), b))
    tmono.TBool(value, _) -> Ok(#(ir.Lit(ir.LBool(value)), b))
    tmono.TNil(_) -> Ok(#(ir.Lit(ir.LUnit), b))
    tmono.TString(value, _) -> {
      let #(dest, b1) = fresh_local(b, "str", TString)
      Ok(#(ir.Var(dest), emit(b1, ir.OpConst(dest, ir.LString(value)))))
    }
    tmono.TVar(name, _) ->
      case env_lookup(b.env, name) {
        Ok(#(operand, _)) -> Ok(#(operand, b))
        Error(_) -> lower_fn_value(b, name)
      }
    tmono.TTuple(elements, ty) -> {
      use #(operands, b1) <- result.try(lower_args(b, elements))
      let #(dest, b2) = fresh_local(b1, "tuple", ty)
      Ok(#(ir.Var(dest), emit(b2, ir.OpTuple(dest, operands, ty))))
    }
    tmono.TBitArray(elements, ty) -> {
      use #(operands, b1) <- result.try(lower_args(b, elements))
      let #(dest, b2) = fresh_local(b1, "bitarray", ty)
      Ok(#(ir.Var(dest), emit(b2, ir.OpBitArray(dest, operands, ty))))
    }
    tmono.TCtor(name, args, ty) -> {
      use ordered <- result.try(order_exprs(ctor_field_names(b, name), args))
      use #(operands, b1) <- result.try(lower_args_expect(
        b,
        ctor_field_types(b, name),
        ordered,
      ))
      let type_name = ctor_type_name(b, name)
      let #(dest, b2) = fresh_local(b1, "ctor", ty)
      Ok(#(
        ir.Var(dest),
        emit(b2, ir.OpCtor(dest, name, type_name, operands, ty)),
      ))
    }
    tmono.TUnop(op, operand, ty) -> {
      use #(operand_op, b1) <- result.try(lower_expr(b, operand))
      let #(dest, b2) = fresh_local(b1, "unop", ty)
      Ok(#(ir.Var(dest), emit(b2, ir.OpUnop(dest, op, operand_op))))
    }
    tmono.TBinop(op, left, right, ty) -> {
      use #(left_op, b1) <- result.try(lower_expr(b, left))
      use #(right_op, b2) <- result.try(lower_expr(b1, right))
      let #(dest, b3) = fresh_local(b2, "binop", ty)
      Ok(#(ir.Var(dest), emit(b3, ir.OpBinop(dest, op, left_op, right_op))))
    }
    tmono.TCall(fun, args, ty) -> lower_call(b, fun, args, ty)
    tmono.TBlock(statements, _) -> lower_block(b, statements)
    tmono.TCase(subject, arms, ty) -> lower_case(b, subject, arms, ty)
    tmono.TField(obj, name, _) -> lower_field(b, obj, name)
    tmono.TLabelled(_, value, _) -> lower_expr(b, value)
    tmono.TLambda(_, _, _) ->
      Error(LowerError("lambda not lifted before lowering"))
    tmono.TClosure(code, captures, env_ty, fn_ty, _) ->
      lower_closure(b, code, captures, env_ty, fn_ty)
    tmono.TUpdate(_, _, _, _) ->
      Error(LowerError("record update must be desugared before lowering"))
    tmono.TPanic(message, ty) -> {
      let #(dest, b1) = fresh_local(b, "panic", ty)
      let #(msg_dest, b2) = fresh_local(b1, "panic_msg", TString)
      let b3 = emit(b2, ir.OpConst(msg_dest, ir.LString(message)))
      Ok(#(
        ir.Var(dest),
        emit(b3, ir.OpBuiltin(dest, "panic", [ir.Var(msg_dest)], ty)),
      ))
    }
    tmono.TEnvGet(env_ty, index, ty) -> {
      let #(dest, b1) = fresh_local(b, "cap", ty)
      Ok(#(ir.Var(dest), emit(b1, ir.OpEnvGet(dest, env_ty, index, ty))))
    }
  }
}

fn lower_closure(
  b,
  code,
  captures,
  env_ty,
  fn_ty,
) -> Result(#(ir.Operand, Builder), LowerError) {
  use #(operands, b1) <- result.try(lower_args(b, captures))
  let #(dest, b2) = fresh_local(b1, "closure", fn_ty)
  Ok(#(
    ir.Var(dest),
    emit(b2, ir.OpClosure(dest, code, operands, env_ty, fn_ty)),
  ))
}

fn lower_field(b, obj, name) -> Result(#(ir.Operand, Builder), LowerError) {
  use #(obj_op, b1) <- result.try(lower_expr(b, obj))
  let obj_ty = tmono.type_of(obj)
  use #(ctor, index, field_ty) <- result.try(field_lookup(b1, obj_ty, name))
  let #(dest, b2) = fresh_local(b1, "field", field_ty)
  Ok(#(ir.Var(dest), emit(b2, ir.OpField(dest, obj_op, ctor, index, field_ty))))
}

fn field_lookup(
  b: Builder,
  obj_ty,
  name,
) -> Result(#(String, Int, Type), LowerError) {
  case obj_ty {
    TNamed(type_name) -> {
      let matches =
        list.filter_map(dict.to_list(b.ctors), fn(entry) {
          let #(ctor, info) = entry
          let checker.CtorInfo(info_type, fields) = info
          case info_type == type_name {
            True -> find_field(fields, name, ctor, 0)
            False -> Error(Nil)
          }
        })
      case matches {
        [found, ..] -> Ok(found)
        [] ->
          Error(LowerError(
            "type `" <> type_name <> "` has no field `" <> name <> "`",
          ))
      }
    }
    _ -> Error(LowerError("field access on a non-record value"))
  }
}

fn find_field(fields, name, ctor, index) {
  case fields {
    [] -> Error(Nil)
    [#(field_name, field_ty), ..rest] ->
      case field_name == name {
        True -> Ok(#(ctor, index, field_ty))
        False -> find_field(rest, name, ctor, index + 1)
      }
  }
}

// ---------------------------------------------------------------------------
// labelled arguments (mirrors the checker's resolution)
// ---------------------------------------------------------------------------

fn ctor_field_names(b: Builder, name: String) -> List(String) {
  case dict.get(b.ctors, name) {
    Ok(checker.CtorInfo(_, fields)) ->
      list.map(fields, fn(field) {
        let #(field_name, _) = field
        field_name
      })
    Error(_) -> []
  }
}

fn empty_expr_slots(names: List(String)) -> List(Option(tmono.TExpr)) {
  list.map(names, fn(_) { None })
}

fn order_exprs(names, args) -> Result(List(tmono.TExpr), LowerError) {
  let slots = empty_expr_slots(names)
  use filled <- result.try(fill_exprs(names, args, slots, 0))
  case collect_exprs(filled, []) {
    Ok(ordered) -> Ok(ordered)
    Error(_) -> Error(LowerError("missing argument"))
  }
}

fn fill_exprs(
  names,
  args,
  slots,
  next_pos,
) -> Result(List(Option(tmono.TExpr)), LowerError) {
  case args {
    [] -> Ok(slots)
    [arg, ..rest] ->
      case arg {
        tmono.TLabelled(label, value, _) ->
          case index_of(names, label) {
            Error(_) -> Error(LowerError("unknown argument `" <> label <> "`"))
            Ok(index) ->
              fill_exprs(
                names,
                rest,
                set_slot(slots, index, Some(value)),
                next_pos,
              )
          }
        _ ->
          case next_empty(slots, next_pos) {
            Error(_) -> Error(LowerError("too many arguments"))
            Ok(index) ->
              fill_exprs(
                names,
                rest,
                set_slot(slots, index, Some(arg)),
                index + 1,
              )
          }
      }
  }
}

fn collect_exprs(slots, acc) {
  case slots {
    [] -> Ok(list.reverse(acc))
    [None, ..] -> Error(Nil)
    [Some(value), ..rest] -> collect_exprs(rest, [value, ..acc])
  }
}

fn index_of(items, target) {
  case items {
    [] -> Error(Nil)
    [item, ..rest] ->
      case item == target {
        True -> Ok(0)
        False -> {
          use index <- result.try(index_of(rest, target))
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

fn lower_call(
  b: Builder,
  fun,
  args,
  ret_ty,
) -> Result(#(ir.Operand, Builder), LowerError) {
  case fun {
    tmono.TVar(name, ty) ->
      case dict.get(b.externals, name) {
        // `@external`: call the runtime symbol directly. The name has no dot,
        // so the backend uses it verbatim instead of the `Gleamc_<module>_...`
        // builtin convention.
        Ok(symbol) -> {
          use #(operands, b1) <- result.try(lower_args(
            b,
            order_by_params(b, name, args),
          ))
          let #(dest, b2) = fresh_local(b1, "ext", ret_ty)
          Ok(#(
            ir.Var(dest),
            emit(b2, ir.OpBuiltin(dest, symbol, operands, ret_ty)),
          ))
        }
        Error(_) ->
          case env_lookup(b.env, name) {
            Ok(_) -> {
              use #(fval, b1) <- result.try(lower_expr(b, tmono.TVar(name, ty)))
              use #(operands, b2) <- result.try(lower_args(b1, args))
              let #(dest, b3) = fresh_local(b2, "callind", ret_ty)
              Ok(#(
                ir.Var(dest),
                emit(b3, ir.OpCallIndirect(dest, fval, operands, ret_ty)),
              ))
            }
            Error(_) -> {
              use #(operands, b1) <- result.try(lower_args_expect(
                b,
                signature_param_types(b, name),
                order_by_params(b, name, args),
              ))
              let #(dest, b2) = fresh_local(b1, "call", ret_ty)
              Ok(#(
                ir.Var(dest),
                emit(b2, ir.OpCall(dest, name, operands, ret_ty)),
              ))
            }
          }
      }
    tmono.TField(tmono.TVar(module, _), name, _) -> {
      let builtin = module <> "." <> name
      case builtin {
        // `task_ffi.await(task)` suspends on a task handle that is already started
        // (no host call to start a future): bind the awaited result.
        "task_ffi.await" -> lower_await(b, args, ret_ty)
        // `process_ffi.receive` is a boxed suspension: the future carries a box
        // whose payload is moved out on resume.
        "process_ffi.receive" -> lower_suspend_mode(b, args, builtin, ret_ty, ir.Boxed)
        _ ->
          case is_suspending(builtin) {
            // Async host call: starts an internal `Future` and suspends; the
            // scheduler loop resumes when it completes, binding the awaited
            // value (the Gleam-visible result).
            True -> lower_suspend(b, args, builtin, ret_ty)
            False -> {
              use #(operands, b1) <- result.try(lower_args(b, args))
              let #(dest, b2) = fresh_local(b1, "call", ret_ty)
              Ok(#(
                ir.Var(dest),
                emit(b2, ir.OpBuiltin(dest, builtin, operands, ret_ty)),
              ))
            }
          }
      }
    }
    _ -> {
      use #(fval, b1) <- result.try(lower_expr(b, fun))
      use #(operands, b2) <- result.try(lower_args(b1, args))
      let #(dest, b3) = fresh_local(b2, "callind", ret_ty)
      Ok(#(
        ir.Var(dest),
        emit(b3, ir.OpCallIndirect(dest, fval, operands, ret_ty)),
      ))
    }
  }
}

/// Async host builtins whose `Future` return is awaited implicitly: the call
/// starts the future and suspends, and the caller sees the unwrapped value.
fn is_suspending(builtin: String) -> Bool {
  list.contains(
    [
      "time.timer",
      "time.timer_count",
      "uv.fs_open",
      "uv.fs_fstat",
      "uv.fs_read",
      "uv.fs_close",
      "uv.fs_write",
      "uv.fs_unlink",
      "uv.fs_mkdir",
      "uv.fs_rmdir",
      "uv.fs_rename",
      "uv.fs_symlink",
      "uv.fs_link",
      "uv.fs_chmod",
      "uv.fs_stat",
      "uv.fs_realpath",
      "uv.fs_readdir",
      "uv.fs_cwd",
      "process_ffi.receive",
      "process_ffi.wait_any",
      "task_ffi.await_timeout",
    ],
    builtin,
  )
}

/// `task_ffi.await(task)`: suspends on an already-started task's completion
/// future and binds the result the task boxed into it. Unlike a host suspend
/// there is no builtin call: the handle is the future and the resume moves the
/// boxed value into `dest_ty`.
fn lower_await(b, args, dest_ty) {
  case args {
    [task_expr] -> {
      use #(fut, b1) <- result.try(lower_expr(b, task_expr))
      let #(dest, b2) = fresh_local(b1, "awaited", dest_ty)
      let #(resume, b3) = new_label(b2, "await")
      let b4 = end_block(b3, ir.Suspend(fut, dest, resume, ir.Boxed))
      let b5 = start_block(b4, resume)
      Ok(#(ir.Var(dest), b5))
    }
    _ -> Error(LowerError("task_ffi.await expects one task handle"))
  }
}

/// Suspending host call (`time.timer`, `uv.fs_read`, ...): starts the future
/// (internal handle) and suspends, binding the awaited value to a fresh local.
/// The Gleam-visible result is that local (unwrapped from the future).
fn lower_suspend(b, args, builtin, dest_ty) {
  lower_suspend_mode(b, args, builtin, dest_ty, ir.Host)
}

fn lower_suspend_mode(b, args, builtin, dest_ty, mode) {
  use #(operands, b1) <- result.try(lower_args(b, args))
  let future_ty = TNamed("Future")
  let #(fut, b2) = fresh_local(b1, "future", future_ty)
  let b3 = emit(b2, ir.OpBuiltin(fut, builtin, operands, future_ty))
  let #(dest, b4) = fresh_local(b3, "awaited", dest_ty)
  // The suspension is a terminator: control yields and resumes at `resume`.
  let #(resume, b5) = new_label(b4, "await")
  let b6 = end_block(b5, ir.Suspend(ir.Var(fut), dest, resume, mode))
  let b7 = start_block(b6, resume)
  Ok(#(ir.Var(dest), b7))
}

/// A top-level function used as a value becomes a function pointer.
fn lower_fn_value(
  b: Builder,
  name: String,
) -> Result(#(ir.Operand, Builder), LowerError) {
  case dict.get(b.signatures, name) {
    Ok(checker.Signature(params, ret)) -> {
      let param_tys =
        list.map(params, fn(param) {
          let #(_, ty) = param
          ty
        })
      let fn_ty = TFun(param_tys, ret)
      let #(dest, b1) = fresh_local(b, "fn", fn_ty)
      Ok(#(
        ir.Var(dest),
        emit(b1, ir.OpClosure(dest, "__gv_" <> name, [], "", fn_ty)),
      ))
    }
    Error(_) -> Error(LowerError("unbound variable `" <> name <> "`"))
  }
}

fn order_by_params(b: Builder, name: String, args) -> List(tmono.TExpr) {
  case dict.get(b.signatures, name) {
    Ok(checker.Signature(params, _)) -> {
      let names =
        list.map(params, fn(param) {
          let #(param_name, _) = param
          param_name
        })
      case order_exprs(names, args) {
        Ok(ordered) -> ordered
        Error(_) -> args
      }
    }
    Error(_) -> args
  }
}

fn lower_args(b, exprs) -> Result(#(List(ir.Operand), Builder), LowerError) {
  case exprs {
    [] -> Ok(#([], b))
    [expr, ..rest] -> {
      use #(operand, b1) <- result.try(lower_expr(b, expr))
      use #(operands, b2) <- result.try(lower_args(b1, rest))
      Ok(#([operand, ..operands], b2))
    }
  }
}

fn signature_param_types(b: Builder, name) -> List(Type) {
  case dict.get(b.signatures, name) {
    Ok(checker.Signature(params, _)) ->
      list.map(params, fn(param) {
        let #(_, ty) = param
        ty
      })
    Error(_) -> []
  }
}

fn ctor_field_types(b: Builder, name) -> List(Type) {
  case dict.get(b.ctors, name) {
    Ok(checker.CtorInfo(_, fields)) ->
      list.map(fields, fn(field) {
        let #(_, ty) = field
        ty
      })
    Error(_) -> []
  }
}

fn lower_args_expect(b, expected, exprs) -> Result(
  #(List(ir.Operand), Builder),
  LowerError,
) {
  case expected, exprs {
    [], [] -> Ok(#([], b))
    [ty, ..tys], [expr, ..rest] -> {
      use #(operand, b1) <- result.try(lower_expect(b, ty, expr))
      use #(operands, b2) <- result.try(lower_args_expect(b1, tys, rest))
      Ok(#([operand, ..operands], b2))
    }
    _, _ -> lower_args(b, exprs)
  }
}

fn is_buffer_like(ty: Type) -> Bool {
  case ty {
    TApp("Buffer", _) -> True
    TNamed(name) ->
      case buffer_elem_name(name) {
        Ok(_) -> True
        Error(_) -> False
      }
    _ -> False
  }
}

fn is_subject_like(ty: Type) -> Bool {
  case ty {
    TApp("Subject", _) -> True
    TNamed(name) ->
      case subject_elem_name(name) {
        Ok(_) -> True
        Error(_) -> False
      }
    _ -> False
  }
}


/// Like `lower_expr`, but a result-polymorphic builtin (`buffer.new`) adopts
/// its element type from the expected type (a constructor field).
fn lower_expect(b, expected, expr) -> Result(#(ir.Operand, Builder), LowerError) {
  case expr {
    tmono.TCall(
      tmono.TField(tmono.TVar("buffer", _), "new", _),
      args,
      _,
    ) ->
      case is_buffer_like(expected) {
        True -> {
          use #(operands, b1) <- result.try(lower_args(b, args))
          let #(dest, b2) = fresh_local(b1, "bufnew", expected)
          Ok(#(
            ir.Var(dest),
            emit(b2, ir.OpBuiltin(dest, "buffer.new", operands, expected)),
          ))
        }
        False -> lower_expr(b, expr)
      }
    // `process_ffi.new_subject()` adopts its message type from an expected
    // `Subject(elem)` at the call site.
    tmono.TCall(
      tmono.TField(tmono.TVar("process_ffi", _), "new_subject", _),
      args,
      _,
    ) ->
      case is_subject_like(expected) {
        True -> {
          use #(operands, b1) <- result.try(lower_args(b, args))
          let #(dest, b2) = fresh_local(b1, "subject", expected)
          Ok(#(
            ir.Var(dest),
            emit(b2, ir.OpBuiltin(dest, "process_ffi.new_subject", operands, expected)),
          ))
        }
        False -> lower_expr(b, expr)
      }
    _ -> lower_expr(b, expr)
  }
}

fn ctor_type_name(b: Builder, name: String) -> String {
  case dict.get(b.ctors, name) {
    Ok(checker.CtorInfo(type_name, _)) -> type_name
    Error(_) -> "?"
  }
}

// ---------------------------------------------------------------------------
// case expressions (decision tree: nested patterns tested incrementally)
// ---------------------------------------------------------------------------

fn lower_case(
  b: Builder,
  subject,
  arms,
  result_ty,
) -> Result(#(ir.Operand, Builder), LowerError) {
  let subject_ty = tmono.type_of(subject)
  let case_env = b.env
  let case_tenv = b.tenv
  use #(subject_op, b0) <- result.try(lower_expr(b, subject))
  let #(result_name, b1) = fresh_local(b0, "res", result_ty)
  let #(end_label, b2) = new_label(b1, "case_end")
  let #(fail_label, b3) = new_label(b2, "case_fail")
  use #(arm_labels, b4) <- result.try(make_arm_labels(b3, arms, []))
  case arm_labels {
    [] -> Error(LowerError("`case` with no arms"))
    [#(first_label, _), ..] -> {
      let b5 = end_block(b4, ir.Jmp(first_label))
      use b6 <- result.try(lower_arms(
        b5,
        subject_op,
        subject_ty,
        result_name,
        result_ty,
        end_label,
        fail_label,
        arm_labels,
        arms,
        case_env,
        case_tenv,
      ))
      let b7 = start_block(b6, fail_label)
      let b9 = end_block(b7, ir.Unreachable)
      let b10 = start_block(b9, end_label)
      Ok(#(ir.Var(result_name), b10))
    }
  }
}

fn make_arm_labels(
  b,
  arms,
  acc,
) -> Result(#(List(#(String, String)), Builder), LowerError) {
  case arms {
    [] -> Ok(#(list.reverse(acc), b))
    [_, ..rest] -> {
      let #(test_label, b1) = new_label(b, "arm_test")
      let #(body_label, b2) = new_label(b1, "arm_body")
      make_arm_labels(b2, rest, [#(test_label, body_label), ..acc])
    }
  }
}

fn lower_arms(
  b,
  subject_op,
  subject_ty,
  result_name,
  result_ty,
  end_label,
  fail_label,
  labels,
  arms,
  case_env,
  case_tenv,
) -> Result(Builder, LowerError) {
  case arms, labels {
    [], _ -> Ok(b)
    [tmono.TArm(pattern, guard, body), ..rest_arms],
      [#(test_label, body_label), ..rest_labels]
    -> {
      let next = case rest_labels {
        [#(next_label, _), ..] -> next_label
        [] -> fail_label
      }
      let b_reset = Builder(..b, env: case_env, tenv: case_tenv)
      let b1 = start_block(b_reset, test_label)
      // with a guard, the pattern success jumps to a guard block
      let #(match_success, b1) = case guard {
        Some(_) -> {
          let #(guard_label, bb) = new_label(b1, "arm_guard")
          #(guard_label, bb)
        }
        None -> #(body_label, b1)
      }
      use b2 <- result.try(match_pattern(
        b1,
        subject_op,
        subject_ty,
        pattern,
        match_success,
        next,
      ))
      let b_guard = case guard {
        Some(_) -> start_block(b2, match_success)
        None -> b2
      }
      use b4 <- result.try(emit_guard(b_guard, guard, body_label, next))
      let b3 = start_block(b4, body_label)
      use #(body_op, b5) <- result.try(lower_expr(b3, body))
      let b5 = emit(b5, ir.OpCopy(result_name, body_op, result_ty))
      let b6 = end_block(b5, ir.Jmp(end_label))
      lower_arms(
        b6,
        subject_op,
        subject_ty,
        result_name,
        result_ty,
        end_label,
        fail_label,
        rest_labels,
        rest_arms,
        case_env,
        case_tenv,
      )
    }
    _, _ -> Error(LowerError("case arm/label mismatch"))
  }
}

fn emit_guard(b, guard, body_label, fail_label) -> Result(Builder, LowerError) {
  case guard {
    None -> Ok(b)
    Some(expr) -> {
      use #(guard_op, b1) <- result.try(lower_expr(b, expr))
      Ok(end_block(b1, ir.Branch(guard_op, body_label, fail_label)))
    }
  }
}

// ---------------------------------------------------------------------------
// patterns: emit tests (and bindings on the success path), jumping to
// `success` or `fail`. Nested patterns extract sub-values only after the
// enclosing constructor tag has matched.
// ---------------------------------------------------------------------------

fn match_pattern(
  b,
  operand,
  ty,
  pattern,
  success,
  fail,
) -> Result(Builder, LowerError) {
  case pattern {
    PWildcard -> Ok(end_block(b, ir.Jmp(success)))
    PNil -> Ok(end_block(b, ir.Jmp(success)))
    PVar(name) -> Ok(end_block(bind_var(b, name, operand, ty), ir.Jmp(success)))
    PAs(inner, name) ->
      match_pattern(
        bind_var(b, name, operand, ty),
        operand,
        ty,
        inner,
        success,
        fail,
      )
    PInt(value) ->
      match_literal(b, operand, ir.Lit(ir.LInt(value)), success, fail)
    PFloat(value) ->
      match_literal(b, operand, ir.Lit(ir.LFloat(value)), success, fail)
    PString(value) -> {
      let #(literal, b1) = const_string(b, value)
      match_literal(b1, operand, ir.Var(literal), success, fail)
    }
    PBool(True) -> Ok(end_block(b, ir.Branch(operand, success, fail)))
    PBool(False) -> Ok(end_block(b, ir.Branch(operand, fail, success)))
    PTuple(patterns) ->
      case ty {
        TTuple(types) ->
          match_tuple(b, operand, patterns, types, success, fail, 0)
        _ -> Error(LowerError("tuple pattern against non-tuple"))
      }
    PCtor(name, args) -> {
      let type_name = ctor_type_name(b, name)
      use ordered <- result.try(order_patterns_lower(
        ctor_field_names(b, name),
        name,
        args,
      ))
      let #(tag_dest, b1) = fresh_local(b, "tagis", TBool)
      let b2 = emit(b1, ir.OpTagIs(tag_dest, operand, name, type_name))
      let #(ok_label, b3) = new_label(b2, "ctor_ok")
      let b4 = end_block(b3, ir.Branch(ir.Var(tag_dest), ok_label, fail))
      let fields = ctor_fields(b4, name)
      match_ctor_args(
        start_block(b4, ok_label),
        operand,
        name,
        ordered,
        fields,
        success,
        fail,
        0,
      )
    }
    PLabelled(_, inner) -> match_pattern(b, operand, ty, inner, success, fail)
    PBitArray(patterns) -> {
      let count = list.length(patterns)
      let #(size, b1) = fresh_local(b, "basize", TInt)
      let b2 =
        emit(b1, ir.OpBuiltin(size, "bit_array.byte_size", [operand], TInt))
      let #(mid, b3) = new_label(b2, "ba_size")
      use b4 <- result.try(match_literal(
        b3,
        ir.Var(size),
        ir.Lit(ir.LInt(count)),
        mid,
        fail,
      ))
      match_bit_array(start_block(b4, mid), operand, patterns, success, fail, 0)
    }
  }
}

fn match_bit_array(b, operand, patterns, success, fail, index) {
  case patterns {
    [] -> Ok(end_block(b, ir.Jmp(success)))
    [pattern, ..rest] -> {
      let #(byte, b1) = fresh_local(b, "babyte", TInt)
      let b2 =
        emit(
          b1,
          ir.OpBuiltin(
            byte,
            "bit_array.byte",
            [operand, ir.Lit(ir.LInt(index))],
            TInt,
          ),
        )
      case rest {
        [] -> match_pattern(b2, ir.Var(byte), TInt, pattern, success, fail)
        _ -> {
          let #(mid, b3) = new_label(b2, "ba_next")
          use b4 <- result.try(match_pattern(
            b3,
            ir.Var(byte),
            TInt,
            pattern,
            mid,
            fail,
          ))
          match_bit_array(
            start_block(b4, mid),
            operand,
            rest,
            success,
            fail,
            index + 1,
          )
        }
      }
    }
  }
}

fn order_patterns_lower(names, ctx, args) -> Result(List(Pattern), LowerError) {
  case infer.order_pattern(names, ctx, args) {
    Ok(value) -> Ok(value)
    Error(message) -> Error(LowerError(message))
  }
}

fn match_literal(
  b,
  operand,
  literal,
  success,
  fail,
) -> Result(Builder, LowerError) {
  let #(dest, b1) = fresh_local(b, "test", TBool)
  let b2 = emit(b1, ir.OpBinop(dest, "==", operand, literal))
  Ok(end_block(b2, ir.Branch(ir.Var(dest), success, fail)))
}

fn match_tuple(
  b,
  operand,
  patterns,
  types,
  success,
  fail,
  index,
) -> Result(Builder, LowerError) {
  case patterns, types {
    [], _ -> Ok(end_block(b, ir.Jmp(success)))
    [pattern, ..rest_patterns], [ty, ..rest_types] -> {
      let #(element, b1) = fresh_local(b, "tget", ty)
      let b2 = emit(b1, ir.OpTupleGet(element, operand, index, ty))
      case rest_patterns {
        [] -> match_pattern(b2, ir.Var(element), ty, pattern, success, fail)
        _ -> {
          let #(mid, b3) = new_label(b2, "tuple_next")
          use b4 <- result.try(match_pattern(
            b3,
            ir.Var(element),
            ty,
            pattern,
            mid,
            fail,
          ))
          match_tuple(
            start_block(b4, mid),
            operand,
            rest_patterns,
            rest_types,
            success,
            fail,
            index + 1,
          )
        }
      }
    }
    _, _ -> Error(LowerError("tuple pattern arity mismatch"))
  }
}

fn match_ctor_args(
  b,
  operand,
  ctor,
  patterns,
  fields,
  success,
  fail,
  index,
) -> Result(Builder, LowerError) {
  case patterns, fields {
    [], _ -> Ok(end_block(b, ir.Jmp(success)))
    [pattern, ..rest_patterns], [ty, ..rest_fields] -> {
      let #(field, b1) = fresh_local(b, "field", ty)
      let b2 = emit(b1, ir.OpField(field, operand, ctor, index, ty))
      case rest_patterns {
        [] -> match_pattern(b2, ir.Var(field), ty, pattern, success, fail)
        _ -> {
          let #(mid, b3) = new_label(b2, "ctor_next")
          use b4 <- result.try(match_pattern(
            b3,
            ir.Var(field),
            ty,
            pattern,
            mid,
            fail,
          ))
          match_ctor_args(
            start_block(b4, mid),
            operand,
            ctor,
            rest_patterns,
            rest_fields,
            success,
            fail,
            index + 1,
          )
        }
      }
    }
    _, _ -> Error(LowerError("constructor pattern arity mismatch"))
  }
}

fn const_string(b, value) -> #(String, Builder) {
  let #(dest, b1) = fresh_local(b, "str", TString)
  #(dest, emit(b1, ir.OpConst(dest, ir.LString(value))))
}

fn ctor_fields(b: Builder, name: String) {
  case dict.get(b.ctors, name) {
    Ok(checker.CtorInfo(_, fields)) ->
      list.map(fields, fn(field) {
        let #(_, field_ty) = field
        field_ty
      })
    Error(_) -> []
  }
}
