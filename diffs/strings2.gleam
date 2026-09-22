import gleam/bool
import gleam/io
import gleam/string

pub fn main() {
  io.println(bool.to_string(string.contains("hello world", "world")))
  io.println(bool.to_string(string.contains("hello", "xyz")))
  io.println(bool.to_string(string.starts_with("hello", "he")))
  io.println(bool.to_string(string.ends_with("hello", "lo")))
  io.println(string.trim("  hi there  "))
  io.println(string.replace("a-b-c", "-", "+"))
}
