import gleam/bool
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/order.{type Order, Eq, Gt, Lt}
import gleam/result

fn by(a: Int, b: Int) -> Order {
  case a < b {
    True -> Lt
    False ->
      case a == b {
        True -> Eq
        False -> Gt
      }
  }
}

pub fn main() {
  io.println(bool.to_string(bool.and(True, False)))
  io.println(bool.to_string(bool.exclusive_or(True, True)))
  io.println(bool.to_string(bool.nand(True, True)))
  io.println(bool.to_string(bool.guard(True, True, fn() { False })))
  io.println(bool.to_string(bool.nor(False, False)))
  io.println(int.to_string(order.to_int(order.compare(Lt, Gt))))
  io.println(int.to_string(order.to_int(order.break_tie(Eq, Gt))))
  let sorted = list.sort([3, 1, 2], order.reverse(by))
  io.println(int.to_string(result.unwrap(list.first(sorted), 0)))
  io.println(
    int.to_string(option.unwrap(
      option.lazy_or(option.None, fn() { option.Some(5) }),
      0,
    )),
  )
  io.println(
    int.to_string(result.unwrap(
      result.try_recover(Error(1), fn(e) { Ok(e + 1) }),
      0,
    )),
  )
}
