import gleam/big_dict
import gleam/int
import gleam/io

const base_n = 50000
const m = 10000

fn build(i: Int, limit: Int, d: big_dict.BigDict(String, Int)) -> big_dict.BigDict(String, Int) {
  case i >= limit {
    True -> d
    False -> build(i + 1, limit, big_dict.insert(d, int.to_string(i), i))
  }
}

fn shared(base: big_dict.BigDict(String, Int), i: Int, acc: Int) -> Int {
  case i >= m {
    True -> acc
    False -> {
      let d = big_dict.insert(base, int.to_string(i), i)
      shared(base, i + 1, acc + big_dict.size(d))
    }
  }
}

pub fn main() {
  let base = build(0, base_n, big_dict.new())
  io.println("shared=" <> int.to_string(shared(base, 0, 0)))
}
