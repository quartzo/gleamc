//// Backend-ABI predicates shared by the SSA pass and the LLVM backend.
////
//// These decide when a value is passed/returned by memory rather than in a
//// register (a large aggregate is returned through an `sret` out pointer, and
//// `FileResult` uses `sret`/`byval`). The SSA pass needs the same answer to know
//// which locals must keep an addressable `Slot`; the backend uses it to render
//// the call. Keeping it in one place stops the two from drifting.

import gleam/dict.{type Dict}
import gleamc/ast.{type Type, TNamed, TString}

fn is_recursive(recursive: Dict(String, Bool), name: String) -> Bool {
  case dict.get(recursive, name) {
    Ok(found) -> found
    Error(_) -> False
  }
}

/// Whether a value of `ty` is returned through an `sret` out pointer (an
/// aggregate) instead of an SSA register.
pub fn ret_needs_sret(ty: Type, recursive: Dict(String, Bool)) -> Bool {
  case ty {
    ast.TInt | ast.TFloat | ast.TBool | ast.TNil -> False
    TString -> False
    TNamed("Nil") -> False
    TNamed("BitArray") -> False
    TNamed("void*") | TNamed("Future") | TNamed("Handle") | TNamed("Dynamic") | TNamed("SelectorHandle") -> False
    ast.TFun(_, _) -> False
    ast.TApp("Task", _) -> False
    TNamed(name) ->
      case ast.task_elem_name(name) {
        Ok(_) -> False
        Error(_) -> !is_recursive(recursive, name)
      }
    _ -> True
  }
}

pub fn is_file_result(ty: Type) -> Bool {
  case ty {
    TNamed("FileResult") -> True
    _ -> False
  }
}
