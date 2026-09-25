//// Bindings for the host OS through the `host` module and portable library
//// calls.
////
//// Isolates all contact with the OS. The rest of the compiler only uses
//// these functions — switching host (Erlang bootstrap or the gleamc C
//// runtime) stays confined to this module and `host`. File I/O goes through
//// `simplifile` so the same source compiles under the official toolchain (the
//// published package) and under `gleamc` (its own `std/simplifile.gleam`).

import gleam/bit_array
import gleam/string
import host
import simplifile

/// Runs a command in the shell and returns `#(exit_status, output)`.
/// Output includes stderr (stderr_to_stdout).
pub fn run(command: String) -> #(Int, String) {
  let blob = host.run(command)
  let status = host.int64_at(blob, 0)
  let output = case bit_array.to_string(host.blob_slice(blob, 8)) {
    Ok(text) -> text
    Error(_) -> ""
  }
  #(status, output)
}

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
pub fn which(name: String) -> Result(String, Nil) {
  case host.which(name) {
    "" -> Error(Nil)
    path -> Ok(path)
  }
}

/// Monotonic milliseconds (phase timing).
pub fn now_ms() -> Int {
  host.now_ms()
}

/// Reads an environment variable.
pub fn get_env(name: String) -> Result(String, Nil) {
  case host.get_env(name) {
    "" -> Error(Nil)
    value -> Ok(value)
  }
}

/// Command-line arguments.
pub fn argv() -> List(String) {
  case bit_array.to_string(host.argv()) {
    Ok("") -> []
    Ok(text) -> string.split(text, separator())
    Error(_) -> []
  }
}

fn separator() -> String {
  case string.utf_codepoint(31) {
    Ok(codepoint) -> string.from_utf_codepoints([codepoint])
    Error(_) -> "\n"
  }
}
