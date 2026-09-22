import gleam/int
import gleam/io
import gleam/list

fn show(xs: List(Int)) -> String {
  case xs {
    [] -> ""
    [x, ..rest] -> int.to_string(x) <> "," <> show(rest)
  }
}

fn show_g(groups: List(List(Int))) -> String {
  case groups {
    [] -> ""
    [g, ..rest] -> "[" <> show(g) <> "]" <> show_g(rest)
  }
}

pub fn main() {
  io.println(show_g(list.sized_chunk([1, 2, 3, 4, 5], 2)))
  io.println(show_g(list.sized_chunk([1, 2, 3], 5)))
  io.println(show_g(list.sized_chunk([], 3)))
}
