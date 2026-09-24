//// Owned-clone pass (M5b, IR→IR).
////
//// A tail call moves its arguments and an indirect call has an unknown
//// callee, so both need the `Owned` parameter ABI. Rather than forcing every
//// parameter of a function that is a tail/indirect target to `Owned` (which
//// degrades its ordinary calls), we keep the original with its natural
//// `Borrow`/`Owned` modes and create an all-`Owned` clone for the owned call
//// sites:
////
////   * `f`         — used by ordinary direct `OpCall` sites (natural modes).
////   * `f__owned`  — used by `Tailcall` sites and by any function value whose
////                   code can be called indirectly.
////
//// A clone is only created when the function is an owned target and at least
//// one parameter is naturally `Borrow` **and** a handle: for scalars the
//// `Borrow`/`Owned` distinction is not observable.

import gleam/dict.{type Dict}
import gleam/list
import gleam/string
import gleamc/ast.{type Type}
import gleamc/borrow
import gleamc/ffi_modes
import gleamc/ir

const suffix = "__owned"

pub fn apply(
  module: ir.Module,
  modes: Dict(String, List(ffi_modes.ParamMode)),
  is_handle: fn(Type) -> Bool,
) -> #(ir.Module, Dict(String, List(ffi_modes.ParamMode))) {
  let ir.Module(functions) = module
  let targets = borrow.owned_target_names(module)
  let by_name =
    list.fold(functions, dict.new(), fn(acc, function) {
      let ir.Function(name, _, _, _, _) = function
      dict.insert(acc, name, function)
    })
  // name -> clone name, only for functions that exist and have a naturally
  // `Borrow` handle parameter.
  let clones =
    list.fold(targets, dict.new(), fn(acc, name) {
      case dict.get(by_name, name) {
        Ok(function) ->
          case dict.get(modes, name) {
            Ok(param_modes) ->
              case has_borrow_handle(function, param_modes, is_handle) {
                True -> dict.insert(acc, name, name <> suffix)
                False -> acc
              }
            Error(_) -> acc
          }
        Error(_) -> acc
      }
    })
  // Rewrite owned call sites in every function (originals and, because they
  // are copied afterwards, the clones too).
  let functions =
    list.map(functions, fn(function) { rewrite_function(function, clones) })
  let clones_out =
    list.filter_map(functions, fn(function) {
      let ir.Function(name, params, ret, blocks, locals) = function
      case dict.get(clones, name) {
        Ok(clone_name) ->
          Ok(ir.Function(clone_name, params, ret, blocks, locals))
        Error(_) -> Error(Nil)
      }
    })
  let all = list.append(functions, clones_out)
  let modes =
    list.fold(clones_out, modes, fn(acc, function) {
      let ir.Function(name, params, _, _, _) = function
      dict.insert(acc, name, list.map(params, fn(_) { ffi_modes.Owned }))
    })
  #(ir.Module(all), modes)
}

fn has_borrow_handle(function, param_modes, is_handle) -> Bool {
  let ir.Function(_, params, _, _, locals) = function
  let by_local =
    list.fold(locals, dict.new(), fn(acc, local) {
      let ir.Local(name, ty) = local
      dict.insert(acc, name, ty)
    })
  let indexed = list.index_map(params, fn(param, index) { #(param, index) })
  list.any(indexed, fn(pair) {
    let #(param, index) = pair
    case dict.get(by_local, param) {
      Ok(ty) ->
        ffi_modes.mode_at(param_modes, index) == ffi_modes.Borrow
        && is_handle(ty)
      Error(_) -> False
    }
  })
}

fn rewrite_function(function: ir.Function, clones: Dict(String, String)) {
  let ir.Function(name, params, ret, blocks, locals) = function
  let blocks =
    list.map(blocks, fn(block) {
      let ir.Block(label, ops, term) = block
      let ops = list.map(ops, fn(op) { rewrite_op(op, clones) })
      ir.Block(label, ops, rewrite_term(term, clones))
    })
  ir.Function(name, params, ret, blocks, locals)
}

fn rewrite_op(op: ir.Op, clones: Dict(String, String)) {
  case op {
    ir.OpClosure(dest, code, captures, env_ty, fn_ty) ->
      ir.OpClosure(dest, rewrite_code(code, clones), captures, env_ty, fn_ty)
    _ -> op
  }
}

fn rewrite_term(term: ir.Terminator, clones: Dict(String, String)) {
  case term {
    ir.Tailcall(fun, args) ->
      case dict.get(clones, fun) {
        Ok(clone) -> ir.Tailcall(clone, args)
        Error(_) -> term
      }
    _ -> term
  }
}

/// The closure code of the clone, keeping the original `__gv_`/`Gleamc_`
/// prefix so the backend emits (and resolves) it the same way.
fn rewrite_code(code: String, clones: Dict(String, String)) -> String {
  case dict.get(clones, code_to_name(code)) {
    Ok(clone) -> prefix_of(code) <> clone
    Error(_) -> code
  }
}

fn prefix_of(code: String) -> String {
  case string.starts_with(code, "__gv_") {
    True -> "__gv_"
    False ->
      case string.starts_with(code, "Gleamc_") {
        True -> "Gleamc_"
        False -> ""
      }
  }
}

fn code_to_name(code: String) -> String {
  case string.starts_with(code, "__gv_") {
    True -> string.drop_start(code, 5)
    False ->
      case string.starts_with(code, "Gleamc_") {
        True -> string.drop_start(code, 7)
        False -> code
      }
  }
}
