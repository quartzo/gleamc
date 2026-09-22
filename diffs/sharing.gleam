import gleam/int
import gleam/io

type Chain(a) {
  Link(value: a, next: Chain(a))
  End
}

fn rev(c: Chain(a), acc: Chain(a)) -> Chain(a) {
  case c {
    Link(h, r) -> rev(r, Link(h, acc))
    End -> acc
  }
}

fn len(c: Chain(a)) -> Int {
  case c {
    Link(_, rest) -> 1 + len(rest)
    End -> 0
  }
}

pub fn main() {
  let xs = Link(1, Link(2, Link(3, End)))
  io.println(int.to_string(len(rev(xs, End))))
  io.println(int.to_string(len(xs)))
}
