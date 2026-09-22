import gleam/bool
import gleam/int
import gleam/io
import gleam/list
import gleam/result

fn total(xs: List(Int)) -> Int {
  list.fold(xs, 0, fn(acc, x) { acc + x })
}

pub fn main() {
  let xs = [1, 2, 3, 4, 5]
  io.println(int.to_string(list.length(xs)))
  io.println(int.to_string(total(xs)))
  io.println(int.to_string(total(list.map(xs, fn(x) { x * 2 }))))
  io.println(int.to_string(total(list.filter(xs, fn(x) { x > 2 }))))
  io.println(int.to_string(list.fold(xs, 0, fn(acc, x) { acc + x })))
  io.println(int.to_string(total(list.take(xs, 2))))
  io.println(int.to_string(total(list.drop(xs, 2))))
  io.println(int.to_string(total(list.append([1, 2], [3, 4]))))
  io.println(int.to_string(total(list.repeat(7, 3))))
  io.println(int.to_string(total(list.flatten([[1, 2], [3]]))))
  io.println(bool.to_string(list.contains(xs, 3)))
  io.println(int.to_string(result.unwrap(list.first(xs), 0)))
  io.println(int.to_string(total(list.reverse(xs))))
  io.println(int.to_string(list.fold_right(xs, 0, fn(x, acc) { acc * 10 + x })))
}
