import gleam/int
import gleam/io

// Phase 1 probe: does `Buffer(Buffer(Int))` work end-to-end (nested glue,
// ownership, extraction)? Expected output: 120.
//
// The wrappers give `buffer.new` an expected element type (the compiler only
// adopts the element type from an expected context, not from a bare return).

type Inner {
  Inner(buf: Buffer(Int))
}

type Outer {
  Outer(buf: Buffer(Buffer(Int)))
}

fn make_inner() -> Inner {
  Inner(buffer.new(3))
}

fn make_outer() -> Outer {
  Outer(buffer.new(2))
}

pub fn main() {
  let Outer(outer) = make_outer()
  let Inner(inner) = make_inner()
  let inner = buffer.set(inner, 0, 10)
  let inner = buffer.set(inner, 1, 20)
  let outer = buffer.set(outer, 0, inner)
  let Inner(inner2) = make_inner()
  let inner2 = buffer.set(inner2, 0, 100)
  let outer = buffer.set(outer, 1, inner2)
  let a = buffer.get(outer, 0)
  let b = buffer.get(outer, 1)
  io.println(int.to_string(buffer.get(a, 1) + buffer.get(b, 0)))
}
