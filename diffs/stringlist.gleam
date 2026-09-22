import gleam/bool
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string

fn show(xs: List(Int)) -> String {
  case xs {
    [] -> ""
    [x, ..rest] -> int.to_string(x) <> "," <> show(rest)
  }
}

fn show2(xss: List(List(Int))) -> String {
  case xss {
    [] -> ""
    [xs, ..rest] -> "[" <> show(xs) <> "]" <> show2(rest)
  }
}

pub fn main() {
  io.println(string.trim_start("  hi  ") <> "|")
  io.println(string.trim_end("  hi  ") <> "|")
  io.println(string.drop_start("hello", 2))
  io.println(string.drop_end("hello", 2))
  io.println(result.unwrap(string.first("abc"), ""))
  io.println(result.unwrap(string.last("abc"), ""))
  io.println(bool.to_string(string.is_empty("")))
  io.println(show(list.take_while([1, 2, 3, 1], fn(x) { x < 3 })))
  io.println(show(list.drop_while([1, 2, 3, 1], fn(x) { x < 3 })))
  io.println(show2(list.window([1, 2, 3, 4], 2)))
}
