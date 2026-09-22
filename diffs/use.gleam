import gleam/int
import gleam/io

fn with_value(x: Int, f: fn(Int) -> Int) -> Int {
  f(x)
}

pub fn main() {
  let sum = {
    use a <- with_value(10)
    use b <- with_value(20)
    a + b
  }
  io.println(int.to_string(sum))
}
