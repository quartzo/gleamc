import gleam/int
import gleam/io

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

fn inner_with(n: Int) -> Inner {
  let Inner(b) = make_inner()
  Inner(buffer.set(b, 0, n))
}

pub fn main() {
  let Outer(outer0) = make_outer()
  io.println("lazy0=" <> bool.to_string(buffer.is_null(buffer.get(outer0, 0))))

  let Inner(i0) = inner_with(11)
  let Outer(outer1) = make_outer()
  let outer1 = buffer.set(outer1, 0, i0)
  io.println("present=" <> bool.to_string(buffer.is_null(buffer.get(outer1, 0))))

  let taken = buffer.take(outer1, 0)
  io.println("after_take_null=" <> bool.to_string(buffer.is_null(buffer.get(outer1, 0))))
  io.println("taken=" <> int.to_string(buffer.get(taken, 0)))
  let outer1 = buffer.set(outer1, 0, taken)
  io.println("restored=" <> int.to_string(buffer.get(buffer.get(outer1, 0), 0)))

  let shared = outer1
  let taken2 = buffer.take(shared, 0)
  io.println("shared_still_present=" <> bool.to_string(buffer.is_null(buffer.get(shared, 0))))
  io.println("taken2=" <> int.to_string(buffer.get(taken2, 0)))
}
