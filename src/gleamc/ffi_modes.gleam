//// FFI parameter modes.
////
//// Runtime builtins have no body the compiler can analyse, so their ownership
//// modes are declared explicitly here (unlike Gleam functions, whose modes the
//// `borrow` pass infers). `Borrow` means the value is only read: the caller
//// keeps ownership, no refcount is touched and the C prototype is `const`.
//// `Owned` means the call takes over the reference, which is what lets a C
//// builtin reuse or mutate the value in place.
////
//// Adding a builtin requires an entry here; `test/ffi_modes_test.gleam` checks
//// coverage against `infer.builtin_names`.

import gleam/dict.{type Dict}

pub type ParamMode {
  Borrow
  Owned
}

/// How a builtin's result relates to its inputs. Every current builtin returns
/// a fresh value (or a scalar), so `OwnedResult` is the norm.
pub type ReturnMode {
  OwnedResult
  BorrowedResult
}

pub type FfiSig {
  FfiSig(params: List(ParamMode), ret: ReturnMode)
}

/// The declared mode of parameter `index`. A declaration shorter than the
/// argument list fails safe to `Owned`.
pub fn mode_at(modes: List(ParamMode), index: Int) -> ParamMode {
  case modes, index {
    [], _ -> Owned
    [mode, ..], 0 -> mode
    [_, ..rest], n -> mode_at(rest, n - 1)
  }
}

/// Explicit mode for every builtin `OpBuiltin` can name: parameter modes first
/// (one per argument), then the return mode. Most builtins `Borrow` every
/// argument and return a fresh value (`OwnedResult`); `string.uppercase` and
/// `string.lowercase` take their argument `Owned` so the C runtime can reuse it
/// in place. Marking one `Owned` is a deliberate step that must be honoured in
/// C.
pub fn table() -> Dict(String, FfiSig) {
  dict.new()
  |> dict.insert("panic", FfiSig([Borrow], OwnedResult))
  |> dict.insert("io.println", FfiSig([Borrow], OwnedResult))
  |> dict.insert("io.print", FfiSig([Borrow], OwnedResult))
  |> dict.insert("int.to_string", FfiSig([Borrow], OwnedResult))
  |> dict.insert("float.to_string", FfiSig([Borrow], OwnedResult))
  |> dict.insert("bool.to_string", FfiSig([Borrow], OwnedResult))
  |> dict.insert("int.min", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("int.max", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("int.absolute_value", FfiSig([Borrow], OwnedResult))
  |> dict.insert("float.min", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("float.max", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("float.absolute_value", FfiSig([Borrow], OwnedResult))
  |> dict.insert("float.floor", FfiSig([Borrow], OwnedResult))
  |> dict.insert("float.ceiling", FfiSig([Borrow], OwnedResult))
  |> dict.insert("float.round", FfiSig([Borrow], OwnedResult))
  |> dict.insert("float.truncate", FfiSig([Borrow], OwnedResult))
  |> dict.insert("float.raw_power", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("float.raw_square_root", FfiSig([Borrow], OwnedResult))
  |> dict.insert(
    "int.raw_to_base_string",
    FfiSig([Borrow, Borrow], OwnedResult),
  )
  |> dict.insert("int.to_float", FfiSig([Borrow], OwnedResult))
  |> dict.insert("string.compare_bytes", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert(
    "string.raw_codepoint_at",
    FfiSig([Borrow, Borrow], OwnedResult),
  )
  |> dict.insert(
    "string.raw_codepoint_to_string",
    FfiSig([Borrow], OwnedResult),
  )
  |> dict.insert("string.contains", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("string.starts_with", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("string.ends_with", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("string.trim", FfiSig([Borrow], OwnedResult))
  |> dict.insert("string.trim_start", FfiSig([Borrow], OwnedResult))
  |> dict.insert("string.trim_end", FfiSig([Borrow], OwnedResult))
  |> dict.insert(
    "string.replace",
    FfiSig([Borrow, Borrow, Borrow], OwnedResult),
  )
  |> dict.insert("string.byte_size", FfiSig([Borrow], OwnedResult))
  |> dict.insert("string.slice", FfiSig([Borrow, Borrow, Borrow], OwnedResult))
  |> dict.insert("string.length", FfiSig([Borrow], OwnedResult))
  |> dict.insert("string.append", FfiSig([Borrow, Borrow], OwnedResult))
  // Same-length transforms: the runtime reuses the buffer when uniquely owned.
  |> dict.insert("string.uppercase", FfiSig([Owned], OwnedResult))
  |> dict.insert("string.lowercase", FfiSig([Owned], OwnedResult))
  |> dict.insert("string.reverse", FfiSig([Borrow], OwnedResult))
  |> dict.insert("bit_array.from_string", FfiSig([Borrow], OwnedResult))
  |> dict.insert("bit_array.raw_to_string", FfiSig([Borrow], OwnedResult))
  |> dict.insert("bit_array.byte_size", FfiSig([Borrow], OwnedResult))
  |> dict.insert("bit_array.byte", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("bit_array.append", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("bit_array.bit_size", FfiSig([Borrow], OwnedResult))
  |> dict.insert("gleamc.key_compare", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("gleamc.show", FfiSig([Borrow], OwnedResult))
  |> dict.insert("io.debug", FfiSig([Borrow], OwnedResult))
  // File system wrappers return the fixed `FileResult` struct; only the
  // `result_data` accessor hands out an owned BitArray.
  |> dict.insert("bit_array.is_utf8", FfiSig([Borrow], OwnedResult))
  |> dict.insert("fs.read", FfiSig([Borrow], OwnedResult))
  |> dict.insert("fs.write", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("fs.append", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("fs.delete", FfiSig([Borrow], OwnedResult))
  |> dict.insert("fs.create_directory", FfiSig([Borrow], OwnedResult))
  |> dict.insert("fs.create_file", FfiSig([Borrow], OwnedResult))
  |> dict.insert("fs.exists", FfiSig([Borrow], OwnedResult))
  |> dict.insert("fs.is_file", FfiSig([Borrow], OwnedResult))
  |> dict.insert("fs.is_directory", FfiSig([Borrow], OwnedResult))
  |> dict.insert("fs.file_size", FfiSig([Borrow], OwnedResult))
  |> dict.insert("fs.current_directory", FfiSig([], OwnedResult))
  |> dict.insert("fs.read_directory", FfiSig([Borrow], OwnedResult))
  |> dict.insert("fs.file_info", FfiSig([Borrow], OwnedResult))
  |> dict.insert("fs.link_info", FfiSig([Borrow], OwnedResult))
  |> dict.insert("fs.rename", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("fs.symlink", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("fs.link", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("fs.touch", FfiSig([Borrow], OwnedResult))
  |> dict.insert("fs.realpath", FfiSig([Borrow], OwnedResult))
  |> dict.insert("fs.chmod", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("fs.int64_at", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("fs.result_code", FfiSig([Borrow], OwnedResult))
  |> dict.insert("fs.result_size", FfiSig([Borrow], OwnedResult))
  |> dict.insert("fs.result_data", FfiSig([Borrow], OwnedResult))
}
