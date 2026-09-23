//// Small shared helpers for the compiler.

import gleam/dict.{type Dict}
import gleam/list

/// Removes duplicates while preserving first-seen order, in O(n).
pub fn dedupe(items: List(a)) -> List(a) {
  dedupe_loop(items, dict.new(), [])
}

fn dedupe_loop(items: List(a), seen: Dict(a, Bool), acc: List(a)) -> List(a) {
  case items {
    [] -> list.reverse(acc)
    [item, ..rest] ->
      case dict.get(seen, item) {
        Ok(_) -> dedupe_loop(rest, seen, acc)
        Error(_) -> dedupe_loop(rest, dict.insert(seen, item, True), [item, ..acc])
      }
  }
}

/// Like `dedupe`, but keyed by a derived value (e.g. a type's textual key), so
/// structurally-equal items are collapsed without needing an `Eq` instance.
pub fn dedupe_by(items: List(a), key: fn(a) -> String) -> List(a) {
  dedupe_by_loop(items, key, dict.new(), [])
}

fn dedupe_by_loop(
  items: List(a),
  key: fn(a) -> String,
  seen: Dict(String, Bool),
  acc: List(a),
) -> List(a) {
  case items {
    [] -> list.reverse(acc)
    [item, ..rest] -> {
      let k = key(item)
      case dict.get(seen, k) {
        Ok(_) -> dedupe_by_loop(rest, key, seen, acc)
        Error(_) ->
          dedupe_by_loop(rest, key, dict.insert(seen, k, True), [item, ..acc])
      }
    }
  }
}
