import gleam/int
import gleam/io

type Name =
  String

type Pair(a) =
  #(a, a)

fn duplicate(x: a) -> Pair(a) {
  #(x, x)
}

fn greet(who: Name) -> Name {
  "hi " <> who
}

pub fn main() {
  io.println(greet("Lucy"))
  let #(a, b) = duplicate(3)
  io.println(int.to_string(a + b))
}
