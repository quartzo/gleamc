import gleam/float
import gleam/function
import gleam/int
import gleam/io
import gleam/order
import gleam/string

pub fn main() {
  io.println(int.to_string(function.identity(7)))
  io.println(int.to_string(order.to_int(int.compare(1, 2))))
  io.println(int.to_string(order.to_int(int.compare(2, 1))))
  io.println(int.to_string(order.to_int(int.compare(2, 2))))
  io.println(int.to_string(order.to_int(float.compare(1.5, 2.5))))
  io.println(string.compare("a", "a") |> order.to_int |> int.to_string)
}
