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

fn sum(a: Int, b: Int) -> Int {
  a + b
}

pub fn main() {
  io.println(float.to_string(area(Circle(2.0))))
  io.println(float.to_string(area(Square(3.0))))
  io.println(int.to_string(sum(20, 22)))
}
