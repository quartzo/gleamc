import gleam/int
import gleam/order
import gleam/string

pub fn power(base: Float, exponent: Float) -> Result(Float, Nil) {
  Ok(float.raw_power(base, exponent))
}

pub fn square_root(value: Float) -> Result(Float, Nil) {
  Ok(float.raw_square_root(value))
}

pub fn parse(value: String) -> Result(Float, Nil) {
  case value {
    "" -> Error(Nil)
    _ -> {
      let #(sign, body) = case string.slice(value, 0, 1) {
        "-" -> #(-1.0, string.drop_start(value, 1))
        "+" -> #(1.0, string.drop_start(value, 1))
        _ -> #(1.0, value)
      }
      parse_unsigned(body, sign)
    }
  }
}

fn parse_unsigned(body: String, sign: Float) -> Result(Float, Nil) {
  case split_exponent(body) {
    Error(_) -> Error(Nil)
    Ok(#(mantissa, exponent)) ->
      case split_dot(mantissa) {
        Error(_) -> Error(Nil)
        Ok(#(int_part, frac_part)) ->
          case int.base_parse(int_part, 10), int.base_parse(frac_part, 10) {
            Ok(whole), Ok(fraction) -> {
              let scale = pow10(string.length(frac_part))
              let whole_float = int.to_float(whole)
              let fraction_float = int.to_float(fraction) /. scale
              let value = sign *. whole_float +. sign *. fraction_float
              Ok(value *. pow10(exponent))
            }
            _, _ -> Error(Nil)
          }
      }
  }
}

fn split_exponent(body: String) -> Result(#(String, Int), Nil) {
  scan_exponent(body, 0)
}

fn scan_exponent(body: String, index: Int) -> Result(#(String, Int), Nil) {
  case index >= string.length(body) {
    True -> Ok(#(body, 0))
    False ->
      case string.slice(body, index, 1) {
        "e" -> exponent_at(body, index)
        "E" -> exponent_at(body, index)
        _ -> scan_exponent(body, index + 1)
      }
  }
}

fn exponent_at(body: String, index: Int) -> Result(#(String, Int), Nil) {
  let mantissa = string.slice(body, 0, index)
  let digits = string.slice(body, index + 1, string.length(body) - index - 1)
  case int.base_parse(digits, 10) {
    Ok(exponent) -> Ok(#(mantissa, exponent))
    Error(_) -> Error(Nil)
  }
}

fn split_dot(mantissa: String) -> Result(#(String, String), Nil) {
  scan_dot(mantissa, 0)
}

fn scan_dot(mantissa: String, index: Int) -> Result(#(String, String), Nil) {
  case index >= string.length(mantissa) {
    True -> Error(Nil)
    False ->
      case string.slice(mantissa, index, 1) {
        "." ->
          Ok(#(
            string.slice(mantissa, 0, index),
            string.slice(
              mantissa,
              index + 1,
              string.length(mantissa) - index - 1,
            ),
          ))
        _ -> scan_dot(mantissa, index + 1)
      }
  }
}

fn pow10(exponent: Int) -> Float {
  case exponent > 0 {
    True -> pow10_loop(exponent, 1.0)
    False ->
      case exponent < 0 {
        True -> 1.0 /. pow10_loop(-exponent, 1.0)
        False -> 1.0
      }
  }
}

fn pow10_loop(exponent: Int, acc: Float) -> Float {
  case exponent <= 0 {
    True -> acc
    False -> pow10_loop(exponent - 1, acc *. 10.0)
  }
}

pub fn compare(a: Float, b: Float) -> Order {
  case a <. b {
    True -> order.Lt
    False ->
      case a >. b {
        True -> order.Gt
        False -> order.Eq
      }
  }
}

pub fn add(a: Float, b: Float) -> Float {
  a +. b
}

pub fn subtract(a: Float, b: Float) -> Float {
  a -. b
}

pub fn multiply(a: Float, b: Float) -> Float {
  a *. b
}

pub fn negate(x: Float) -> Float {
  -x
}

pub fn sum(numbers: List(Float)) -> Float {
  list.fold(numbers, 0.0, fn(acc, x) { acc +. x })
}

pub fn product(numbers: List(Float)) -> Float {
  list.fold(numbers, 1.0, fn(acc, x) { acc *. x })
}

pub fn divide(a: Float, by: Float) -> Result(Float, Nil) {
  case by == 0.0 {
    True -> Error(Nil)
    False -> Ok(a /. by)
  }
}

pub fn modulo(dividend: Float, by: Float) -> Result(Float, Nil) {
  case by == 0.0 {
    True -> Error(Nil)
    False -> {
      let quotient = int.to_float(float.truncate(dividend /. by))
      let r = dividend -. quotient *. by
      let negative_r = r <. 0.0
      let negative_by = by <. 0.0
      case r == 0.0 {
        True -> Ok(0.0)
        False ->
          case negative_r == negative_by {
            True -> Ok(r)
            False -> Ok(r +. by)
          }
      }
    }
  }
}

pub fn clamp(x: Float, min: Float, max: Float) -> Float {
  let #(lo, hi) = case min <=. max {
    True -> #(min, max)
    False -> #(max, min)
  }
  case x <. lo {
    True -> lo
    False ->
      case x >. hi {
        True -> hi
        False -> x
      }
  }
}

pub fn exponential(x: Float) -> Float {
  float.raw_exponential(x)
}

pub fn logarithm(x: Float) -> Result(Float, Nil) {
  case x <=. 0.0 {
    True -> Error(Nil)
    False -> Ok(float.raw_logarithm(x))
  }
}

pub fn loosely_compare(a: Float, with: Float, tolerating: Float) -> Order {
  case float.absolute_value(a -. with) <=. tolerating {
    True -> order.Eq
    False -> compare(a, with)
  }
}

pub fn loosely_equals(a: Float, with: Float, tolerating: Float) -> Bool {
  case loosely_compare(a, with: with, tolerating: tolerating) {
    order.Eq -> True
    _ -> False
  }
}

pub fn to_precision(x: Float, precision: Int) -> Float {
  let scale = pow10(precision)
  int.to_float(float.round(x *. scale)) /. scale
}
