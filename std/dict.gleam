import gleam/list
import gleam/option.{None, Some}
import gleam/order

pub opaque type Dict(k, v) {
  Dict(entries: List(#(k, v)))
}

pub fn new() -> Dict(k, v) {
  Dict([])
}

pub fn is_empty(dict: Dict(k, v)) -> Bool {
  let entries = entries_of(dict)
  case entries {
    [] -> True
    _ -> False
  }
}

pub fn size(dict: Dict(k, v)) -> Int {
  let entries = entries_of(dict)
  list.length(entries)
}

pub fn from_list(entries: List(#(k, v))) -> Dict(k, v) {
  list.fold(entries, new(), fn(dict, entry) {
    let #(key, value) = entry
    insert(dict, key, value)
  })
}

pub fn to_list(dict: Dict(k, v)) -> List(#(k, v)) {
  let entries = entries_of(dict)
  entries
}

pub fn keys(dict: Dict(k, v)) -> List(k) {
  let entries = entries_of(dict)
  list.map(entries, fn(entry) {
    let #(key, _) = entry
    key
  })
}

pub fn values(dict: Dict(k, v)) -> List(v) {
  let entries = entries_of(dict)
  list.map(entries, fn(entry) {
    let #(_, value) = entry
    value
  })
}

pub fn get(dict: Dict(k, v), key: k) -> Result(v, Nil) {
  let entries = entries_of(dict)
  get_entries(entries, key)
}

fn get_entries(entries: List(#(k, v)), key: k) -> Result(v, Nil) {
  case entries {
    [] -> Error(Nil)
    [entry, ..rest] -> {
      let #(entry_key, value) = entry
      case key_order(key, entry_key) {
        order.Eq -> Ok(value)
        order.Lt -> Error(Nil)
        order.Gt -> get_entries(rest, key)
      }
    }
  }
}

pub fn has_key(dict: Dict(k, v), key: k) -> Bool {
  case get(dict, key) {
    Ok(_) -> True
    Error(_) -> False
  }
}

pub fn insert(dict: Dict(k, v), key: k, value: v) -> Dict(k, v) {
  let entries = entries_of(dict)
  Dict(insert_entries(entries, key, value))
}

fn insert_entries(entries: List(#(k, v)), key: k, value: v) -> List(#(k, v)) {
  case entries {
    [] -> [#(key, value)]
    [entry, ..rest] -> {
      let #(entry_key, _) = entry
      case key_order(key, entry_key) {
        order.Lt -> [#(key, value), ..entries]
        order.Eq -> [#(key, value), ..rest]
        order.Gt -> [entry, ..insert_entries(rest, key, value)]
      }
    }
  }
}

pub fn delete(dict: Dict(k, v), key: k) -> Dict(k, v) {
  let entries = entries_of(dict)
  Dict(delete_entries(entries, key))
}

fn delete_entries(entries: List(#(k, v)), key: k) -> List(#(k, v)) {
  case entries {
    [] -> []
    [entry, ..rest] -> {
      let #(entry_key, _) = entry
      case key_order(key, entry_key) {
        order.Eq -> rest
        order.Lt -> entries
        order.Gt -> [entry, ..delete_entries(rest, key)]
      }
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

pub fn map_values(dict: Dict(k, v), with: fn(k, v) -> b) -> Dict(k, b) {
  let entries = entries_of(dict)
  Dict(
    list.map(entries, fn(entry) {
      let #(key, value) = entry
      #(key, with(key, value))
    }),
  )
}

pub fn fold(dict: Dict(k, v), from: acc, with: fn(acc, k, v) -> acc) -> acc {
  let entries = entries_of(dict)
  list.fold(entries, from, fn(acc, entry) {
    let #(key, value) = entry
    with(acc, key, value)
  })
}

pub fn filter(dict: Dict(k, v), keeping: fn(k, v) -> Bool) -> Dict(k, v) {
  let entries = entries_of(dict)
  Dict(
    list.filter(entries, fn(entry) {
      let #(key, value) = entry
      keeping(key, value)
    }),
  )
}

pub fn each(dict: Dict(k, v), with: fn(k, v) -> a) -> Nil {
  let entries = entries_of(dict)
  list.each(entries, fn(entry) {
    let #(key, value) = entry
    with(key, value)
  })
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

fn entries_of(dict: Dict(k, v)) -> List(#(k, v)) {
  case dict {
    Dict(entries) -> entries
  }
}

pub fn merge(into: Dict(k, v), from: Dict(k, v)) -> Dict(k, v) {
  merge_entries(entries_of(from), into)
}

fn merge_entries(entries: List(#(k, v)), dict: Dict(k, v)) -> Dict(k, v) {
  case entries {
    [] -> dict
    [entry, ..rest] -> {
      let #(key, value) = entry
      merge_entries(rest, insert(dict, key, value))
    }
  }
}

pub fn combine(
  dict: Dict(k, v),
  other: Dict(k, v),
  with: fn(v, v) -> v,
) -> Dict(k, v) {
  combine_entries(entries_of(other), dict, with)
}

fn combine_entries(
  entries: List(#(k, v)),
  dict: Dict(k, v),
  with: fn(v, v) -> v,
) -> Dict(k, v) {
  case entries {
    [] -> dict
    [entry, ..rest] -> {
      let #(key, value) = entry
      let next = case get(dict, key) {
        Ok(existing) -> insert(dict, key, with(existing, value))
        Error(_) -> insert(dict, key, value)
      }
      combine_entries(rest, next, with)
    }
  }
}

pub fn take(dict: Dict(k, v), desired_keys: List(k)) -> Dict(k, v) {
  Dict(take_entries(entries_of(dict), desired_keys, []))
}

fn take_entries(
  entries: List(#(k, v)),
  desired_keys: List(k),
  acc: List(#(k, v)),
) -> List(#(k, v)) {
  case entries {
    [] -> list.reverse(acc)
    [entry, ..rest] -> {
      let #(key, _) = entry
      case list.contains(desired_keys, key) {
        True -> take_entries(rest, desired_keys, [entry, ..acc])
        False -> take_entries(rest, desired_keys, acc)
      }
    }
  }
}

pub fn drop(dict: Dict(k, v), disallowed_keys: List(k)) -> Dict(k, v) {
  Dict(drop_entries(entries_of(dict), disallowed_keys, []))
}

fn drop_entries(
  entries: List(#(k, v)),
  disallowed_keys: List(k),
  acc: List(#(k, v)),
) -> List(#(k, v)) {
  case entries {
    [] -> list.reverse(acc)
    [entry, ..rest] -> {
      let #(key, _) = entry
      case list.contains(disallowed_keys, key) {
        True -> drop_entries(rest, disallowed_keys, acc)
        False -> drop_entries(rest, disallowed_keys, [entry, ..acc])
      }
    }
  }
}

pub fn group(key: fn(v) -> k, list: List(v)) -> Dict(k, List(v)) {
  group_entries(list, key, new())
}

fn group_entries(
  values: List(v),
  key: fn(v) -> k,
  dict: Dict(k, List(v)),
) -> Dict(k, List(v)) {
  case values {
    [] -> dict
    [value, ..rest] -> {
      let value_key = key(value)
      let next = case get(dict, value_key) {
        Ok(existing) -> insert(dict, value_key, [value, ..existing])
        Error(_) -> insert(dict, value_key, [value])
      }
      group_entries(rest, key, next)
    }
  }
}
