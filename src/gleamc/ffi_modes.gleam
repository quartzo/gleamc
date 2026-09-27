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
  // Async base: `time.timer(ms)` reads `ms` and its `Future(())` stays
  // internal; the builtin itself has no user-visible result.
  |> dict.insert("time.timer", FfiSig([Borrow], OwnedResult))
  |> dict.insert("time.timer_count", FfiSig([Borrow], OwnedResult))
  |> dict.insert("uv.fs_open", FfiSig([Borrow, Borrow, Borrow], OwnedResult))
  |> dict.insert("uv.fs_fstat", FfiSig([Borrow], OwnedResult))
  |> dict.insert("uv.fs_read", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("uv.fs_close", FfiSig([Borrow], OwnedResult))
  |> dict.insert("uv.fs_write", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("uv.fs_unlink", FfiSig([Borrow], OwnedResult))
  |> dict.insert("uv.fs_mkdir", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("uv.fs_rmdir", FfiSig([Borrow], OwnedResult))
  |> dict.insert("uv.fs_rename", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("uv.fs_symlink", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("uv.fs_link", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("uv.fs_chmod", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("uv.fs_stat", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("uv.fs_realpath", FfiSig([Borrow], OwnedResult))
  |> dict.insert("uv.fs_readdir", FfiSig([Borrow], OwnedResult))
  |> dict.insert("uv.fs_cwd", FfiSig([], OwnedResult))
  // Processes and tasks: handles and scalar messages are borrowed; the
  // subject handle is an owned result.
  |> dict.insert("process_ffi.new_subject", FfiSig([], OwnedResult))
  // The message is moved into a box; the mailbox then owns that reference.
  |> dict.insert("process_ffi.send", FfiSig([Borrow, Owned], OwnedResult))
  |> dict.insert("process_ffi.receive", FfiSig([Borrow], OwnedResult))
  |> dict.insert("process_ffi.wait_any", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert(
    "task_ffi.await_timeout",
    FfiSig([Borrow, Borrow], OwnedResult),
  )
  |> dict.insert("process.spawn", FfiSig([Borrow], OwnedResult))
  |> dict.insert("process.spawn_unlinked", FfiSig([Borrow], OwnedResult))
  |> dict.insert("process_ffi.self", FfiSig([], OwnedResult))
  |> dict.insert("process_ffi.is_alive", FfiSig([Borrow], OwnedResult))
  |> dict.insert("task_ffi.pid", FfiSig([Borrow], OwnedResult))
  |> dict.insert(
    "process_ffi.send_after",
    FfiSig([Borrow, Borrow, Owned], OwnedResult),
  )
  |> dict.insert("process_ffi.cancel_timer", FfiSig([Borrow], OwnedResult))
  |> dict.insert("process_ffi.monitor", FfiSig([Borrow], OwnedResult))
  |> dict.insert("process_ffi.kill", FfiSig([Borrow], OwnedResult))
  |> dict.insert("process_ffi.new_name", FfiSig([], OwnedResult))
  |> dict.insert("process_ffi.register", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("process_ffi.unregister", FfiSig([Borrow], OwnedResult))
  |> dict.insert("process_ffi.named", FfiSig([Borrow], OwnedResult))
  |> dict.insert("process_ffi.named_subject", FfiSig([Borrow], OwnedResult))
  |> dict.insert("process_ffi.pid_of_int", FfiSig([Borrow], OwnedResult))
  |> dict.insert("process_ffi.demonitor", FfiSig([Borrow], OwnedResult))
  |> dict.insert("process_ffi.self_down_inbox", FfiSig([], OwnedResult))
  |> dict.insert("process_ffi.self_exit_inbox", FfiSig([], OwnedResult))
  |> dict.insert("process_ffi.trap_exits", FfiSig([Borrow], OwnedResult))
  |> dict.insert("process_ffi.link", FfiSig([Borrow], OwnedResult))
  |> dict.insert("process_ffi.unlink", FfiSig([Borrow], OwnedResult))
  |> dict.insert("process_ffi.selector_new", FfiSig([], OwnedResult))
  |> dict.insert(
    "process_ffi.selector_add",
    FfiSig([Borrow, Borrow], OwnedResult),
  )
  |> dict.insert(
    "process_ffi.selector_remove",
    FfiSig([Borrow, Borrow], OwnedResult),
  )
  |> dict.insert(
    "process_ffi.selector_wait",
    FfiSig([Borrow, Borrow], OwnedResult),
  )
  |> dict.insert("process_ffi.selector_ready", FfiSig([Borrow], OwnedResult))
  |> dict.insert(
    "process_ffi.selector_subject",
    FfiSig([Borrow, Borrow], OwnedResult),
  )
  |> dict.insert("task.async", FfiSig([Borrow], OwnedResult))
  |> dict.insert("task_ffi.await", FfiSig([Borrow], OwnedResult))
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
  |> dict.insert("float.raw_exponential", FfiSig([Borrow], OwnedResult))
  |> dict.insert("float.raw_logarithm", FfiSig([Borrow], OwnedResult))
  |> dict.insert("int.bitwise_and", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("int.bitwise_or", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert(
    "int.bitwise_exclusive_or",
    FfiSig([Borrow, Borrow], OwnedResult),
  )
  |> dict.insert("int.bitwise_not", FfiSig([Borrow], OwnedResult))
  |> dict.insert(
    "int.bitwise_shift_left",
    FfiSig([Borrow, Borrow], OwnedResult),
  )
  |> dict.insert(
    "int.bitwise_shift_right",
    FfiSig([Borrow, Borrow], OwnedResult),
  )
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
  |> dict.insert("bit_array.int64_at", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("bit_array.append", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("bit_array.bit_size", FfiSig([Borrow], OwnedResult))
  |> dict.insert("gleamc.key_compare", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("gleamc.show", FfiSig([Borrow], OwnedResult))
  |> dict.insert("gleamc.hash", FfiSig([Borrow], OwnedResult))
  // `Buffer(a)`: all arguments are borrowed; `set`'s value is retained by the
  // runtime, so ownership never transfers.
  |> dict.insert("buffer.new", FfiSig([Borrow], OwnedResult))
  |> dict.insert("buffer.len", FfiSig([Borrow], OwnedResult))
  |> dict.insert("buffer.get", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("buffer.set", FfiSig([Borrow, Borrow, Borrow], OwnedResult))
  |> dict.insert("buffer.is_null", FfiSig([Borrow], OwnedResult))
  |> dict.insert("buffer.take", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("io.debug", FfiSig([Borrow], OwnedResult))
  |> dict.insert("bit_array.is_utf8", FfiSig([Borrow], OwnedResult))
  |> dict.insert("host.run", FfiSig([Borrow], OwnedResult))
  |> dict.insert("host.argv", FfiSig([], OwnedResult))
  |> dict.insert("host.get_env", FfiSig([Borrow], OwnedResult))
  |> dict.insert("host.which", FfiSig([Borrow], OwnedResult))
  |> dict.insert("host.now_ms", FfiSig([], OwnedResult))
  |> dict.insert("host.blob_slice", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("host.int64_at", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("host.char_code_at", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("host.char_byte_len", FfiSig([Borrow, Borrow], OwnedResult))
  |> dict.insert("host.byte_slice", FfiSig([Borrow, Borrow, Borrow], OwnedResult))
}
