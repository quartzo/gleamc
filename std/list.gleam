import gleam/order

pub type List(a) {
  ListCons(head: a, tail: List(a))
  ListEmpty
}

pub fn length(list: List(a)) -> Int {
  case list {
    ListCons(_, rest) -> 1 + length(rest)
    ListEmpty -> 0
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
  case list {
    ListCons(head, rest) -> head + sum(rest)
    ListEmpty -> 0
  }
}

pub fn map(list: List(a), with: fn(a) -> b) -> List(b) {
  case list {
    ListCons(head, rest) -> ListCons(with(head), map(rest, with))
    ListEmpty -> ListEmpty
  }
}

pub fn filter(list: List(a), keeping: fn(a) -> Bool) -> List(a) {
  case list {
    ListCons(head, rest) ->
      case keeping(head) {
        True -> ListCons(head, filter(rest, keeping))
        False -> filter(rest, keeping)
      }
    ListEmpty -> ListEmpty
  }
}

pub fn fold(over: List(a), from: b, with: fn(b, a) -> b) -> b {
  case over {
    ListCons(head, rest) -> fold(rest, with(from, head), with)
    ListEmpty -> from
  }
}

pub fn fold_right(over: List(a), from: b, with: fn(b, a) -> b) -> b {
  case over {
    ListCons(head, rest) -> with(fold_right(rest, from, with), head)
    ListEmpty -> from
  }
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
  case first {
    ListCons(head, rest) -> ListCons(head, append(rest, second))
    ListEmpty -> second
  }
}

pub fn flatten(lists: List(List(a))) -> List(a) {
  case lists {
    ListCons(head, rest) -> append(head, flatten(rest))
    ListEmpty -> ListEmpty
  }
}

pub fn flat_map(over: List(a), with: fn(a) -> List(b)) -> List(b) {
  case over {
    ListCons(head, rest) -> append(with(head), flat_map(rest, with))
    ListEmpty -> ListEmpty
  }
}

pub fn take(over: List(a), up_to: Int) -> List(a) {
  case up_to <= 0 {
    True -> ListEmpty
    False ->
      case over {
        ListCons(head, rest) -> ListCons(head, take(rest, up_to - 1))
        ListEmpty -> ListEmpty
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
  case times <= 0 {
    True -> ListEmpty
    False -> ListCons(item, repeat(item, times - 1))
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
  case list {
    ListCons(x, xs) ->
      case other {
        ListCons(y, ys) -> ListCons(#(x, y), zip(xs, ys))
        ListEmpty -> ListEmpty
      }
    ListEmpty -> ListEmpty
  }
}

pub fn map2(list: List(a), other: List(b), with: fn(a, b) -> c) -> List(c) {
  case list {
    ListCons(x, xs) ->
      case other {
        ListCons(y, ys) -> ListCons(with(x, y), map2(xs, ys, with))
        ListEmpty -> ListEmpty
      }
    ListEmpty -> ListEmpty
  }
}

pub fn index_map(list: List(a), with: fn(a, Int) -> b) -> List(b) {
  index_map_loop(list, with, 0)
}

fn index_map_loop(list: List(a), with: fn(a, Int) -> b, index: Int) -> List(b) {
  case list {
    ListCons(head, rest) ->
      ListCons(with(head, index), index_map_loop(rest, with, index + 1))
    ListEmpty -> ListEmpty
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
  unique_loop(list, ListEmpty)
}

fn unique_loop(list: List(a), seen: List(a)) -> List(a) {
  case list {
    ListCons(head, rest) ->
      case contains(seen, head) {
        True -> unique_loop(rest, seen)
        False -> ListCons(head, unique_loop(rest, ListCons(head, seen)))
      }
    ListEmpty -> ListEmpty
  }
}

pub fn filter_map(list: List(a), with: fn(a) -> Result(b, e)) -> List(b) {
  case list {
    ListCons(head, rest) ->
      case with(head) {
        Ok(value) -> ListCons(value, filter_map(rest, with))
        Error(_) -> filter_map(rest, with)
      }
    ListEmpty -> ListEmpty
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
  case list {
    [] -> [item]
    [head, ..rest] ->
      case compare(item, head) {
        Lt -> [item, head, ..rest]
        _ -> [head, ..insert(rest, item, compare)]
      }
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
    [first, ..rest] -> [first, ..intersperse_rest(rest, separator)]
  }
}

fn intersperse_rest(list: List(a), separator: a) -> List(a) {
  case list {
    [] -> []
    [head, ..rest] -> [separator, head, ..intersperse_rest(rest, separator)]
  }
}

pub fn take_while(list: List(a), satisfying: fn(a) -> Bool) -> List(a) {
  case list {
    [] -> []
    [head, ..rest] ->
      case satisfying(head) {
        True -> [head, ..take_while(rest, satisfying)]
        False -> []
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
