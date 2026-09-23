//// Bindings for the Erlang shim (`gleamc_ffi.erl`) and portable library
//// calls.
////
//// Isolates all contact with the OS. The rest of the compiler only uses
//// these functions — switching target (Erlang/JS) stays confined to this
//// module. File I/O goes through `simplifile` so the same source can be
//// compiled by the official toolchain (the published package) and by
//// `gleamc` (its own `std/simplifile.gleam`).

import simplifile

/// Runs a command in the shell and returns `#(exit_status, output)`.
/// Output includes stderr (stderr_to_stdout).
@external(erlang, "gleamc_ffi", "run")
pub fn run(command: String) -> #(Int, String)

/// Reads a file as UTF-8 text.
pub fn read_file(path: String) -> Result(String, String) {
  case simplifile.read(from: path) {
    Ok(contents) -> Ok(contents)
    Error(error) -> Error(simplifile.describe_error(error))
  }
}

/// Writes UTF-8 text to a file (creates/overwrites).
pub fn write_file(path: String, contents: String) -> Result(Nil, String) {
  case simplifile.write(to: path, contents: contents) {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> Error(simplifile.describe_error(error))
  }
}

/// Resolves an executable on the PATH.
@external(erlang, "gleamc_ffi", "which")
pub fn which(name: String) -> Result(String, Nil)

/// Reads an environment variable.
@external(erlang, "gleamc_ffi", "get_env")
pub fn get_env(name: String) -> Result(String, Nil)

/// Command-line arguments.
@external(erlang, "gleamc_ffi", "argv")
pub fn argv() -> List(String)
