import gleam/io
import gleam/string

pub fn main() {
  io.println(string.concat(["a", "b", "c"]))
  io.println(string.join(["a", "b", "c"], "-"))
  io.println(string.uppercase("ok"))
  io.println(string.concat([]))
}
