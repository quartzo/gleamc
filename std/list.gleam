import gleam/dict
import gleam/order

pub type List(a) {
  ListCons(head: a, tail: List(a))
  ListEmpty
}

pub fn length(list: List(a)) -> Int {
  length_loop(list, 0)
}

fn length_loop(list: List(a), acc: Int) -> Int {
  case list {
    ListCons(_, rest) -> length_loop(rest, acc + 1)
    ListEmpty -> acc
  }
}

pub fn reverse(list: List(a)) -> List(a) {
  reverse_helper(list, ListEmpty)
}

fn reverse_helper(list: List(a), acc: List(a)) -> List(a) {
  case list {
    ListCons(head, rest) -> reverse_helper(rest, ListCons(head, acc))
    ListEmpty -> acc
  }
}

pub fn sum(list: List(Int)) -> Int {
  sum_loop(list, 0)
}

fn sum_loop(list: List(Int), acc: Int) -> Int {
  case list {
    ListCons(head, rest) -> sum_loop(rest, acc + head)
    ListEmpty -> acc
  }
}

pub fn map(list: List(a), with: fn(a) -> b) -> List(b) {
  map_loop(list, with, ListEmpty)
}

fn map_loop(list: List(a), with: fn(a) -> b, acc: List(b)) -> List(b) {
  case list {
    ListCons(head, rest) -> map_loop(rest, with, ListCons(with(head), acc))
    ListEmpty -> reverse(acc)
  }
}

pub fn filter(list: List(a), keeping: fn(a) -> Bool) -> List(a) {
  filter_loop(list, keeping, ListEmpty)
}

fn filter_loop(list: List(a), keeping: fn(a) -> Bool, acc: List(a)) -> List(a) {
  case list {
    ListCons(head, rest) ->
      case keeping(head) {
        True -> filter_loop(rest, keeping, ListCons(head, acc))
        False -> filter_loop(rest, keeping, acc)
      }
    ListEmpty -> reverse(acc)
  }
}

pub fn fold(over: List(a), from: b, with: fn(b, a) -> b) -> b {
  case over {
    ListCons(head, rest) -> fold(rest, with(from, head), with)
    ListEmpty -> from
  }
}

pub fn fold_right(over: List(a), from: b, with: fn(b, a) -> b) -> b {
  fold(reverse(over), from, fn(acc, item) { with(acc, item) })
}

pub fn any(over: List(a), satisfying: fn(a) -> Bool) -> Bool {
  case over {
    ListCons(head, rest) ->
      case satisfying(head) {
        True -> True
        False -> any(rest, satisfying)
      }
    ListEmpty -> False
  }
}

pub fn all(over: List(a), satisfying: fn(a) -> Bool) -> Bool {
  case over {
    ListCons(head, rest) ->
      case satisfying(head) {
        True -> all(rest, satisfying)
        False -> False
      }
    ListEmpty -> True
  }
}

pub fn each(over: List(a), with: fn(a) -> b) -> Nil {
  case over {
    ListCons(head, rest) -> {
      with(head)
      each(rest, with)
    }
    ListEmpty -> Nil
  }
}

pub fn append(first: List(a), second: List(a)) -> List(a) {
  append_loop(reverse(first), second)
}

fn append_loop(reversed: List(a), acc: List(a)) -> List(a) {
  case reversed {
    ListCons(head, rest) -> append_loop(rest, ListCons(head, acc))
    ListEmpty -> acc
  }
}

pub fn flatten(lists: List(List(a))) -> List(a) {
  flatten_loop(reverse(lists), ListEmpty)
}

fn flatten_loop(lists: List(List(a)), acc: List(a)) -> List(a) {
  case lists {
    ListCons(head, rest) -> flatten_loop(rest, append(head, acc))
    ListEmpty -> acc
  }
}

pub fn flat_map(over: List(a), with: fn(a) -> List(b)) -> List(b) {
  flatten(map(over, with))
}

pub fn take(over: List(a), up_to: Int) -> List(a) {
  take_loop(over, up_to, ListEmpty)
}

