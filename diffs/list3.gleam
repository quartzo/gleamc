import gleam/int
import gleam/io
import gleam/list

fn show(xs: List(Int)) -> String {
  case xs {
    [] -> ""
    [x, ..r] -> int.to_string(x) <> "," <> show(r)
  }
}

fn show_g(gs: List(List(Int))) -> String {
  case gs {
    [] -> ""
    [g, ..r] -> "[" <> show(g) <> "]" <> show_g(r)
  }
}

pub fn main() {
  io.println(show(list.scan([1, 2, 3], 0, fn(acc, x) { acc + x })))
  io.println(show_g(list.transpose([[1, 2, 3], [4, 5, 6]])))
  io.println(show_g(list.transpose([[1, 2], [3, 4, 5]])))
}
