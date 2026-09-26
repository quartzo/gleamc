import gleam/big_dict
import gleam/int
import gleam/io

// Two workloads, mirroring `bench/dictbench.gleam` (unique) plus a shared one:
//  - unique: `n` String-keyed inserts + `n` gets in a tail-recursive loop.
//  - shared: a base of `base_n` entries kept live while `m` single-key inserts
//    are layered on top (each one sees the base shared, as in `merge_dicts`).

const n = 100000
const base_n = 50000
const m = 10000

fn build(i: Int, limit: Int, d: big_dict.BigDict(String, Int)) -> big_dict.BigDict(String, Int) {
  case i >= limit {
    True -> d
    False -> build(i + 1, limit, big_dict.insert(d, int.to_string(i), i))
  }
}

fn sum(i: Int, d: big_dict.BigDict(String, Int), acc: Int) -> Int {
  case i >= n {
    True -> acc
    False -> {
      let acc = case big_dict.get(d, int.to_string(i)) {
        Ok(v) -> acc + v
        Error(_) -> acc
      }
      sum(i + 1, d, acc)
    }
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
  let d = build(0, n, big_dict.new())
  io.println("unique=" <> int.to_string(sum(0, d, 0)))
  let base = build(0, base_n, big_dict.new())
  io.println("shared=" <> int.to_string(shared(base, 0, 0)))
}
