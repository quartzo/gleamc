//// Host process/environment bindings.
////
//// These `@external(erlang, ...)` declarations exist only so the compiler
//// still runs under the official toolchain (bootstrap). Under gleamc this
//// module is ignored and `host.*` resolve to C runtime builtins
//// (`Gleamc_host_*`). The compiler's `ffi` module wraps them.

/// Runs a shell command and returns a blob: an 8-byte little-endian exit
/// status followed by the combined stdout/stderr.
@external(erlang, "gleamc_ffi", "run_blob")
pub fn run(command: String) -> BitArray

/// Command-line arguments joined by the unit separator (0x1f).
@external(erlang, "gleamc_ffi", "argv_blob")
pub fn argv() -> BitArray

/// Reads an environment variable, or `""` when unset.
@external(erlang, "gleamc_ffi", "get_env_bin")
pub fn get_env(name: String) -> String

/// Resolves an executable on the PATH, or `""` when not found.
@external(erlang, "gleamc_ffi", "which_bin")
pub fn which(name: String) -> String

/// Returns `blob` from `offset` to the end.
@external(erlang, "gleamc_ffi", "blob_slice")
pub fn blob_slice(blob: BitArray, offset: Int) -> BitArray

/// Reads a little-endian int64 at `index` (0-based, over 8-byte fields).
@external(erlang, "gleamc_ffi", "int64_at")
pub fn int64_at(blob: BitArray, index: Int) -> Int

/// Unicode codepoint at byte offset `off`, or -1 past the end.
@external(erlang, "gleamc_ffi", "char_code_at")
pub fn char_code_at(string: String, off: Int) -> Int

/// Byte length of the character starting at byte offset `off` (0 past the end).
@external(erlang, "gleamc_ffi", "char_byte_len")
pub fn char_byte_len(string: String, off: Int) -> Int

/// Copies `len` bytes from byte offset `start`.
@external(erlang, "gleamc_ffi", "byte_slice")
pub fn byte_slice(string: String, start: Int, len: Int) -> String
