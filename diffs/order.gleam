import gleam/int
import gleam/io

type A {
  A(b: B)
}

type B {
  B(x: Int)
}

pub fn main() {
  let a = A(B(3))
  io.println(int.to_string(a.b.x))
}
