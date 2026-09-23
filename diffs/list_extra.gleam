import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/string

fn is_odd(n: Int) -> Bool {
  n % 2 == 1
}

pub fn main() {
  io.println(string.inspect(list.new()))
  io.println(string.inspect(list.is_empty([])))
  io.println(string.inspect(list.prepend(to: [2, 3], this: 1)))
  io.println(string.inspect(list.wrap(1)))
  io.println(string.inspect(list.rest([1, 2, 3])))
  io.println(string.inspect(list.count([1, 2, 3], where: fn(x) { x > 1 })))
  io.println(string.inspect(list.find_map([[], [2], [3]], list.first)))
  io.println(
    string.inspect(
      list.fold_until([1, 2, 3, 4], 0, fn(acc, i) {
        case i < 3 {
          True -> list.Continue(acc + i)
          False -> list.Stop(acc)
        }
      }),
    ),
  )
  io.println(
    string.inspect(list.try_fold([1, 2, 3], 0, fn(acc, i) { Ok(acc + i) })),
  )
  io.println(string.inspect(list.try_map([1, 2, 3], fn(x) { Ok(x + 2) })))
  io.println(string.inspect(list.try_each([1, 2, 3], fn(x) { Ok(x) })))
  io.println(string.inspect(list.key_find([#("a", 0), #("b", 1)], "b")))
  io.println(
    string.inspect(list.key_filter([#("a", 0), #("b", 1), #("a", 2)], "a")),
  )
  io.println(string.inspect(list.key_pop([#("a", 0), #("b", 1)], "a")))
  io.println(string.inspect(list.key_set([#(5, 0), #(4, 1)], 4, 100)))
  io.println(string.inspect(list.strict_zip([1, 2], [3, 4])))
  io.println(
    string.inspect(list.split_while([1, 2, 3, 4, 5], fn(x) { x <= 3 })),
  )
  io.println(string.inspect(list.interleave([[1, 2], [101, 102], [201, 202]])))
  io.println(string.inspect(list.combinations([1, 2, 3], 2)))
  io.println(string.inspect(list.combination_pairs([1, 2, 3])))
  io.println(string.inspect(list.max([1, 2, 3, 4, 5], int.compare)))
  io.println(string.inspect(list.partition([1, 2, 3, 4, 5], is_odd)))
  io.println(
    string.inspect(
      dict.to_list(list.group([1, 2, 3, 4, 5], fn(i) { i - i / 3 * 3 })),
    ),
  )
}
