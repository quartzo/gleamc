import gleam/io
import gleam/string

type Wrap(a) {
  Wrap(value: a)
}

type Point {
  Point(x: Int, y: Int)
}

pub fn main() {
  let Wrap(v) = Wrap(5)
  io.println(string.inspect(v))
  let Wrap(value: w) = Wrap("hi")
  io.println(w)
  let Point(x: a, y: b) = Point(3, 4)
  io.println(string.inspect(a + b))
}
