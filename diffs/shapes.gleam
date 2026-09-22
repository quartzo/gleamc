import gleam/float
import gleam/io

type Shape {
  Circle(radius: Float)
  Square(side: Float)
}

fn area(shape: Shape) -> Float {
  case shape {
    Circle(r) -> 3.14159 *. r *. r
    Square(s) -> s *. s
  }
}

pub fn main() {
  io.println(float.to_string(area(Circle(1.0))))
  io.println(float.to_string(area(Square(3.0))))
}
