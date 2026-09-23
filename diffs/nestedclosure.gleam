import gleam/io
import gleam/result
import gleam/string

fn expand(prefix: String, names: List(String)) -> Result(List(String), Nil) {
  case names {
    [] -> Ok([])
    [name, ..rest] -> {
      use tail <- result.try(expand(prefix, rest))
      use marked <- result.try(Ok(prefix <> ":" <> name))
      Ok([marked, ..tail])
    }
  }
}

fn count(values: List(Int), target: Int) -> Result(Int, Nil) {
  case values {
    [] -> Ok(0)
    [value, ..rest] -> {
      use total <- result.try(count(rest, target))
      use is_match <- result.try(Ok(value == target))
      case is_match {
        True -> Ok(total + 1)
        False -> Ok(total)
      }
    }
  }
}

fn make_adder(x: Int) -> fn(Int) -> Int {
  let add = fn(value: Int) { value + x }
  add
}

pub fn main() {
  let assert Ok(out) = expand("p", ["a", "b", "c"])
  io.println(string.join(out, ","))
  let assert Ok(n) = count([1, 2, 1, 3, 1], 1)
  io.println(string.inspect(n))
  let add_ten = make_adder(10)
  io.println(string.inspect(add_ten(5)))
  let triple = fn(value: Int) { value * 3 }
  io.println(string.inspect(triple(4)))
}
