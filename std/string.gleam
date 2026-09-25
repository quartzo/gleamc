import gleam/list
import gleam/option
import gleam/order

pub fn concat(strings: List(String)) -> String {
  case strings {
    ListCons(head, rest) -> concat_loop(rest, head)
    ListEmpty -> ""
  }
}

fn concat_loop(strings: List(String), acc: String) -> String {
  case strings {
    ListCons(head, rest) -> concat_loop(rest, acc <> head)
    ListEmpty -> acc
  }
}

pub fn join(strings: List(String), separator: String) -> String {
  case strings {
    ListCons(head, rest) -> join_loop(rest, separator, head)
    ListEmpty -> ""
  }
}

fn join_loop(strings: List(String), separator: String, acc: String) -> String {
  case strings {
    ListCons(head, rest) -> join_loop(rest, separator, acc <> separator <> head)
    ListEmpty -> acc
  }
}

pub fn split(value: String, pattern: String) -> List(String) {
  case string.length(pattern) == 0 {
    True -> split_graphemes(value, [])
    False -> split_loop(value, pattern, "", [])
  }
}

fn split_graphemes(value: String, acc: List(String)) -> List(String) {
  case string.length(value) == 0 {
    True -> list.reverse(acc)
    False ->
      split_graphemes(string.slice(value, 1, string.length(value) - 1), [
        string.slice(value, 0, 1),
        ..acc
      ])
  }
}

fn split_loop(
  value: String,
  pattern: String,
  current: String,
  acc: List(String),
) -> List(String) {
  case string.length(value) == 0 {
    True -> list.reverse(ListCons(current, acc))
    False ->
      case string.starts_with(value, pattern) {
        True ->
          split_loop(
            string.slice(
              value,
              string.length(pattern),
              string.length(value) - string.length(pattern),
            ),
            pattern,
            "",
            ListCons(current, acc),
          )
        False ->
          split_loop(
            string.slice(value, 1, string.length(value) - 1),
            pattern,
            current <> string.slice(value, 0, 1),
            acc,
          )
      }
  }
}

pub fn repeat(string: String, times: Int) -> String {
  case times <= 0 {
    True -> ""
    False -> string <> repeat(string, times - 1)
  }
}

pub fn pad_start(string: String, desired_length: Int, with: String) -> String {
  let missing = desired_length - string.length(string)
  case missing <= 0 {
    True -> string
    False -> pad_for(with, missing) <> string
  }
}

pub fn pad_end(string: String, desired_length: Int, with: String) -> String {
  let missing = desired_length - string.length(string)
  case missing <= 0 {
    True -> string
    False -> string <> pad_for(with, missing)
  }
}

fn pad_for(with: String, missing: Int) -> String {
  case string.length(with) == 0 {
    True -> ""
    False -> {
      let needed = missing / string.length(with) + 1
      string.slice(repeat(with, needed), 0, missing)
    }
  }
}

pub fn to_graphemes(string: String) -> List(String) {
  split(string, "")
}

pub fn is_empty(value: String) -> Bool {
  string.length(value) == 0
}

pub fn drop_start(value: String, up_to: Int) -> String {
  let len = string.length(value)
  case up_to <= 0 {
    True -> value
    False -> string.slice(value, min_int(up_to, len), max_int(len - up_to, 0))
  }
}

pub fn drop_end(value: String, up_to: Int) -> String {
  let len = string.length(value)
  case up_to <= 0 {
    True -> value
    False -> string.slice(value, 0, max_int(len - up_to, 0))
  }
}

pub fn first(value: String) -> Result(String, Nil) {
  case string.length(value) == 0 {
    True -> Error(Nil)
    False -> Ok(string.slice(value, 0, 1))
  }
}

pub fn last(value: String) -> Result(String, Nil) {
  let len = string.length(value)
  case len == 0 {
    True -> Error(Nil)
    False -> Ok(string.slice(value, len - 1, 1))
  }
}

