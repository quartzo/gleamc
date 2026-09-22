import gleam/int
import gleam/io
import gleam/list

fn show(xs: List(Int)) -> String {
  case xs {
    [] -> ""
    [x, ..rest] -> int.to_string(x) <> "," <> show(rest)
  }
}

pub fn main() {
  io.println(
    show(
      list.filter_map([1, 2, 3, 4], fn(x) {
        case x > 2 {
          True -> Ok(x * 10)
          False -> Error(Nil)
        }
      }),
    ),
  )
  io.println(show(list.filter_map([5, 6], fn(x) { Ok(x + 1) })))
}
