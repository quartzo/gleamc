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

pub fn main() {
  io.println(show(list.unique([1, 2, 1, 3, 2, 1])))
  io.println(show(list.map2([1, 2, 3], [10, 20], fn(a, b) { a + b })))
  io.println(show(list.index_map([10, 20, 30], fn(x, i) { x + i })))
  io.println(int.to_string(result.unwrap(list.last([1, 2, 3]), 0)))
  io.println(
    int.to_string(result.unwrap(list.find([1, 2, 3], fn(x) { x > 1 }), 0)),
  )
}
