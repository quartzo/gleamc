import gleam/int
import gleam/io
import gleam/list
import gleam/result

fn show(xs: List(Int)) -> String {
  case xs {
    [] -> ""
    [x, ..rest] -> int.to_string(x) <> "," <> show(rest)
  }
}

fn show_groups(groups: List(List(Int))) -> String {
  case groups {
    [] -> ""
    [g, ..rest] -> "[" <> show(g) <> "]" <> show_groups(rest)
  }
}

pub fn main() {
  io.println(int.to_string(result.unwrap(int.base_parse("FF", 16), -1)))
  io.println(int.to_string(result.unwrap(int.base_parse("ff", 16), -1)))
  io.println(int.to_string(result.unwrap(int.base_parse("-101", 2), -1)))
  io.println(int.to_string(result.unwrap(int.base_parse("zz", 36), -1)))
  io.println(int.to_string(result.unwrap(int.base_parse("xyz", 10), -1)))
  io.println(show_groups(list.chunk([1, 1, 2, 3, 3, 3], fn(x) { x })))
}
