import gleam/float
import gleam/io

fn p(v: Float) {
  io.println(float.to_string(v))
}

pub fn main() {
  p(1.0)
  p(0.5)
  p(1.5)
  p(100.0)
  p(0.1)
  p(1.0e20)
  p(1.0e-7)
  p(3.14159)
  p(12.56636)
  p(1_234_567.0)
  p(123_456_789_012_345.0)
  p(1.0e15)
  p(1.0e16)
  p(1.0e17)
  p(1.0e-4)
  p(1.0e-5)
  p(0.00012)
  p(123_456_789.0)
  p(1.2345678901234e15)
  p(1.0e100)
  p(1.0e-100)
}
