import gleam/float
import gleam/int
import gleam/io

pub fn main() {
  io.println(int.to_string(int.min(3, 5)))
  io.println(int.to_string(int.max(3, 5)))
  io.println(int.to_string(int.absolute_value(-4)))
  io.println(int.to_string(float.round(2.5)))
  io.println(float.to_string(float.floor(2.7)))
  io.println(float.to_string(float.ceiling(2.1)))
  io.println(int.to_string(float.truncate(-2.7)))
  io.println(float.to_string(float.absolute_value(-2.5)))
  io.println(float.to_string(float.min(1.5, 0.5)))
  io.println(float.to_string(float.max(1.5, 0.5)))
}
