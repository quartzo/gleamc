import gleam/int
import gleam/io

fn classify(n: Int) -> Int {
  case n {
    x if x > 0 -> 1
    0 -> 0
    _ -> -1
  }
}

pub fn main() {
  io.println(int.to_string(classify(5)))
  io.println(int.to_string(classify(0)))
  io.println(int.to_string(classify(-3)))
}
