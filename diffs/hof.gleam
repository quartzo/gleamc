import gleam/int
import gleam/io

fn apply(f: fn(Int) -> Int, x: Int) -> Int {
  f(x)
}

fn double(x: Int) -> Int {
  x * 2
}

fn inc(x: Int) -> Int {
  x + 1
}

pub fn main() {
  io.println(int.to_string(apply(double, 5)))
  io.println(int.to_string(apply(inc, 10)))
}
