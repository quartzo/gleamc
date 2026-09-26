import gleam/big_dict
import gleam/int
import gleam/io

const n = 100000

fn build(i: Int, d: big_dict.BigDict(String, Int)) -> big_dict.BigDict(String, Int) {
  case i >= n {
    True -> d
    False -> build(i + 1, big_dict.insert(d, int.to_string(i), i))
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

pub fn main() {
  let d = build(0, big_dict.new())
  io.println("unique=" <> int.to_string(sum(0, d, 0)))
}
