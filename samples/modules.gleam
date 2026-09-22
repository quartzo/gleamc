import gleam/io
import math

pub fn main() {
  io.println(int.to_string(math.add(20, 22)))
  io.println(int.to_string(math.mul(6, 7)))
}
