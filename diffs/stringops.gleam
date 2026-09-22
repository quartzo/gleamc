import gleam/int
import gleam/io
import gleam/option
import gleam/result
import gleam/string

pub fn main() {
  io.println(string.crop("hello world", " "))
  io.println(string.remove_prefix("foobar", "foo"))
  io.println(string.remove_suffix("foobar", "bar"))
  io.println(string.capitalise("gleam"))
  let #(a, b) = result.unwrap(string.split_once("a=b", "="), #("", ""))
  io.println(a <> "/" <> b)
  io.println(int.to_string(string.byte_size("abc")))
  let #(first, rest) = result.unwrap(string.pop_grapheme("ab"), #("", ""))
  io.println(first <> "/" <> rest)
  io.println(option.unwrap(string.to_option(""), "empty"))
  io.println(option.unwrap(string.to_option("x"), "empty"))
}
