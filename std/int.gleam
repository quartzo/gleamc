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

pub fn to_base_string(value: Int, base: Int) -> Result(String, Nil) {
  Ok(int.raw_to_base_string(value, base))
}

pub fn base_parse(value: String, base: Int) -> Result(Int, Nil) {
  case base < 2 || base > 36 {
    True -> Error(Nil)
    False ->
      case string.length(value) == 0 {
        True -> Error(Nil)
        False ->
          case string.slice(value, 0, 1) {
            "-" -> negate(base_parse_digits(value, 1, base, 0))
            "+" -> base_parse_digits(value, 1, base, 0)
            _ -> base_parse_digits(value, 0, base, 0)
          }
      }
  }
}

fn base_parse_digits(
  value: String,
  index: Int,
  base: Int,
  acc: Int,
) -> Result(Int, Nil) {
  case index >= string.length(value) {
    True -> Ok(acc)
    False ->
      case digit_value(string.slice(value, index, 1), base) {
        Ok(digit) ->
          base_parse_digits(value, index + 1, base, acc * base + digit)
        Error(_) -> Error(Nil)
      }
  }
}

fn digit_value(ch: String, base: Int) -> Result(Int, Nil) {
  let value = case string.lowercase(ch) {
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
    "a" -> Ok(10)
    "b" -> Ok(11)
    "c" -> Ok(12)
    "d" -> Ok(13)
    "e" -> Ok(14)
    "f" -> Ok(15)
    "g" -> Ok(16)
    "h" -> Ok(17)
    "i" -> Ok(18)
    "j" -> Ok(19)
    "k" -> Ok(20)
    "l" -> Ok(21)
    "m" -> Ok(22)
    "n" -> Ok(23)
    "o" -> Ok(24)
    "p" -> Ok(25)
    "q" -> Ok(26)
    "r" -> Ok(27)
    "s" -> Ok(28)
    "t" -> Ok(29)
    "u" -> Ok(30)
    "v" -> Ok(31)
    "w" -> Ok(32)
    "x" -> Ok(33)
    "y" -> Ok(34)
    "z" -> Ok(35)
    _ -> Error(Nil)
  }
  case value {
    Ok(digit) ->
      case digit < base {
        True -> Ok(digit)
        False -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}
