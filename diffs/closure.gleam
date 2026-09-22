import gleam/int
import gleam/io

fn make_adder(n: Int) -> fn(Int) -> Int {
  fn(x) { x + n }
}

fn apply(f: fn(Int) -> Int, x: Int) -> Int {
  f(x)
}

pub fn main() {
  let add5 = make_adder(5)
  io.println(int.to_string(add5(10)))
  io.println(int.to_string(apply(make_adder(100), 1)))
}
