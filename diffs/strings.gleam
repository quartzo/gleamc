import gleam/int
import gleam/io
import gleam/string

pub fn main() {
  io.println(int.to_string(string.length("hello")))
  io.println(string.uppercase("abc"))
  io.println(string.reverse("abc"))
  io.println(string.append("foo", "bar"))
}
