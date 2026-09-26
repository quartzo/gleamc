import gleam/dict
import gleam/int
import gleam/io

// Same two workloads as `bench/big_dictbench.gleam`, but over the flat `dict`.

const n = 100000
const base_n = 50000
const m = 10000

fn build(i: Int, limit: Int, d: dict.Dict(String, Int)) -> dict.Dict(String, Int) {
  case i >= limit {
    True -> d
    False -> build(i + 1, limit, dict.insert(d, int.to_string(i), i))
  }
}

fn sum(i: Int, d: dict.Dict(String, Int), acc: Int) -> Int {
  case i >= n {
    True -> acc
    False -> {
      let acc = case dict.get(d, int.to_string(i)) {
        Ok(v) -> acc + v
        Error(_) -> acc
      }
      sum(i + 1, d, acc)
    }
  }
}

fn shared(base: dict.Dict(String, Int), i: Int, acc: Int) -> Int {
  case i >= m {
    True -> acc
    False -> {
      let d = dict.insert(base, int.to_string(i), i)
      shared(base, i + 1, acc + dict.size(d))
    }
  }
}

pub fn main() {
  let d = build(0, n, dict.new())
  io.println("unique=" <> int.to_string(sum(0, d, 0)))
  let base = build(0, base_n, dict.new())
  io.println("shared=" <> int.to_string(shared(base, 0, 0)))
}
