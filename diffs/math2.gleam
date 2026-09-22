import gleam/float
import gleam/int
import gleam/io
import gleam/order
import gleam/result
import gleam/string

pub fn main() {
  io.println(float.to_string(result.unwrap(float.power(2.0, 10.0), 0.0)))
  io.println(float.to_string(result.unwrap(float.square_root(9.0), 0.0)))
  io.println(result.unwrap(int.to_base_string(255, 16), "err"))
  io.println(result.unwrap(int.to_base_string(5, 2), "err"))
  io.println(result.unwrap(int.to_base_string(-10, 16), "err"))
  io.println(float.to_string(int.to_float(3)))
  io.println(int.to_string(order.to_int(string.compare("a", "b"))))
  io.println(int.to_string(order.to_int(string.compare("b", "a"))))
  io.println(int.to_string(order.to_int(string.compare("a", "a"))))
}
