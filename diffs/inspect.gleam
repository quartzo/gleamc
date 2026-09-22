import gleam/io
import gleam/string

type Person {
  Person(name: String, age: Int)
}

type Shape {
  Circle(radius: Float)
  Empty
}

fn show(x: a) -> String {
  string.inspect(x)
}

pub fn main() {
  io.println(show(42))
  io.println(show(-7))
  io.println(show(3.5))
  io.println(show(True))
  io.println(show("he\"llo"))
  io.println(show(Nil))
  io.println(show([1, 2, 3]))
  io.println(show(#(1, "a")))
  io.println(show(Person("Lucy", 6)))
  io.println(show(Circle(1.5)))
  io.println(show(Empty))
  io.println(show([[1], [2, 3]]))
}
