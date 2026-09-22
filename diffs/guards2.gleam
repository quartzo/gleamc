import gleam/int
import gleam/io

fn classify(n: Int) -> String {
  case n {
    x if x < 0 -> "neg"
    0 -> "zero"
    x if x > 0 && x < 10 -> "small"
    _ -> "big"
  }
}

fn pick(pair: #(Int, Int)) -> Int {
  case pair {
    #(a, b) if a > b -> a
    #(a, b) -> b
  }
}

pub fn main() {
  io.println(classify(5))
  io.println(classify(-3))
  io.println(classify(0))
  io.println(classify(100))
  io.println(int.to_string(pick(#(7, 2))))
  io.println(int.to_string(pick(#(1, 9))))
}
