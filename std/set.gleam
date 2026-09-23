import gleam/list
import gleam/order

/// A set of unique values, kept sorted by the generated comparison glue.
/// Only the operations the compiler and the standard library need are
/// implemented (there is no balanced-tree representation).
pub opaque type Set(member) {
  Set(members: List(member))
}

fn members_of(set: Set(member)) -> List(member) {
  case set {
    Set(members) -> members
  }
}

fn compare(a: member, b: member) -> Order {
  let ordering = gleamc.key_compare(a, b)
  case ordering < 0 {
    True -> order.Lt
    False ->
      case ordering > 0 {
        True -> order.Gt
        False -> order.Eq
      }
  }
}

pub fn new() -> Set(member) {
  Set([])
}

pub fn is_empty(set: Set(member)) -> Bool {
  case members_of(set) {
    [] -> True
    _ -> False
  }
}

pub fn size(set: Set(member)) -> Int {
  list.length(members_of(set))
}

pub fn to_list(set: Set(member)) -> List(member) {
  members_of(set)
}

pub fn from_list(members: List(member)) -> Set(member) {
  list.fold(members, new(), fn(acc, member) { insert(acc, member) })
}

pub fn contains(set: Set(member), member: member) -> Bool {
  contains_members(members_of(set), member)
}

fn contains_members(members: List(member), member: member) -> Bool {
  case members {
    [] -> False
    [first, ..rest] ->
      case compare(first, member) {
        order.Eq -> True
        order.Lt -> contains_members(rest, member)
        order.Gt -> False
      }
  }
}

pub fn insert(set: Set(member), member: member) -> Set(member) {
  insert_members(members_of(set), member)
}

fn insert_members(members: List(member), member: member) -> Set(member) {
  case members {
    [] -> Set([member])
    [first, ..rest] ->
      case compare(first, member) {
        order.Eq -> Set([first, ..rest])
        order.Lt -> Set([first, ..members_of(insert_members(rest, member))])
        order.Gt -> Set([member, ..members])
      }
  }
}

pub fn delete(set: Set(member), member: member) -> Set(member) {
  delete_members(members_of(set), member)
}

fn delete_members(members: List(member), member: member) -> Set(member) {
  case members {
    [] -> Set([])
    [first, ..rest] ->
      case compare(first, member) {
        order.Eq -> Set(rest)
        order.Lt -> Set([first, ..members_of(delete_members(rest, member))])
        order.Gt -> Set(members)
      }
  }
}

pub fn union(a: Set(member), b: Set(member)) -> Set(member) {
  list.fold(members_of(b), a, fn(acc, member) { insert(acc, member) })
}

pub fn intersect(a: Set(member), b: Set(member)) -> Set(member) {
  list.fold(members_of(b), new(), fn(result, member) {
    case contains(a, member) {
      True -> insert(result, member)
      False -> result
    }
  })
}

pub fn difference(a: Set(member), b: Set(member)) -> Set(member) {
  list.fold(members_of(b), a, fn(acc, member) { delete(acc, member) })
}

pub fn filter(set: Set(member), keeping: fn(member) -> Bool) -> Set(member) {
  from_list(list.filter(members_of(set), keeping))
}

pub fn map(set: Set(member), with: fn(member) -> other) -> Set(other) {
  from_list(list.map(members_of(set), with))
}

pub fn fold(
  set: Set(member),
  initial: acc,
  with: fn(acc, member) -> acc,
) -> acc {
  list.fold(members_of(set), initial, with)
}

pub fn each(set: Set(member), with: fn(member) -> Nil) -> Nil {
  list.each(members_of(set), with)
}
