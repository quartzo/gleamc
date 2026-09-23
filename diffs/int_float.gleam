import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/string

pub fn main() {
  io.println(string.inspect(int.add(1, 2)))
  io.println(string.inspect(int.subtract(3, 1)))
  io.println(string.inspect(int.multiply(2, 4)))
  io.println(string.inspect(int.negate(1)))
  io.println(string.inspect(int.is_even(2)))
  io.println(string.inspect(int.is_odd(3)))
  io.println(string.inspect(int.sum([1, 2, 3])))
  io.println(string.inspect(int.product([2, 3, 4])))
  io.println(string.inspect(int.clamp(40, min: 50, max: 60)))
  io.println(string.inspect(int.divide(5, 2)))
  io.println(string.inspect(int.divide(1, 0)))
  io.println(string.inspect(int.remainder(-13, by: 3)))
  io.println(string.inspect(int.modulo(-13, by: 3)))
  io.println(string.inspect(int.floor_divide(-99, by: 2)))
  io.println(string.inspect(int.power(2, of: 2.0)))
  io.println(string.inspect(int.square_root(4)))
  io.println(string.inspect(int.to_base16(48)))
  io.println(string.inspect(int.to_base2(2)))
  io.println(
    string.inspect(int.range(from: 1, to: -2, with: [], run: list.prepend)),
  )
  io.println(string.inspect(int.bitwise_and(6, 3)))
  io.println(string.inspect(int.bitwise_or(6, 3)))
  io.println(string.inspect(int.bitwise_exclusive_or(6, 3)))
  io.println(string.inspect(int.bitwise_not(0)))
  io.println(string.inspect(int.bitwise_shift_left(1, 4)))
  io.println(string.inspect(int.bitwise_shift_right(16, 2)))
  io.println(string.inspect(float.add(1.0, 2.0)))
  io.println(string.inspect(float.subtract(3.0, 1.0)))
  io.println(string.inspect(float.multiply(2.0, 4.0)))
  io.println(string.inspect(float.negate(1.0)))
  io.println(string.inspect(float.divide(1.0, 0.0)))
  io.println(string.inspect(float.modulo(5.0, by: 2.0)))
  io.println(string.inspect(float.clamp(1.2, min: 1.4, max: 1.6)))
  io.println(string.inspect(float.exponential(0.0)))
  io.println(string.inspect(float.logarithm(1.0)))
  io.println(
    string.inspect(float.loosely_compare(5.0, with: 5.3, tolerating: 0.5)),
  )
  io.println(
    string.inspect(float.loosely_equals(5.0, with: 5.3, tolerating: 0.5)),
  )
  io.println(string.inspect(float.to_precision(2.43434348473, 2)))
  io.println(string.inspect(float.sum([1.0, 2.0, 3.0])))
  io.println(string.inspect(float.product([2.0, 3.0, 4.0])))
}
