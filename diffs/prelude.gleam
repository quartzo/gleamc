import gleam/int
import gleam/io

fn value() -> Result(Int, String) {
  Ok(1)
}

pub fn main() {
  case value() {
    Ok(n) -> io.println(int.to_string(n + 1))
    Error(_) -> io.println("err")
  }
}