fn min_int(a: Int, b: Int) -> Int {
  case a < b {
    True -> a
    False -> b
  }
}

fn max_int(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

pub fn split_once(
  value: String,
  pattern: String,
) -> Result(#(String, String), Nil) {
  split_once_loop(value, pattern, "")
}

fn split_once_loop(
  value: String,
  pattern: String,
  prefix: String,
) -> Result(#(String, String), Nil) {
  case string.length(value) == 0 {
    True -> Error(Nil)
    False ->
      case string.starts_with(value, pattern) {
        True ->
          Ok(#(
            prefix,
            string.slice(
              value,
              string.length(pattern),
              string.length(value) - string.length(pattern),
            ),
          ))
        False ->
          split_once_loop(
            string.slice(value, 1, string.length(value) - 1),
            pattern,
            prefix <> string.slice(value, 0, 1),
          )
      }
  }
}

pub fn crop(value: String, before: String) -> String {
  case split_once(value, before) {
    Ok(#(_, after)) -> before <> after
    Error(_) -> value
  }
}

pub fn remove_prefix(value: String, prefix: String) -> String {
  case string.starts_with(value, prefix) {
    True ->
      string.slice(
        value,
        string.length(prefix),
        string.length(value) - string.length(prefix),
      )
    False -> value
  }
}

pub fn remove_suffix(value: String, suffix: String) -> String {
  case string.ends_with(value, suffix) {
    True -> string.slice(value, 0, string.length(value) - string.length(suffix))
    False -> value
  }
}

pub fn capitalise(value: String) -> String {
  case string.length(value) == 0 {
    True -> value
    False ->
      string.uppercase(string.slice(value, 0, 1))
      <> string.slice(value, 1, string.length(value) - 1)
  }
}

pub fn pop_grapheme(value: String) -> Result(#(String, String), Nil) {
  case string.length(value) == 0 {
    True -> Error(Nil)
    False ->
      Ok(#(
        string.slice(value, 0, 1),
        string.slice(value, 1, string.length(value) - 1),
      ))
  }
}

pub fn to_option(value: String) -> Option(String) {
  case string.length(value) == 0 {
    True -> option.None
    False -> option.Some(value)
  }
}

pub fn compare(a: String, b: String) -> Order {
  let ordering = string.compare_bytes(a, b)
  case ordering < 0 {
    True -> order.Lt
    False ->
      case ordering > 0 {
        True -> order.Gt
        False -> order.Eq
      }
  }
}

pub fn inspect(term: a) -> String {
  gleamc.show(term)
}

pub opaque type UtfCodepoint {
  UtfCodepoint(value: Int)
}

pub fn utf_codepoint(value: Int) -> Result(UtfCodepoint, Nil) {
  case value > 1_114_111 {
    True -> Error(Nil)
    False ->
      case value >= 55_296 && value <= 57_343 {
        True -> Error(Nil)
        False ->
          case value < 0 {
            True -> Error(Nil)
            False -> Ok(UtfCodepoint(value))
          }
      }
  }
}

pub fn utf_codepoint_to_int(cp: UtfCodepoint) -> Int {
  case cp {
    UtfCodepoint(value) -> value
  }
}

pub fn to_utf_codepoints(value: String) -> List(UtfCodepoint) {
  to_utf_codepoints_loop(value, 0, string.length(value), [])
}

fn to_utf_codepoints_loop(
  value: String,
  index: Int,
  count: Int,
  acc: List(UtfCodepoint),
) -> List(UtfCodepoint) {
  case index >= count {
    True -> list.reverse(acc)
    False ->
      to_utf_codepoints_loop(value, index + 1, count, [
        UtfCodepoint(string.raw_codepoint_at(value, index)),
        ..acc
      ])
  }
}

pub fn from_utf_codepoints(cps: List(UtfCodepoint)) -> String {
  case cps {
    [] -> ""
    [cp, ..rest] ->
      string.raw_codepoint_to_string(utf_codepoint_to_int(cp))
      <> from_utf_codepoints(rest)
  }
}
