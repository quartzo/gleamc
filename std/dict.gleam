import gleam/list
import gleam/option.{None, Some}
import gleam/order

// A persistent dictionary: open-addressing hash table over a `Buffer` of
// buckets (linear probing, power-of-two capacity). `Buffer` is copy-on-write,
// so a uniquely-owned dict updates in place (O(1)) and a shared one copies.
// Keys are hashed natively (`gleamc.hash`, FNV-1a). `to_list` sorts by key, so
// iteration order is stable and matches the previous implementation.

pub opaque type Dict(k, v) {
  Dict(slots: Buffer(Bucket(k, v)), cap: Int, count: Int)
}

type Bucket(k, v) {
  Empty
  Used(key: k, value: v)
  Tomb(key: k, value: v)
}

const min_cap = 16

pub fn new() -> Dict(k, v) {
  Dict(slots: buffer.new(min_cap), cap: min_cap, count: 0)
}

pub fn is_empty(dict: Dict(k, v)) -> Bool {
  size(dict) == 0
}

pub fn size(dict: Dict(k, v)) -> Int {
  let Dict(_, _, count) = dict
  count
}

pub fn from_list(entries: List(#(k, v))) -> Dict(k, v) {
  list.fold(entries, new(), fn(dict, entry) {
    let #(key, value) = entry
    insert(dict, key, value)
  })
}

/// Iteration is by key order, so the observable order is stable.
pub fn to_list(dict: Dict(k, v)) -> List(#(k, v)) {
  let Dict(slots, cap, _) = dict
  let entries = collect(slots, cap, 0, [])
  sort_entries(entries)
}

fn collect(
  slots: Buffer(Bucket(k, v)),
  cap: Int,
  i: Int,
  acc: List(#(k, v)),
) -> List(#(k, v)) {
  case i >= cap {
    True -> acc
    False ->
      case buffer.get(slots, i) {
        Used(key, value) -> collect(slots, cap, i + 1, [#(key, value), ..acc])
        _ -> collect(slots, cap, i + 1, acc)
      }
  }
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
      case gleamc.key_compare(key_a, key_b) > 0 {
        True -> merge_entries(a, rest_b, [entry_b, ..acc])
        False -> merge_entries(rest_a, b, [entry_a, ..acc])
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
  let Dict(slots, cap, _) = dict
  probe_get(slots, cap, gleamc.hash(key) % cap, key)
}

fn probe_get(slots: Buffer(Bucket(k, v)), cap: Int, i: Int, key: k) -> Result(v, Nil) {
  case buffer.get(slots, i) {
    Empty -> Error(Nil)
    Used(k, value) ->
      case k == key {
        True -> Ok(value)
        False -> probe_get(slots, cap, next(cap, i), key)
      }
    Tomb(_, _) -> probe_get(slots, cap, next(cap, i), key)
  }
}

pub fn has_key(dict: Dict(k, v), key: k) -> Bool {
  case get(dict, key) {
    Ok(_) -> True
    Error(_) -> False
  }
}

pub fn insert(dict: Dict(k, v), key: k, value: v) -> Dict(k, v) {
  let dict = grow_if_needed(dict)
  let Dict(slots, cap, count) = dict
  let #(slots, added) = place(slots, cap, gleamc.hash(key) % cap, key, value, cap)
  Dict(slots, cap, case added {
    True -> count + 1
    False -> count
  })
}

fn place(
  slots: Buffer(Bucket(k, v)),
  cap: Int,
  i: Int,
  key: k,
  value: v,
  tomb: Int,
) -> #(Buffer(Bucket(k, v)), Bool) {
  case buffer.get(slots, i) {
    Empty ->
      case tomb == cap {
        True -> #(buffer.set(slots, i, Used(key, value)), True)
        False -> #(buffer.set(slots, tomb, Used(key, value)), True)
      }
    Used(k, _) ->
      case k == key {
        True -> #(buffer.set(slots, i, Used(key, value)), False)
        False -> place(slots, cap, next(cap, i), key, value, tomb)
      }
    Tomb(_, _) -> {
      let tomb = case tomb == cap {
        True -> i
        False -> tomb
      }
      place(slots, cap, next(cap, i), key, value, tomb)
    }
  }
}

pub fn delete(dict: Dict(k, v), key: k) -> Dict(k, v) {
  let Dict(slots, cap, count) = dict
  let #(slots, removed) = probe_delete(slots, cap, gleamc.hash(key) % cap, key)
  Dict(slots, cap, case removed {
    True -> count - 1
    False -> count
  })
}

fn probe_delete(
  slots: Buffer(Bucket(k, v)),
  cap: Int,
  i: Int,
  key: k,
) -> #(Buffer(Bucket(k, v)), Bool) {
  case buffer.get(slots, i) {
    Empty -> #(slots, False)
    Tomb(_, _) -> probe_delete(slots, cap, next(cap, i), key)
    Used(k, value) ->
      case k == key {
        // Keep the key/value bytes: the tombstone just marks the slot free.
        True -> #(buffer.set(slots, i, Tomb(k, value)), True)
        False -> probe_delete(slots, cap, next(cap, i), key)
      }
  }
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

fn grow_if_needed(dict: Dict(k, v)) -> Dict(k, v) {
  let Dict(slots, cap, count) = dict
  case count * 4 > cap * 3 {
    True -> Dict(rehash(slots, cap, cap * 2, 0), cap * 2, count)
    False -> dict
  }
}

fn rehash(
  old: Buffer(Bucket(k, v)),
  old_cap: Int,
  new_cap: Int,
  i: Int,
) -> Buffer(Bucket(k, v)) {
  rehash_loop(old, old_cap, buffer.new(new_cap), new_cap, i)
}

fn rehash_loop(
  old: Buffer(Bucket(k, v)),
  old_cap: Int,
  new: Buffer(Bucket(k, v)),
  new_cap: Int,
  i: Int,
) -> Buffer(Bucket(k, v)) {
  case i >= old_cap {
    True -> new
    False ->
      case buffer.get(old, i) {
        Used(key, value) -> {
          let #(new, _) = place(new, new_cap, gleamc.hash(key) % new_cap, key, value, new_cap)
          rehash_loop(old, old_cap, new, new_cap, i + 1)
        }
        _ -> rehash_loop(old, old_cap, new, new_cap, i + 1)
      }
  }
}

fn next(cap: Int, i: Int) -> Int {
  case i + 1 >= cap {
    True -> 0
    False -> i + 1
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
