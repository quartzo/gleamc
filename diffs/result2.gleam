import gleam/bool
import gleam/int
import gleam/io
import gleam/result

fn show(xs: List(Int)) -> String {
  case xs {
    [] -> ""
    [x, ..rest] -> int.to_string(x) <> "," <> show(rest)
  }
}

pub fn main() {
  io.println(bool.to_string(result.is_ok(Ok(1))))
  io.println(bool.to_string(result.is_error(Error("e"))))
  io.println(int.to_string(result.unwrap(result.flatten(Ok(Ok(5))), 0)))
  io.println(show(result.unwrap(result.all([Ok(1), Ok(2), Ok(3)]), [])))
  io.println(show(result.unwrap(result.all([Ok(1), Error("x"), Ok(3)]), [])))
}
