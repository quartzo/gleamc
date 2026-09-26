import gleam/list
import gleam/option.{None, Some}

// A persistent dictionary over a **lazy two-level Buffer**: `slots` is a
// `Buffer` of blocks, and each block is a `Buffer` of buckets materialised on
// first write. A NULL block slot means "all Empty" (the lazy universe), so a
// freshly created dict costs one (empty) spine.
//
// Updates use `buffer.take`: when the spine is uniquely owned the addressed
// block is *moved* out (no retain, so the subsequent `buffer.set` can mutate it
// in place); when the spine is shared the block is retained and the `set` does
// the shallow copy. Either way only the spine and one block are touched, never
// the whole bucket array.
//
// `block_bits`/`block_size` are a power of two so `i / block_size` and
// `i % block_size` lower to shift/mask. `cap` is always a multiple of
// `block_size`.
//
// Keys hash natively (`gleamc.hash`, FNV-1a) and `to_list` sorts by key, so
// iteration order is stable.

pub opaque type BigDict(k, v) {
  BigDict(slots: Buffer(Buffer(Bucket(k, v))), cap: Int, count: Int)
}

type Bucket(k, v) {
  Empty
  Used(key: k, value: v)
  Tomb(key: k, value: v)
}

// `buffer.new` only adopts its element type from an expected context, so an
// empty block is produced through a one-field wrapper.
type BlockBox(k, v) {
  BlockBox(buf: Buffer(Bucket(k, v)))
}

const block_bits = 6
const block_size = 64
const min_cap = 64

pub fn new() -> BigDict(k, v) {
  BigDict(buffer.new(min_cap / block_size), min_cap, 0)
}

pub fn is_empty(dict: BigDict(k, v)) -> Bool {
  size(dict) == 0
}

pub fn size(dict: BigDict(k, v)) -> Int {
  let BigDict(_, _, count) = dict
  count
}

fn empty_block() -> BlockBox(k, v) {
  BlockBox(buffer.new(block_size))
}

// ---------------------------------------------------------------------------
// block-aware slot access
// ---------------------------------------------------------------------------

fn slots_get(slots: Buffer(Buffer(Bucket(k, v))), i: Int) -> Bucket(k, v) {
  let block = buffer.get(slots, i / block_size)
  case buffer.is_null(block) {
    True -> Empty
    False -> buffer.get(block, i % block_size)
  }
}

fn slots_set(
  slots: Buffer(Buffer(Bucket(k, v))),
  i: Int,
  bucket: Bucket(k, v),
) -> Buffer(Buffer(Bucket(k, v))) {
  let ci = i / block_size
  let off = i % block_size
  let block = buffer.take(slots, ci)
  let block = case buffer.is_null(block) {
    True -> {
      let BlockBox(b) = empty_block()
      b
    }
    False -> block
  }
  let block = buffer.set(block, off, bucket)
  buffer.set(slots, ci, block)
}

// ---------------------------------------------------------------------------
// queries
// ---------------------------------------------------------------------------

pub fn get(dict: BigDict(k, v), key: k) -> Result(v, Nil) {
  let BigDict(slots, cap, _) = dict
  probe_get(slots, cap, gleamc.hash(key) % cap, key)
}

fn probe_get(
  slots: Buffer(Buffer(Bucket(k, v))),
  cap: Int,
  i: Int,
  key: k,
) -> Result(v, Nil) {
  case slots_get(slots, i) {
    Empty -> Error(Nil)
    Used(k, value) ->
      case k == key {
        True -> Ok(value)
        False -> probe_get(slots, cap, next(cap, i), key)
      }
    Tomb(_, _) -> probe_get(slots, cap, next(cap, i), key)
  }
}

pub fn has_key(dict: BigDict(k, v), key: k) -> Bool {
  case get(dict, key) {
    Ok(_) -> True
    Error(_) -> False
  }
}

// ---------------------------------------------------------------------------
// updates
// ---------------------------------------------------------------------------

pub fn insert(dict: BigDict(k, v), key: k, value: v) -> BigDict(k, v) {
  let dict = grow_if_needed(dict)
  let BigDict(slots, cap, count) = dict
  let #(slots, added) = place(slots, cap, gleamc.hash(key) % cap, key, value, cap)
  BigDict(slots, cap, case added {
    True -> count + 1
    False -> count
  })
}

