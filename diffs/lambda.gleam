import gleam/int
import gleam/io

fn apply(f: fn(Int) -> Int, x: Int) -> Int {
  f(x)
}

fn keep_if(flag: Bool, value: Int) -> Int {
  case flag {
    True -> value
    False -> 0
  }
}

pub fn main() {
  io.println(int.to_string(apply(fn(x) { x * 3 }, 4)))
  io.println(int.to_string(keep_if(True, 7)))
  io.println(int.to_string(keep_if(False, 7)))
}
