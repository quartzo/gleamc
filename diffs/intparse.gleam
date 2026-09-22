import gleam/int
import gleam/io
import gleam/result

pub fn main() {
  io.println(int.to_string(result.unwrap(int.parse("123"), -1)))
  io.println(int.to_string(result.unwrap(int.parse("0"), -1)))
  io.println(int.to_string(result.unwrap(int.parse("-45"), -1)))
  io.println(int.to_string(result.unwrap(int.parse("+7"), -1)))
  io.println(int.to_string(result.unwrap(int.parse("abc"), -1)))
  io.println(int.to_string(result.unwrap(int.parse("12x"), -1)))
  io.println(int.to_string(result.unwrap(int.parse(""), -1)))
}
