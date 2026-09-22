import gleam/dict
import gleam/int
import gleam/io
import gleam/list

fn show_entries(entries: List(#(String, Int))) -> String {
  case entries {
    [] -> ""
    [#(k, v), ..rest] ->
      k <> "=" <> int.to_string(v) <> " " <> show_entries(rest)
  }
}

fn show_list(vs: List(Int)) -> String {
  case vs {
    [] -> ""
    [v, ..r] -> int.to_string(v) <> "," <> show_list(r)
  }
}

fn show_entries_list(entries: List(#(String, List(Int)))) -> String {
  case entries {
    [] -> ""
    [#(k, vs), ..rest] ->
      k <> "=[" <> show_list(vs) <> "] " <> show_entries_list(rest)
  }
}

pub fn main() {
  let a = dict.from_list([#("a", 1), #("b", 2)])
  let b = dict.from_list([#("b", 20), #("c", 30)])
  io.println(show_entries(dict.to_list(dict.merge(a, b))))
  io.println(show_entries(dict.to_list(dict.combine(a, b, fn(x, y) { x + y }))))
  io.println(show_entries(dict.to_list(dict.take(a, ["a"]))))
  io.println(show_entries(dict.to_list(dict.drop(a, ["a"]))))
  io.println(
    show_entries_list(
      dict.to_list(dict.group(fn(x) { int.to_string(x % 2) }, [1, 2, 3, 4, 5])),
    ),
  )
}