fn take_loop(over: List(a), up_to: Int, acc: List(a)) -> List(a) {
  case up_to <= 0 {
    True -> reverse(acc)
    False ->
      case over {
        ListCons(head, rest) -> take_loop(rest, up_to - 1, ListCons(head, acc))
        ListEmpty -> reverse(acc)
      }
  }
}

pub fn drop(over: List(a), up_to: Int) -> List(a) {
  case up_to <= 0 {
    True -> over
    False ->
      case over {
        ListCons(_, rest) -> drop(rest, up_to - 1)
        ListEmpty -> ListEmpty
      }
  }
}

pub fn contains(list: List(a), element: a) -> Bool {
  case list {
    ListCons(head, rest) ->
      case head == element {
        True -> True
        False -> contains(rest, element)
      }
    ListEmpty -> False
  }
}

pub fn repeat(item: a, times: Int) -> List(a) {
  repeat_loop(item, times, ListEmpty)
}

fn repeat_loop(item: a, times: Int, acc: List(a)) -> List(a) {
  case times <= 0 {
    True -> acc
    False -> repeat_loop(item, times - 1, ListCons(item, acc))
  }
}

pub fn first(list: List(a)) -> Result(a, Nil) {
  case list {
    ListCons(head, _) -> Ok(head)
    ListEmpty -> Error(Nil)
  }
}

pub fn at(list: List(a), index: Int) -> Result(a, Nil) {
  case index <= 0 {
    True ->
      case list {
        ListCons(head, _) -> Ok(head)
        ListEmpty -> Error(Nil)
      }
    False ->
      case list {
        ListCons(_, rest) -> at(rest, index - 1)
        ListEmpty -> Error(Nil)
      }
  }
}

pub fn zip(list: List(a), other: List(b)) -> List(#(a, b)) {
  zip_loop(list, other, ListEmpty)
}

