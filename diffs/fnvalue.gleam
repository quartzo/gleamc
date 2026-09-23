import gleam/io
import gleam/list
import gleam/string

fn add(a: Int, b: Int) -> Int {
  a + b
}

fn double(n: Int) -> Int {
  n * 2
}

fn is_even(n: Int) -> Bool {
  n % 2 == 0
}

pub fn main() {
  io.println(string.inspect(list.fold([1, 2, 3], 0, add)))
  io.println(string.inspect(list.map([1, 2, 3], double)))
  io.println(string.inspect(list.filter([1, 2, 3, 4], is_even)))
}
