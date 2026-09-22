import gleam/int
import gleam/io

type Person {
  Person(name: String, age: Int)
}

fn name_of(person: Person) -> String {
  person.name
}

pub fn main() {
  let person = Person(name: "Lucy", age: 6)
  io.println(name_of(person))
  io.println(int.to_string(person.age))
}
