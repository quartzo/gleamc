import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string

// A persistent hash array mapped trie (HAMT), 32-way (5 bits per level). Keys
// are hashed from `string.inspect`; collisions are chained. This replaces the
// previous sorted-list implementation, whose O(n) `get`/`insert` made building
// a large dict (e.g. the monomorphiser's tables) quadratic.

pub opaque type Dict(k, v) {
  Dict(root: Node(k, v), count: Int)
}

type Node(k, v) {
  Empty
  Leaf(hash: Int, key: k, value: v)
  Collision(hash: Int, entries: List(#(k, v)))
  Branch(bitmap: Int, children: List(Node(k, v)))
}

pub fn new() -> Dict(k, v) {
  Dict(root: Empty, count: 0)
}

pub fn is_empty(dict: Dict(k, v)) -> Bool {
  size(dict) == 0
}

pub fn size(dict: Dict(k, v)) -> Int {
  let Dict(_, count) = dict
  count
}

pub fn from_list(entries: List(#(k, v))) -> Dict(k, v) {
  list.fold(entries, new(), fn(dict, entry) {
    let #(key, value) = entry
    insert(dict, key, value)
  })
}

/// Iteration is by key order, so the observable order is stable and matches
/// the previous (sorted) implementation. `list.sort` is an insertion sort
/// (O(n^2) and deep recursion) so use a merge sort here.
pub fn to_list(dict: Dict(k, v)) -> List(#(k, v)) {
  let Dict(root, _) = dict
  sort_entries(entries(root, []))
}

fn sort_entries(items: List(#(k, v))) -> List(#(k, v)) {
  case items {
    [] -> []
    [_] -> items
    _ -> {
      let middle = list.length(items) / 2
      let #(left, right) = list.split(items, middle)
      merge_entries(sort_entries(left), sort_entries(right), [])
    }
  }
}

fn merge_entries(
  a: List(#(k, v)),
  b: List(#(k, v)),
  acc: List(#(k, v)),
) -> List(#(k, v)) {
  case a, b {
    [], _ -> list.append(list.reverse(acc), b)
    _, [] -> list.append(list.reverse(acc), a)
    [#(key_a, _) as entry_a, ..rest_a], [#(key_b, _) as entry_b, ..rest_b] ->
      case key_order(key_a, key_b) {
        order.Gt -> merge_entries(a, rest_b, [entry_b, ..acc])
        _ -> merge_entries(rest_a, b, [entry_a, ..acc])
      }
  }
}

fn key_order(a: k, b: k) -> Order {
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

pub fn keys(dict: Dict(k, v)) -> List(k) {
  list.map(to_list(dict), fn(entry) {
    let #(key, _) = entry
    key
  })
}

pub fn values(dict: Dict(k, v)) -> List(v) {
  list.map(to_list(dict), fn(entry) {
    let #(_, value) = entry
    value
  })
}

pub fn get(dict: Dict(k, v), key: k) -> Result(v, Nil) {
  let Dict(root, _) = dict
  get_node(root, hash_key(key), key, 0)
}

pub fn has_key(dict: Dict(k, v), key: k) -> Bool {
  case get(dict, key) {
    Ok(_) -> True
    Error(_) -> False
  }
}

pub fn insert(dict: Dict(k, v), key: k, value: v) -> Dict(k, v) {
  let Dict(root, count) = dict
  let #(root, added) = insert_node(root, hash_key(key), key, value, 0)
  Dict(root, case added {
    True -> count + 1
    False -> count
  })
}

pub fn delete(dict: Dict(k, v), key: k) -> Dict(k, v) {
  let Dict(root, count) = dict
  let #(root, removed) = delete_node(root, hash_key(key), key, 0)
  Dict(root, case removed {
    True -> count - 1
    False -> count
  })
}

pub fn upsert(
  dict: Dict(k, v),
  key: k,
  with: fn(Option(v)) -> v,
) -> Dict(k, v) {
  case get(dict, key) {
    Ok(value) -> insert(dict, key, with(Some(value)))
    Error(_) -> insert(dict, key, with(None))
  }
}

pub fn map_values(dict: Dict(k, v), with: fn(k, v) -> b) -> Dict(k, b) {
  from_list(list.map(to_list(dict), fn(entry) {
    let #(key, value) = entry
    #(key, with(key, value))
  }))
}

pub fn fold(dict: Dict(k, v), from: acc, with: fn(acc, k, v) -> acc) -> acc {
  list.fold(to_list(dict), from, fn(acc, entry) {
    let #(key, value) = entry
    with(acc, key, value)
  })
}

pub fn filter(dict: Dict(k, v), keeping: fn(k, v) -> Bool) -> Dict(k, v) {
  from_list(list.filter(to_list(dict), fn(entry) {
    let #(key, value) = entry
    keeping(key, value)
  }))
}

pub fn each(dict: Dict(k, v), with: fn(k, v) -> a) -> Nil {
  list.each(to_list(dict), fn(entry) {
    let #(key, value) = entry
    with(key, value)
  })
}

pub fn merge(into: Dict(k, v), from: Dict(k, v)) -> Dict(k, v) {
  list.fold(to_list(from), into, fn(dict, entry) {
    let #(key, value) = entry
    insert(dict, key, value)
  })
}

pub fn combine(
  dict: Dict(k, v),
  other: Dict(k, v),
  with: fn(v, v) -> v,
) -> Dict(k, v) {
  list.fold(to_list(other), dict, fn(dict, entry) {
    let #(key, value) = entry
    case get(dict, key) {
      Ok(existing) -> insert(dict, key, with(existing, value))
      Error(_) -> insert(dict, key, value)
    }
  })
}

pub fn take(dict: Dict(k, v), desired_keys: List(k)) -> Dict(k, v) {
  from_list(list.filter(to_list(dict), fn(entry) {
    let #(key, _) = entry
    list.contains(desired_keys, key)
  }))
}

pub fn drop(dict: Dict(k, v), disallowed_keys: List(k)) -> Dict(k, v) {
  from_list(list.filter(to_list(dict), fn(entry) {
    let #(key, _) = entry
    !list.contains(disallowed_keys, key)
  }))
}

pub fn group(key: fn(v) -> k, values: List(v)) -> Dict(k, List(v)) {
  list.fold(values, new(), fn(dict, value) {
    let value_key = key(value)
    case get(dict, value_key) {
      Ok(existing) -> insert(dict, value_key, [value, ..existing])
      Error(_) -> insert(dict, value_key, [value])
    }
  })
}

// ---------------------------------------------------------------------------
// nodes
// ---------------------------------------------------------------------------

fn get_node(node: Node(k, v), hash: Int, key: k, level: Int) -> Result(v, Nil) {
  case node {
    Empty -> Error(Nil)
    Leaf(h, k, v) ->
      case h == hash && k == key {
        True -> Ok(v)
        False -> Error(Nil)
      }
    Collision(h, entries) ->
      case h == hash {
        True -> collision_get(entries, key)
        False -> Error(Nil)
      }
    Branch(bitmap, children) ->
      case bit_at(bitmap, index(hash, level)) {
        True -> {
          let child = list_at(children, bits_below(bitmap, index(hash, level)))
          get_node(child, hash, key, level + 1)
        }
        False -> Error(Nil)
      }
  }
}

fn insert_node(node: Node(k, v), hash: Int, key: k, value: v, level: Int) -> #(Node(k, v), Bool) {
  case node {
    Empty -> #(Leaf(hash, key, value), True)
    Leaf(h, k, v) ->
      case h == hash {
        True ->
          case k == key {
            True -> #(Leaf(hash, key, value), False)
            False -> #(Collision(hash, [#(key, value), #(k, v)]), True)
          }
        False -> #(merge_two(node, Leaf(hash, key, value), level), True)
      }
    Collision(h, entries) ->
      case h == hash {
        True -> {
          let #(entries, added) = collision_put(entries, key, value, [])
          #(Collision(h, entries), added)
        }
        False -> #(merge_two(node, Leaf(hash, key, value), level), True)
      }
    Branch(bitmap, children) -> {
      let idx = index(hash, level)
      let pos = bits_below(bitmap, idx)
      case bit_at(bitmap, idx) {
        True -> {
          let child = list_at(children, pos)
          let #(child, added) = insert_node(child, hash, key, value, level + 1)
          #(Branch(bitmap, replace_at(children, pos, child)), added)
        }
        False ->
          #(
            Branch(
              bitmap + pow(2, idx),
              insert_at(children, pos, Leaf(hash, key, value)),
            ),
            True,
          )
      }
    }
  }
}

fn delete_node(node: Node(k, v), hash: Int, key: k, level: Int) -> #(Node(k, v), Bool) {
  case node {
    Empty -> #(Empty, False)
    Leaf(h, k, v) ->
      case h == hash && k == key {
        True -> #(Empty, True)
        False -> #(node, False)
      }
    Collision(h, entries) ->
      case h == hash {
        True -> {
          let #(entries, removed) = collision_remove(entries, key)
          case entries {
            [] -> #(Empty, removed)
            [#(k, v)] -> #(Leaf(h, k, v), removed)
            _ -> #(Collision(h, entries), removed)
          }
        }
        False -> #(node, False)
      }
    Branch(bitmap, children) -> {
      let idx = index(hash, level)
      case bit_at(bitmap, idx) {
        False -> #(node, False)
        True -> {
          let pos = bits_below(bitmap, idx)
          let #(child, removed) =
            delete_node(list_at(children, pos), hash, key, level + 1)
          case removed {
            False -> #(node, False)
            True ->
              case child {
                Empty -> {
                  let remaining = remove_at(children, pos)
                  case remaining {
                    [] -> #(Empty, True)
                    [only] -> #(only, True)
                    _ -> #(Branch(bitmap - pow(2, idx), remaining), True)
                  }
                }
                _ -> #(Branch(bitmap, replace_at(children, pos, child)), True)
              }
          }
        }
      }
    }
  }
}



// Two leaf-like nodes (Leaf/Collision) whose hashes differ: branch them at the
// first level where their indices diverge.
fn merge_two(a: Node(k, v), b: Node(k, v), level: Int) -> Node(k, v) {
  let ia = index(node_hash(a), level)
  let ib = index(node_hash(b), level)
  case ia == ib {
    True -> Branch(pow(2, ia), [merge_two(a, b, level + 1)])
    False ->
      case ia < ib {
        True -> Branch(pow(2, ia) + pow(2, ib), [a, b])
        False -> Branch(pow(2, ia) + pow(2, ib), [b, a])
      }
  }
}

fn node_hash(node: Node(k, v)) -> Int {
  case node {
    Leaf(h, _, _) -> h
    Collision(h, _) -> h
    _ -> 0
  }
}

fn collision_get(entries: List(#(k, v)), key: k) -> Result(v, Nil) {
  case entries {
    [] -> Error(Nil)
    [#(k, v), ..rest] ->
      case k == key {
        True -> Ok(v)
        False -> collision_get(rest, key)
      }
  }
}

fn collision_put(entries: List(#(k, v)), key: k, value: v, acc: List(#(k, v))) -> #(List(#(k, v)), Bool) {
  case entries {
    [] -> #(list.reverse([#(key, value), ..acc]), True)
    [#(k, v), ..rest] ->
      case k == key {
        True -> #(list.reverse(acc) |> list.append([#(key, value), ..rest]), False)
        False -> collision_put(rest, key, value, [#(k, v), ..acc])
      }
  }
}

fn collision_remove(entries: List(#(k, v)), key: k) -> #(List(#(k, v)), Bool) {
  collision_remove_loop(entries, key, [])
}

fn collision_remove_loop(entries: List(#(k, v)), key: k, acc: List(#(k, v))) -> #(List(#(k, v)), Bool) {
  case entries {
    [] -> #(list.reverse(acc), False)
    [#(k, v), ..rest] ->
      case k == key {
        True -> #(list.append(list.reverse(acc), rest), True)
        False -> collision_remove_loop(rest, key, [#(k, v), ..acc])
      }
  }
}

fn entries(node: Node(k, v), acc: List(#(k, v))) -> List(#(k, v)) {
  case node {
    Empty -> acc
    Leaf(_, k, v) -> [#(k, v), ..acc]
    Collision(_, es) -> list.append(es, acc)
    Branch(_, children) ->
      list.fold(children, acc, fn(acc, child) { entries(child, acc) })
  }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn hash_key(key: a) -> Int {
  hash_codepoints(string.to_utf_codepoints(string.inspect(key)), 5381)
}

fn hash_codepoints(codepoints, hash) {
  case codepoints {
    [] -> hash
    [cp, ..rest] ->
      hash_codepoints(
        rest,
        { hash * 33 + string.utf_codepoint_to_int(cp) } % 2147483647,
      )
  }
}

fn index(hash, level) -> Int {
  hash / pow(32, level) % 32
}

fn pow(base, exponent) -> Int {
  case exponent <= 0 {
    True -> 1
    False -> base * pow(base, exponent - 1)
  }
}

fn bit_at(bitmap, i) -> Bool {
  bitmap / pow(2, i) % 2 == 1
}

fn bits_below(bitmap, i) -> Int {
  bits_below_loop(bitmap, 0, i, 0)
}

fn bits_below_loop(bitmap, from, to, acc) {
  case from >= to {
    True -> acc
    False ->
      bits_below_loop(
        bitmap,
        from + 1,
        to,
        case bit_at(bitmap, from) {
          True -> acc + 1
          False -> acc
        },
      )
  }
}

fn list_at(items: List(Node(k, v)), index: Int) -> Node(k, v) {
  case items {
    [] -> Empty
    [item, ..rest] ->
      case index <= 0 {
        True -> item
        False -> list_at(rest, index - 1)
      }
  }
}

fn insert_at(items: List(Node(k, v)), index: Int, item: Node(k, v)) -> List(Node(k, v)) {
  case items {
    [] -> [item]
    [first, ..rest] ->
      case index <= 0 {
        True -> [item, first, ..rest]
        False -> [first, ..insert_at(rest, index - 1, item)]
      }
  }
}

fn replace_at(items: List(Node(k, v)), index: Int, item: Node(k, v)) -> List(Node(k, v)) {
  case items {
    [] -> []
    [first, ..rest] ->
      case index <= 0 {
        True -> [item, ..rest]
        False -> [first, ..replace_at(rest, index - 1, item)]
      }
  }
}

fn remove_at(items: List(Node(k, v)), index: Int) -> List(Node(k, v)) {
  case items {
    [] -> []
    [first, ..rest] ->
      case index <= 0 {
        True -> rest
        False -> [first, ..remove_at(rest, index - 1)]
      }
  }
}