fn place(
  slots: Buffer(Buffer(Bucket(k, v))),
  cap: Int,
  i: Int,
  key: k,
  value: v,
  tomb: Int,
) -> #(Buffer(Buffer(Bucket(k, v))), Bool) {
  case slots_get(slots, i) {
    Empty ->
      case tomb == cap {
        True -> #(slots_set(slots, i, Used(key, value)), True)
        False -> #(slots_set(slots, tomb, Used(key, value)), True)
      }
    Used(k, _) ->
      case k == key {
        True -> #(slots_set(slots, i, Used(key, value)), False)
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

pub fn delete(dict: BigDict(k, v), key: k) -> BigDict(k, v) {
  let BigDict(slots, cap, count) = dict
  let #(slots, removed) = probe_delete(slots, cap, gleamc.hash(key) % cap, key)
  BigDict(slots, cap, case removed {
    True -> count - 1
    False -> count
  })
}

fn probe_delete(
  slots: Buffer(Buffer(Bucket(k, v))),
  cap: Int,
  i: Int,
  key: k,
) -> #(Buffer(Buffer(Bucket(k, v))), Bool) {
  case slots_get(slots, i) {
    Empty -> #(slots, False)
    Tomb(_, _) -> probe_delete(slots, cap, next(cap, i), key)
    Used(k, value) ->
      case k == key {
        True -> #(slots_set(slots, i, Tomb(k, value)), True)
        False -> probe_delete(slots, cap, next(cap, i), key)
      }
  }
}

pub fn upsert(
  dict: BigDict(k, v),
  key: k,
  with: fn(Option(v)) -> v,
) -> BigDict(k, v) {
  case get(dict, key) {
    Ok(value) -> insert(dict, key, with(Some(value)))
    Error(_) -> insert(dict, key, with(None))
  }
}

// ---------------------------------------------------------------------------
// growth
// ---------------------------------------------------------------------------

fn grow_if_needed(dict: BigDict(k, v)) -> BigDict(k, v) {
  let BigDict(slots, cap, count) = dict
  case count * 4 > cap * 3 {
    True -> BigDict(rehash(slots, cap, cap * 2, 0), cap * 2, count)
    False -> dict
  }
}

fn rehash(
  old: Buffer(Buffer(Bucket(k, v))),
  old_cap: Int,
  new_cap: Int,
  i: Int,
) -> Buffer(Buffer(Bucket(k, v))) {
  rehash_loop(old, old_cap, buffer.new(new_cap / block_size), new_cap, i)
}

fn rehash_loop(
  old: Buffer(Buffer(Bucket(k, v))),
  old_cap: Int,
  new: Buffer(Buffer(Bucket(k, v))),
  new_cap: Int,
  i: Int,
) -> Buffer(Buffer(Bucket(k, v))) {
  case i >= old_cap {
    True -> new
    False ->
      case slots_get(old, i) {
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

// ---------------------------------------------------------------------------
// iteration
// ---------------------------------------------------------------------------

pub fn from_list(entries: List(#(k, v))) -> BigDict(k, v) {
  list.fold(entries, new(), fn(dict, entry) {
    let #(key, value) = entry
    insert(dict, key, value)
  })
}

pub fn to_list(dict: BigDict(k, v)) -> List(#(k, v)) {
  let BigDict(slots, cap, _) = dict
  let entries = collect(slots, cap, 0, [])
  sort_entries(entries)
}

fn collect(
  slots: Buffer(Buffer(Bucket(k, v))),
  cap: Int,
  i: Int,
  acc: List(#(k, v)),
) -> List(#(k, v)) {
  case i >= cap {
    True -> acc
    False ->
      case slots_get(slots, i) {
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

pub fn keys(dict: BigDict(k, v)) -> List(k) {
  list.map(to_list(dict), fn(entry) {
    let #(key, _) = entry
    key
  })
}

pub fn values(dict: BigDict(k, v)) -> List(v) {
  list.map(to_list(dict), fn(entry) {
    let #(_, value) = entry
    value
  })
}

pub fn fold(dict: BigDict(k, v), from: acc, with: fn(acc, k, v) -> acc) -> acc {
  list.fold(to_list(dict), from, fn(acc, entry) {
    let #(key, value) = entry
    with(acc, key, value)
  })
}

pub fn map_values(dict: BigDict(k, v), with: fn(k, v) -> b) -> BigDict(k, b) {
  from_list(list.map(to_list(dict), fn(entry) {
    let #(key, value) = entry
    #(key, with(key, value))
  }))
}

pub fn merge(into: BigDict(k, v), from: BigDict(k, v)) -> BigDict(k, v) {
  list.fold(to_list(from), into, fn(dict, entry) {
    let #(key, value) = entry
    insert(dict, key, value)
  })
}