fn zip_loop(list: List(a), other: List(b), acc: List(#(a, b))) -> List(#(a, b)) {
  case list, other {
    ListCons(x, xs), ListCons(y, ys) -> zip_loop(xs, ys, ListCons(#(x, y), acc))
    _, _ -> reverse(acc)
  }
}

pub fn map2(list: List(a), other: List(b), with: fn(a, b) -> c) -> List(c) {
  map2_loop(list, other, with, ListEmpty)
}

fn map2_loop(
  list: List(a),
  other: List(b),
  with: fn(a, b) -> c,
  acc: List(c),
) -> List(c) {
  case list, other {
    ListCons(x, xs), ListCons(y, ys) ->
      map2_loop(xs, ys, with, ListCons(with(x, y), acc))
    _, _ -> reverse(acc)
  }
}

pub fn index_map(list: List(a), with: fn(a, Int) -> b) -> List(b) {
  index_map_loop(list, with, 0, ListEmpty)
}

fn index_map_loop(
  list: List(a),
  with: fn(a, Int) -> b,
  index: Int,
  acc: List(b),
) -> List(b) {
  case list {
    ListCons(head, rest) ->
      index_map_loop(rest, with, index + 1, ListCons(with(head, index), acc))
    ListEmpty -> reverse(acc)
  }
}

pub fn last(list: List(a)) -> Result(a, Nil) {
  case list {
    ListCons(head, rest) ->
      case rest {
        ListEmpty -> Ok(head)
        _ -> last(rest)
      }
    ListEmpty -> Error(Nil)
  }
}

pub fn find(list: List(a), satisfying: fn(a) -> Bool) -> Result(a, Nil) {
  case list {
    ListCons(head, rest) ->
      case satisfying(head) {
        True -> Ok(head)
        False -> find(rest, satisfying)
      }
    ListEmpty -> Error(Nil)
  }
}

pub fn unzip(list: List(#(a, b))) -> #(List(a), List(b)) {
  unzip_helper(list, ListEmpty, ListEmpty)
}

fn unzip_helper(
  list: List(#(a, b)),
  acc_a: List(a),
  acc_b: List(b),
) -> #(List(a), List(b)) {
  case list {
    ListCons(#(a, b), rest) ->
      unzip_helper(rest, ListCons(a, acc_a), ListCons(b, acc_b))
    ListEmpty -> #(reverse(acc_a), reverse(acc_b))
  }
}

pub fn unique(list: List(a)) -> List(a) {
  unique_loop(list, ListEmpty, ListEmpty)
}

fn unique_loop(list: List(a), seen: List(a), acc: List(a)) -> List(a) {
  case list {
    ListCons(head, rest) ->
      case contains(seen, head) {
        True -> unique_loop(rest, seen, acc)
        False -> unique_loop(rest, ListCons(head, seen), ListCons(head, acc))
      }
    ListEmpty -> reverse(acc)
  }
}

pub fn filter_map(list: List(a), with: fn(a) -> Result(b, e)) -> List(b) {
  filter_map_loop(list, with, ListEmpty)
}

fn filter_map_loop(
  list: List(a),
  with: fn(a) -> Result(b, e),
  acc: List(b),
) -> List(b) {
  case list {
    ListCons(head, rest) ->
      case with(head) {
        Ok(value) -> filter_map_loop(rest, with, ListCons(value, acc))
        Error(_) -> filter_map_loop(rest, with, acc)
      }
    ListEmpty -> reverse(acc)
  }
}

pub fn sort(list: List(a), compare: fn(a, a) -> Order) -> List(a) {
  sort_loop(list, [], compare)
}

fn sort_loop(
  list: List(a),
  acc: List(a),
  compare: fn(a, a) -> Order,
) -> List(a) {
  case list {
    [] -> acc
    [head, ..rest] -> sort_loop(rest, insert(acc, head, compare), compare)
  }
}

fn insert(list: List(a), item: a, compare: fn(a, a) -> Order) -> List(a) {
  insert_loop(list, item, compare, [])
}

fn insert_loop(
  list: List(a),
  item: a,
  compare: fn(a, a) -> Order,
  acc: List(a),
) -> List(a) {
  case list {
    [] -> reverse([item, ..acc])
    [head, ..rest] ->
      case compare(item, head) {
        Lt -> reverse_onto(acc, [item, head, ..rest])
        _ -> insert_loop(rest, item, compare, [head, ..acc])
      }
  }
}

fn reverse_onto(acc: List(a), tail: List(a)) -> List(a) {
  case acc {
    [] -> tail
    [head, ..rest] -> reverse_onto(rest, [head, ..tail])
  }
}

pub fn index_fold(list: List(a), from: b, with: fn(b, a, Int) -> b) -> b {
  index_fold_loop(list, from, with, 0)
}

fn index_fold_loop(
  list: List(a),
  acc: b,
  with: fn(b, a, Int) -> b,
  index: Int,
) -> b {
  case list {
    [] -> acc
    [head, ..rest] ->
      index_fold_loop(rest, with(acc, head, index), with, index + 1)
  }
}

pub fn intersperse(list: List(a), separator: a) -> List(a) {
  case list {
    [] -> []
    [first, ..rest] -> reverse(intersperse_loop(rest, separator, [first]))
  }
}

fn intersperse_loop(list: List(a), separator: a, acc: List(a)) -> List(a) {
  case list {
    [] -> acc
    [head, ..rest] -> intersperse_loop(rest, separator, [head, separator, ..acc])
  }
}

pub fn take_while(list: List(a), satisfying: fn(a) -> Bool) -> List(a) {
  take_while_loop(list, satisfying, [])
}

fn take_while_loop(list: List(a), satisfying: fn(a) -> Bool, acc: List(a)) -> List(a) {
  case list {
    [] -> reverse(acc)
    [head, ..rest] ->
      case satisfying(head) {
        True -> take_while_loop(rest, satisfying, [head, ..acc])
        False -> reverse(acc)
      }
  }
}

pub fn drop_while(list: List(a), satisfying: fn(a) -> Bool) -> List(a) {
  case list {
    [] -> []
    [head, ..rest] ->
      case satisfying(head) {
        True -> drop_while(rest, satisfying)
        False -> list
      }
  }
}

pub fn window(list: List(a), size: Int) -> List(List(a)) {
  case size <= 0 {
    True -> []
    False ->
      case list.length(list) < size {
        True -> []
        False -> [list.take(list, size), ..window(list.drop(list, 1), size)]
      }
  }
}

pub fn chunk(list: List(a), by: fn(a) -> k) -> List(List(a)) {
  case list {
    [] -> []
    [first, ..rest] -> chunk_loop(rest, by, by(first), [first], [])
  }
}

fn chunk_loop(
  list: List(a),
  by: fn(a) -> k,
  key: k,
  group: List(a),
  acc: List(List(a)),
) -> List(List(a)) {
  case list {
    [] -> list.reverse([list.reverse(group), ..acc])
    [head, ..rest] ->
      case by(head) == key {
        True -> chunk_loop(rest, by, key, [head, ..group], acc)
        False ->
          chunk_loop(rest, by, by(head), [head], [list.reverse(group), ..acc])
      }
  }
}

pub fn sized_chunk(list: List(a), count: Int) -> List(List(a)) {
  case count <= 0 {
    True -> []
    False -> sized_chunk_loop(list, count, [])
  }
}

fn sized_chunk_loop(
  list: List(a),
  count: Int,
  acc: List(List(a)),
) -> List(List(a)) {
  case list {
    [] -> list.reverse(acc)
    _ ->
      sized_chunk_loop(list.drop(list, count), count, [
        list.take(list, count),
        ..acc
      ])
  }
}

pub fn permutations(elements: List(a)) -> List(List(a)) {
  case elements {
    [] -> [[]]
    _ ->
      list.flat_map(elements, fn(element) {
        list.map(permutations(remove_first(elements, element)), fn(permutation) {
          [element, ..permutation]
        })
      })
  }
}

fn remove_first(elements: List(a), element: a) -> List(a) {
  case elements {
    [] -> []
    [head, ..rest] ->
      case head == element {
        True -> rest
        False -> [head, ..remove_first(rest, element)]
      }
  }
}

pub fn scan(list: List(a), from: b, with: fn(b, a) -> b) -> List(b) {
  scan_loop(list, from, with, [])
}

fn scan_loop(
  list: List(a),
  acc: b,
  with: fn(b, a) -> b,
  out: List(b),
) -> List(b) {
  case list {
    [] -> list.reverse(out)
    [head, ..rest] -> {
      let next = with(acc, head)
      scan_loop(rest, next, with, [next, ..out])
    }
  }
}

pub fn transpose(rows: List(List(a))) -> List(List(a)) {
  case any_non_empty(rows) {
    False -> []
    True -> {
      let heads =
        list.filter_map(rows, fn(row) {
          case row {
            [] -> Error(Nil)
            [head, ..] -> Ok(head)
          }
        })
      let tails =
        list.filter_map(rows, fn(row) {
          case row {
            [] -> Error(Nil)
            [_, ..rest] -> Ok(rest)
          }
        })
      [heads, ..transpose(tails)]
    }
  }
}

fn any_non_empty(rows: List(List(a))) -> Bool {
  list.any(rows, fn(row) {
    case row {
      [] -> False
      _ -> True
    }
  })
}

pub fn map_fold(
  list: List(a),
  from: acc,
  with: fn(acc, a) -> #(acc, b),
) -> #(acc, List(b)) {
  map_fold_loop(list, from, with, [])
}

fn map_fold_loop(
  list: List(a),
  acc: acc,
  with: fn(acc, a) -> #(acc, b),
  out: List(b),
) -> #(acc, List(b)) {
  case list {
    [] -> #(acc, list.reverse(out))
    [head, ..rest] -> {
      let #(next, mapped) = with(acc, head)
      map_fold_loop(rest, next, with, [mapped, ..out])
    }
  }
}

pub fn reduce(list: List(a), with: fn(a, a) -> a) -> Result(a, Nil) {
  case list {
    [] -> Error(Nil)
    [first, ..rest] -> Ok(reduce_loop(rest, first, with))
  }
}

fn reduce_loop(list: List(a), acc: a, with: fn(a, a) -> a) -> a {
  case list {
    [] -> acc
    [head, ..rest] -> reduce_loop(rest, with(acc, head), with)
  }
}

pub fn window_by_2(list: List(a)) -> List(#(a, a)) {
  case list {
    [first, second, ..rest] -> [
      #(first, second),
      ..window_by_2([second, ..rest])
    ]
    _ -> []
  }
}

pub fn split(list: List(a), index: Int) -> #(List(a), List(a)) {
  #(list.take(list, index), list.drop(list, index))
}

pub type ContinueOrStop(a) {
  Continue(value: a)
  Stop(value: a)
}

pub fn new() -> List(a) {
  ListEmpty
}

pub fn is_empty(list: List(a)) -> Bool {
  case list {
    ListEmpty -> True
    ListCons(_, _) -> False
  }
}

pub fn prepend(to: List(a), this: a) -> List(a) {
  ListCons(this, to)
}

pub fn wrap(item: a) -> List(a) {
  [item]
}

pub fn rest(list: List(a)) -> Result(List(a), Nil) {
  case list {
    ListCons(_, tail) -> Ok(tail)
    ListEmpty -> Error(Nil)
  }
}

pub fn count(list: List(a), where: fn(a) -> Bool) -> Int {
  count_loop(list, where, 0)
}

fn count_loop(list: List(a), where: fn(a) -> Bool, acc: Int) -> Int {
  case list {
    ListEmpty -> acc
    ListCons(head, tail) ->
      case where(head) {
        True -> count_loop(tail, where, acc + 1)
        False -> count_loop(tail, where, acc)
      }
  }
}

pub fn find_map(over: List(a), with: fn(a) -> Result(b, c)) -> Result(b, Nil) {
  case over {
    ListEmpty -> Error(Nil)
    ListCons(head, tail) ->
      case with(head) {
        Ok(value) -> Ok(value)
        Error(_) -> find_map(tail, with)
      }
  }
}

pub fn fold_until(
  over: List(a),
  from: acc,
  with: fn(acc, a) -> ContinueOrStop(acc),
) -> acc {
  case over {
    ListEmpty -> from
    ListCons(head, tail) ->
      case with(from, head) {
        Continue(acc) -> fold_until(tail, acc, with)
        Stop(acc) -> acc
      }
  }
}

pub fn try_fold(
  over: List(a),
  from: acc,
  with: fn(acc, a) -> Result(acc, e),
) -> Result(acc, e) {
  case over {
    ListEmpty -> Ok(from)
    ListCons(head, tail) ->
      case with(from, head) {
        Ok(acc) -> try_fold(tail, acc, with)
        Error(err) -> Error(err)
      }
  }
}

pub fn try_map(
  over: List(a),
  with: fn(a) -> Result(b, e),
) -> Result(List(b), e) {
  try_map_loop(over, with, [])
}

fn try_map_loop(
  over: List(a),
  with: fn(a) -> Result(b, e),
  acc: List(b),
) -> Result(List(b), e) {
  case over {
    ListEmpty -> Ok(reverse(acc))
    ListCons(head, tail) ->
      case with(head) {
        Error(err) -> Error(err)
        Ok(value) -> try_map_loop(tail, with, [value, ..acc])
      }
  }
}

pub fn try_each(over: List(a), with: fn(a) -> Result(b, e)) -> Result(Nil, e) {
  case over {
    ListEmpty -> Ok(Nil)
    ListCons(head, tail) ->
      case with(head) {
        Ok(_) -> try_each(tail, with)
        Error(err) -> Error(err)
      }
  }
}

pub fn key_find(in: List(#(k, v)), find: k) -> Result(v, Nil) {
  case in {
    ListEmpty -> Error(Nil)
    ListCons(#(key, value), tail) ->
      case key == find {
        True -> Ok(value)
        False -> key_find(tail, find)
      }
  }
}

pub fn key_filter(in: List(#(k, v)), find: k) -> List(v) {
  key_filter_loop(in, find, [])
}

fn key_filter_loop(in: List(#(k, v)), find: k, acc: List(v)) -> List(v) {
  case in {
    ListEmpty -> reverse(acc)
    ListCons(#(key, value), tail) ->
      case key == find {
        True -> key_filter_loop(tail, find, [value, ..acc])
        False -> key_filter_loop(tail, find, acc)
      }
  }
}

pub fn key_pop(
  list: List(#(k, v)),
  key: k,
) -> Result(#(v, List(#(k, v))), Nil) {
  case list {
    ListEmpty -> Error(Nil)
    ListCons(#(entry_key, entry_value), tail) ->
      case entry_key == key {
        True -> Ok(#(entry_value, tail))
        False ->
          case key_pop(tail, key) {
            Ok(#(value, rest)) ->
              Ok(#(value, ListCons(#(entry_key, entry_value), rest)))
            Error(_) -> Error(Nil)
          }
      }
  }
}

pub fn key_set(list: List(#(k, v)), key: k, value: v) -> List(#(k, v)) {
  case key_find(list, key) {
    Ok(_) ->
      map(list, fn(pair) {
        let #(entry_key, _) = pair
        case entry_key == key {
          True -> #(key, value)
          False -> pair
        }
      })
    Error(_) -> append(list, [#(key, value)])
  }
}

pub fn strict_zip(list: List(a), with: List(b)) -> Result(List(#(a, b)), Nil) {
  strict_zip_loop(list, with, [])
}

fn strict_zip_loop(
  list: List(a),
  other: List(b),
  acc: List(#(a, b)),
) -> Result(List(#(a, b)), Nil) {
  case list, other {
    [], [] -> Ok(reverse(acc))
    [first, ..firsts], [second, ..seconds] ->
      strict_zip_loop(firsts, seconds, [#(first, second), ..acc])
    _, _ -> Error(Nil)
  }
}

pub fn split_while(
  list: List(a),
  satisfying: fn(a) -> Bool,
) -> #(List(a), List(a)) {
  let #(taken, rest) = split_while_loop(list, satisfying, [])
  #(reverse(taken), rest)
}

fn split_while_loop(
  list: List(a),
  satisfying: fn(a) -> Bool,
  acc: List(a),
) -> #(List(a), List(a)) {
  case list {
    [] -> #(acc, [])
    [head, ..tail] ->
      case satisfying(head) {
        True -> split_while_loop(tail, satisfying, [head, ..acc])
        False -> #(acc, list)
      }
  }
}

pub fn interleave(list: List(List(a))) -> List(a) {
  case list {
    [] -> []
    _ -> {
      let heads =
        flat_map(list, fn(row) {
          case row {
            [] -> []
            [head, ..] -> [head]
          }
        })
      let tails =
        filter_map(list, fn(row) {
          case row {
            [] -> Error(Nil)
            [_, ..tail] -> Ok(tail)
          }
        })
      append(heads, interleave(tails))
    }
  }
}

pub fn combinations(items: List(a), by: Int) -> List(List(a)) {
  case by <= 0 {
    True -> [[]]
    False ->
      case items {
        [] -> []
        [head, ..tail] ->
          append(
            map(combinations(tail, by - 1), fn(rest) { [head, ..rest] }),
            combinations(tail, by),
          )
      }
  }
}

pub fn combination_pairs(items: List(a)) -> List(#(a, a)) {
  case items {
    [] -> []
    [head, ..tail] ->
      append(map(tail, fn(other) { #(head, other) }), combination_pairs(tail))
  }
}

pub fn max(over: List(a), with: fn(a, a) -> Order) -> Result(a, Nil) {
  case over {
    [] -> Error(Nil)
    [head, ..tail] ->
      Ok(
        fold(tail, head, fn(best, item) {
          case with(item, best) {
            Gt -> item
            _ -> best
          }
        }),
      )
  }
}

pub fn partition(list: List(a), with: fn(a) -> Bool) -> #(List(a), List(a)) {
  partition_loop(list, with, [], [])
}

fn partition_loop(
  list: List(a),
  with: fn(a) -> Bool,
  yes: List(a),
  no: List(a),
) -> #(List(a), List(a)) {
  case list {
    [] -> #(reverse(yes), reverse(no))
    [head, ..tail] ->
      case with(head) {
        True -> partition_loop(tail, with, [head, ..yes], no)
        False -> partition_loop(tail, with, yes, [head, ..no])
      }
  }
}

pub fn group(list: List(v), by: fn(v) -> k) -> dict.Dict(k, List(v)) {
  fold(list, dict.new(), fn(acc, item) {
    let key = by(item)
    case dict.get(acc, key) {
      Ok(items) -> dict.insert(acc, key, [item, ..items])
      Error(_) -> dict.insert(acc, key, [item])
    }
  })
}
