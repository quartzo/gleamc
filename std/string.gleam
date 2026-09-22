import gleam/list

pub fn concat(strings: List(String)) -> String {
  case strings {
    ListCons(head, rest) -> head <> concat(rest)
    ListEmpty -> ""
  }
}

pub fn join(strings: List(String), separator: String) -> String {
  case strings {
    ListCons(head, rest) -> head <> join_rest(rest, separator)
    ListEmpty -> ""
  }
}

fn join_rest(strings: List(String), separator: String) -> String {
  case strings {
    ListCons(head, rest) -> separator <> head <> join_rest(rest, separator)
    ListEmpty -> ""
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
