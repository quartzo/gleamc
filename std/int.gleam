import gleam/string

pub fn parse(value: String) -> Result(Int, Nil) {
  case string.length(value) == 0 {
    True -> Error(Nil)
    False ->
      case string.slice(value, 0, 1) {
        "-" ->
          case string.length(value) == 1 {
            True -> Error(Nil)
            False -> negate(parse_digits(value, 1, 0))
          }
        "+" -> parse_digits(value, 1, 0)
        _ -> parse_digits(value, 0, 0)
      }
  }
}

fn negate(result: Result(Int, Nil)) -> Result(Int, Nil) {
  case result {
    Ok(value) -> Ok(-value)
    Error(_) -> Error(Nil)
  }
}

fn parse_digits(value: String, index: Int, acc: Int) -> Result(Int, Nil) {
  case index >= string.length(value) {
    True -> Ok(acc)
    False ->
      case digit(string.slice(value, index, 1)) {
        Ok(d) -> parse_digits(value, index + 1, acc * 10 + d)
        Error(_) -> Error(Nil)
      }
  }
}

fn digit(ch: String) -> Result(Int, Nil) {
  case ch {
    "0" -> Ok(0)
    "1" -> Ok(1)
    "2" -> Ok(2)
    "3" -> Ok(3)
    "4" -> Ok(4)
    "5" -> Ok(5)
    "6" -> Ok(6)
    "7" -> Ok(7)
    "8" -> Ok(8)
    "9" -> Ok(9)
    _ -> Error(Nil)
  }
}
