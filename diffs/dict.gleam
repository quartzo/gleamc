import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/result

fn show_entries(entries: List(#(String, Int))) -> String {
  case entries {
    [] -> ""
    [#(k, v), ..rest] ->
      k <> "=" <> int.to_string(v) <> " " <> show_entries(rest)
  }
}

fn show_keys(keys: List(String)) -> String {
  case keys {
    [] -> ""
    [k, ..rest] -> k <> " " <> show_keys(rest)
  }
}

pub fn main() {
  let d = dict.from_list([#("c", 3), #("a", 1), #("b", 2), #("a", 9)])
  io.println(show_entries(dict.to_list(d)))
  io.println(show_keys(dict.keys(d)))
  io.println(int.to_string(dict.size(d)))
  io.println(int.to_string(result.unwrap(dict.get(d, "b"), 0)))
  io.println(int.to_string(result.unwrap(dict.get(d, "z"), -1)))
  io.println(show_entries(dict.to_list(dict.delete(d, "b"))))
  io.println(show_entries(dict.to_list(dict.insert(d, "a", 100))))
  io.println(show_entries(dict.to_list(dict.upsert(d, "z", fn(_) { 7 }))))
  io.println(show_entries(dict.to_list(dict.upsert(d, "a", fn(_) { 100 }))))
  io.println(int.to_string(dict.fold(d, 0, fn(acc, _, v) { acc + v })))
  io.println(show_entries(dict.to_list(dict.filter(d, fn(_, v) { v > 1 }))))
  io.println(show_keys(dict.keys(dict.map_values(d, fn(_, v) { v * 2 }))))
}
