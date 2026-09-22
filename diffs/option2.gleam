import gleam/bool
import gleam/int
import gleam/io
import gleam/option
import gleam/result

pub fn main() {
  io.println(
    int.to_string(option.unwrap(
      option.then(option.Some(3), fn(x) { option.Some(x + 1) }),
      0,
    )),
  )
  io.println(
    int.to_string(option.unwrap(
      option.then(option.Some(3), fn(_) { option.None }),
      7,
    )),
  )
  io.println(
    int.to_string(option.unwrap(option.or(option.None, option.Some(5)), 0)),
  )
  io.println(
    int.to_string(result.unwrap(option.to_result(option.Some(1), "err"), 0)),
  )
  io.println(int.to_string(option.unwrap(option.from_result(Ok(2)), 0)))
  io.println(
    int.to_string(option.unwrap(option.flatten(option.Some(option.Some(3))), 0)),
  )
  io.println(int.to_string(option.lazy_unwrap(option.None, fn() { 9 })))
  io.println(bool.to_string(option.is_none(option.None)))
}
