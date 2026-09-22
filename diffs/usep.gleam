import gleam/int
import gleam/io

fn pair(f: fn(#(Int, Int)) -> Int) -> Int {
  f(#(3, 4))
}

pub fn main() {
  let r = {
    use #(a, b) <- pair
    a + b
  }
  io.println(int.to_string(r))
}
