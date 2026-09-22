import gleam/int
import gleam/io
import gleam/option
import gleam/result

pub fn main() {
  let mapped = option.map(option.Some(1), fn(x) { x + 1 })
  io.println(int.to_string(option.unwrap(mapped, 0)))
  io.println(int.to_string(option.unwrap(option.None, 42)))

  let doubled = result.map(Ok(20), fn(x) { x * 2 })
  io.println(int.to_string(result.unwrap(doubled, 0)))
}
