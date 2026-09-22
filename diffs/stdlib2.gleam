import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn show(xs: List(Int)) -> String {
  case xs {
    [] -> ""
    [x, ..rest] -> int.to_string(x) <> "," <> show(rest)
  }
}

pub fn main() {
  io.println(string.pad_start("7", 3, "0"))
  io.println(string.pad_end("7", 3, "0"))
  io.println(string.pad_start("7", 4, "ab"))
  io.println(show(list.intersperse([1, 2, 3], 0)))
  io.println(
    int.to_string(
      list.index_fold([10, 20, 30], 0, fn(acc, x, i) { acc + x * i }),
    ),
  )
  io.println(show(option.values([Some(1), None, Some(3)])))
  io.println(show(option.unwrap(option.all([Some(1), Some(2)]), [])))
  io.println(show(option.unwrap(option.all([Some(1), None]), [])))
}
