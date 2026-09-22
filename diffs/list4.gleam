import gleam/int
import gleam/io
import gleam/list
import gleam/result

fn show(xs: List(Int)) -> String {
  case xs {
    [] -> ""
    [x, ..r] -> int.to_string(x) <> "," <> show(r)
  }
}

fn show_p(p: #(Int, List(Int))) -> String {
  let #(acc, xs) = p
  int.to_string(acc) <> "|" <> show(xs)
}

fn show_t(t: #(List(Int), List(Int))) -> String {
  let #(a, b) = t
  show(a) <> "|" <> show(b)
}

fn show_pairs(xs: List(#(Int, Int))) -> String {
  case xs {
    [] -> ""
    [#(a, b), ..r] ->
      "(" <> int.to_string(a) <> "," <> int.to_string(b) <> ")" <> show_pairs(r)
  }
}

pub fn main() {
  io.println(
    show_p(list.map_fold([1, 2, 3], 0, fn(acc, x) { #(acc + x, x * 2) })),
  )
  io.println(
    int.to_string(result.unwrap(
      list.reduce([1, 2, 3, 4], fn(a, b) { a + b }),
      0,
    )),
  )
  io.println(int.to_string(result.unwrap(list.reduce([], fn(a, b) { a }), -1)))
  io.println(show_pairs(list.window_by_2([1, 2, 3, 4])))
  io.println(show_t(list.split([1, 2, 3, 4], 2)))
}
