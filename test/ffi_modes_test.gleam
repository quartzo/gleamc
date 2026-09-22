import gleam/dict
import gleam/list
import gleam/string
import gleamc/ffi_modes
import gleamc/infer

/// Every builtin the checker knows must have a declared ownership mode, so a
/// C builtin can never be reached without an explicit borrow/move decision.
pub fn ffi_modes_cover_builtins_test() {
  let declared = ffi_modes.table()
  let missing =
    list.filter(infer.builtin_names(), fn(name) {
      case dict.get(declared, name) {
        Ok(_) -> False
        Error(_) -> True
      }
    })
  let message = "builtins missing ffi modes: " <> string.join(missing, ", ")
  assert list.is_empty(missing) as message
}

/// `panic` is lowered directly to a builtin, not declared in `infer.builtins`.
pub fn ffi_modes_cover_panic_test() {
  case dict.get(ffi_modes.table(), "panic") {
    Ok(_) -> Nil
    Error(_) -> panic as "panic missing ffi mode"
  }
}
