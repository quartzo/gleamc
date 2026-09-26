import gleam/big_dict
import gleam/int
import gleam/io
import gleam/result

fn empty() -> big_dict.BigDict(String, Int) {
  big_dict.new()
}

pub fn main() {
  let d = empty()
  let d = big_dict.insert(d, "a", 1)
  let d = big_dict.insert(d, "b", 2)
  let d = big_dict.insert(d, "c", 3)
  let d = big_dict.delete(d, "b")
  io.println("size=" <> int.to_string(big_dict.size(d)))
  io.println("a=" <> int.to_string(result.unwrap(big_dict.get(d, "a"), -1)))
  io.println("b=" <> int.to_string(result.unwrap(big_dict.get(d, "b"), -1)))
  io.println("c=" <> int.to_string(result.unwrap(big_dict.get(d, "c"), -1)))
  io.println("has_c=" <> bool.to_string(big_dict.has_key(d, "c")))
  io.println("has_z=" <> bool.to_string(big_dict.has_key(d, "z")))
}
