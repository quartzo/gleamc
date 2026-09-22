import gleam/io
import gleam/string

fn show(xs: List(String)) -> String {
  case xs {
    [] -> ""
    [x, ..rest] -> "<" <> x <> ">" <> show(rest)
  }
}

pub fn main() {
  io.println(string.slice("hello", 1, 3))
  io.println(string.slice("hello", 0, 4))
  io.println(show(string.split("a-b-c", "-")))
  io.println(show(string.split("a,b,,c", ",")))
  io.println(show(string.split("abc", "")))
  io.println(show(string.split("", ",")))
}
