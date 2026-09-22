import gleam/int
import gleam/io
import gleam/result

fn label(a: Result(Int, String), b: Int) -> Int {
  case a, b {
    Ok(x), 0 -> x
    Ok(x), y -> x + y
    Error(_), _ -> -1
  }
}

pub fn main() {
  io.println(int.to_string(label(Ok(1), 0)))
  io.println(int.to_string(label(Ok(1), 2)))
  io.println(int.to_string(label(Error("e"), 5)))
}
