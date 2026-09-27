//// Bindings for the host OS through the `host` module and portable library
//// calls.
////
//// Isolates all contact with the OS. The rest of the compiler only uses
//// these functions — switching host (Erlang bootstrap or the gleamc C
//// runtime) stays confined to this module and `host`. File I/O goes through
//// `simplifile` so the same source compiles under the official toolchain (the
//// published package) and under `gleamc` (its own `std/simplifile.gleam`).

import gleam/bit_array
import gleam/list
import gleam/result
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

/// Bytes buffered before each flush when streaming chunks (see `write_chunks`).
const flush_bytes = 4_194_304

/// Writes a sequence of chunks to a file without ever materialising the whole
/// document: chunks are buffered and flushed every `flush_bytes`, so peak
/// memory stays bounded and the file is written through one open at a time.
pub fn write_chunks(path: String, chunks: List(String)) -> Result(Nil, String) {
  do_write_chunks(path, chunks, [], 0, True)
}

fn do_write_chunks(path, chunks, buf, size, first) {
  case chunks {
    [] ->
      case buf {
        [] -> Ok(Nil)
        _ -> flush_chunks(path, buf, first)
      }
    [chunk, ..rest] -> {
      let size = size + string.byte_size(chunk)
      case size >= flush_bytes {
        True -> {
          use _ <- result.try(flush_chunks(path, [chunk, ..buf], first))
          do_write_chunks(path, rest, [], 0, False)
        }
        False -> do_write_chunks(path, rest, [chunk, ..buf], size, first)
      }
    }
  }
}

fn flush_chunks(path, buf, first) {
  let text = string.join(list.reverse(buf), "")
  let result = case first {
    True -> simplifile.write(to: path, contents: text)
    False -> simplifile.append(to: path, contents: text)
  }
  case result {
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
