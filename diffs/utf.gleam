import gleam/int
import gleam/io
import gleam/list
import gleam/string

fn ints(xs: List(Int)) -> String {
  case xs {
    [] -> ""
    [x, ..rest] -> int.to_string(x) <> "," <> ints(rest)
  }
}

fn codes(value: String) -> String {
  value
  |> string.to_utf_codepoints
  |> list.map(string.utf_codepoint_to_int)
  |> ints
}

pub fn main() {
  let assert Ok(a) = string.utf_codepoint(97)
  let assert Ok(b) = string.utf_codepoint(233)
  let assert Ok(c) = string.utf_codepoint(128_512)
  let sample = string.from_utf_codepoints([a, b, c])
  io.println(codes(sample))
  io.println(codes(""))
  io.println(sample)
  io.println(case string.utf_codepoint(55_296) {
    Ok(_) -> "ok"
    Error(_) -> "err"
  })
  io.println(case string.utf_codepoint(-1) {
    Ok(_) -> "ok"
    Error(_) -> "err"
  })
  io.println(int.to_string(string.utf_codepoint_to_int(a)))
}
