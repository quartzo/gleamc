import gleam/io

type Wrapped(a) {
  Wrapped(value: a)
  Empty
}

fn unwrap(wrapped: Wrapped(a), default: a) -> a {
  case wrapped {
    Wrapped(value: v) -> v
    Empty -> default
  }
}

pub fn main() {
  io.println(unwrap(Wrapped(value: "hi"), "none"))
  io.println(unwrap(Empty, "fallback"))
}
