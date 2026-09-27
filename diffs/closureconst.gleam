import gleam/int
import gleam/io

pub fn main() {
  let base = 41
  let add = fn(x: Int) { x + base }
  let zero = fn() { base + 1 }
  io.println(int.to_string(add(1)))
  io.println(int.to_string(zero()))

  let name = "joe"
  let greet = fn() { "hi " <> name }
  io.println(greet())
}
