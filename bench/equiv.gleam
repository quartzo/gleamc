import gleam/big_dict
import gleam/dict
import gleam/io
import gleam/int

// Build the same operation sequence into the flat `dict` and the lazy
// `big_dict`, then print both `to_list` (key-sorted). Identical output is the
// equivalence check.

const n = 2000

fn bd(i: Int, d: big_dict.BigDict(String, Int)) -> big_dict.BigDict(String, Int) {
  case i >= n {
    True -> d
    False -> {
      let d = big_dict.insert(d, int.to_string(i), i * 3)
      let d = case i % 7 == 0 {
        True -> big_dict.delete(d, int.to_string(i / 2))
        False -> d
      }
      bd(i + 1, d)
    }
  }
}

fn fl(i: Int, d: dict.Dict(String, Int)) -> dict.Dict(String, Int) {
  case i >= n {
    True -> d
    False -> {
      let d = dict.insert(d, int.to_string(i), i * 3)
      let d = case i % 7 == 0 {
        True -> dict.delete(d, int.to_string(i / 2))
        False -> d
      }
      fl(i + 1, d)
    }
  }
}

pub fn main() {
  let a = bd(0, big_dict.new())
  let b = fl(0, dict.new())
  io.println("big=" <> gleamc.show(big_dict.to_list(a)))
  io.println("flat=" <> gleamc.show(dict.to_list(b)))
}
