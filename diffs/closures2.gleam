import gleam/int
import gleam/io
import gleam/list

fn total(xs: List(Int)) -> Int {
  list.fold(xs, 0, fn(acc, x) { acc + x })
}

fn size(xs: List(Int)) -> Int {
  list.length(xs)
}

fn add_size(xs: List(Int)) -> List(Int) {
  list.map(xs, fn(a) { a + size(xs) })
}

pub fn main() {
  io.println(int.to_string(list.length(add_size([1, 2, 3]))))
  io.println(int.to_string(total(add_size([1, 2, 3]))))
  let base = [10, 20]
  let nested = list.flat_map(base, fn(x) { list.map(base, fn(y) { x + y }) })
  io.println(int.to_string(total(nested)))
}
