import gleam/int
import gleam/io

type Person {
  Person(name: String, age: Int)
}

type Shape {
  Circle(radius: Float)
  Rect(width: Int, height: Int)
}

pub fn main() {
  let person = Person("Lucy", 6)
  let older = Person(..person, age: 7)
  io.println(older.name)
  io.println(int.to_string(older.age))
  io.println(int.to_string(person.age))
  let rect = Rect(2, 3)
  let wider = Rect(..rect, width: 5)
  io.println(int.to_string(wider.width + wider.height))
}
