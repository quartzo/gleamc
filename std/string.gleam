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
