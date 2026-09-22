import gleam/int
import gleam/io
import gleam/list
import gleam/order.{type Order, Eq, Gt, Lt}
import gleam/result

fn show(xs: List(Int)) -> String {
  case xs {
    [] -> ""
    [x, ..rest] -> int.to_string(x) <> "," <> show(rest)
  }
}

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
  io.println(show(list.sort([3, 1, 2, 1], by)))
  io.println(
    int.to_string(result.unwrap(list.first(list.sort([3, 1, 2], by)), 0)),
  )
  io.println(int.to_string(order.to_int(order.negate(Lt))))
}
