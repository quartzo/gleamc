import gleam/int
import gleam/io

fn fib(n: Int) -> Int {
  case n {
    0 -> 0
    1 -> 1
    _ -> fib(n - 1) + fib(n - 2)
  }
}

pub fn main() {
  io.println(int.to_string(fib(10)))
}
