import gleam/int
import gleam/io
import gleam/result

fn get(r: Result(Int, String)) -> Int {
  let assert Ok(n) = r
  n + 1
}

fn pair() -> #(Int, Int) {
  #(3, 4)
}

pub fn main() {
  io.println(int.to_string(get(Ok(4))))
  let assert #(a, b) = pair()
  io.println(int.to_string(a + b))
}
