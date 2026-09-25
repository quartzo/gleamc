import gleam/dict
import gleam/int
import gleam/io

const n = 100000

// 100k String-keyed inserts + 100k gets, to isolate `dict` cost.
pub fn main() {
  let d = build(0, dict.new())
  io.println(int.to_string(sum(0, d, 0)))
}

fn build(i: Int, d: dict.Dict(String, Int)) -> dict.Dict(String, Int) {
  case i >= n {
    True -> d
    False -> build(i + 1, dict.insert(d, int.to_string(i), i))
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
