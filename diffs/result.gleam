import gleam/int
import gleam/io
import gleam/result

fn parse(v: Int) -> Result(Int, String) {
  case v > 0 {
    True -> Ok(v)
    False -> Error("neg")
  }
}

fn add(a: Int, b: Int) -> Result(Int, String) {
  use x <- result.try(parse(a))
  use y <- result.try(parse(b))
  Ok(x + y)
}

pub fn main() {
  case add(1, 2) {
    Ok(n) -> io.println(int.to_string(n))
    Error(e) -> io.println(e)
  }
  case add(-1, 2) {
    Ok(n) -> io.println(int.to_string(n))
    Error(e) -> io.println(e)
  }
  case result.map_error(Error(1), fn(n) { n + 1 }) {
    Ok(_) -> io.println("ok")
    Error(n) -> io.println(int.to_string(n))
  }
}
