import gleam/int
import gleam/io

type Wrapped(a) {
  Wrapped(value: a)
  Empty
}

fn unwrap(wrapped: Wrapped(a), default: a) -> a {
  case wrapped {
    Wrapped(v) -> v
    Empty -> default
  }
}

pub fn main() {
  io.println(unwrap(Wrapped("hi"), "none"))
  io.println(int.to_string(unwrap(Wrapped(7), 0)))
  io.println(unwrap(Empty, "fallback"))
}
