import gleam/bool
import gleam/io
import gleam/option

type Shape {
  Circle(radius: Float)
  Rect(width: Int, height: Int)
}

type Tree {
  Leaf(value: Int)
  Node(left: Tree, right: Tree)
}

pub fn main() {
  io.println(bool.to_string(Circle(1.5) == Circle(1.5)))
  io.println(bool.to_string(Circle(1.5) == Circle(2.5)))
  io.println(bool.to_string(Rect(2, 3) == Rect(2, 3)))
  io.println(bool.to_string(Rect(2, 3) == Rect(2, 4)))
  io.println(bool.to_string([1, 2, 3] == [1, 2, 3]))
  io.println(bool.to_string([1, 2, 3] == [1, 2, 4]))
  io.println(bool.to_string(#(1, "a") == #(1, "a")))
  io.println(bool.to_string(option.Some(1) == option.Some(1)))
  io.println(bool.to_string(option.Some(1) == option.None))
  io.println(bool.to_string(Node(Leaf(1), Leaf(2)) == Node(Leaf(1), Leaf(2))))
  io.println(bool.to_string(Node(Leaf(1), Leaf(2)) == Node(Leaf(1), Leaf(3))))
  io.println(bool.to_string(Ok(1) == Ok(1)))
}
