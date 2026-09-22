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
  io.println(int.to_string(result.unwrap(result.replace(Ok(1), 9), 0)))
  io.println(int.to_string(result.unwrap(result.or(Error("a"), Ok(5)), 0)))
  io.println(int.to_string(result.lazy_unwrap(Error("e"), fn() { 7 })))
  io.println(int.to_string(result.unwrap_error(Error(2), 0)))
  io.println(
    int.to_string(result.unwrap(result.replace_error(Error("x"), 5), 0)),
  )
  io.println(show(result.values([Ok(1), Error(2), Ok(3)])))
  let #(oks, errors) = result.partition([Ok(1), Error(2), Ok(3)])
  io.println(show(oks) <> "/" <> show(errors))
}
