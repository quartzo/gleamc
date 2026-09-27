import gleam/int
import gleam/io

pub type Box(a) {
  Box(items: List(a))
}

fn capture(x: Int) -> fn() -> Int {
  fn() { x }
}

fn via_list() -> Int {
  let items = [capture(41), capture(10)]
  case items {
    [f, g] -> f() + g()
    _ -> 0
  }
}

fn via_box() -> Int {
  let Box(boxed) = Box(items: [capture(7)])
  case boxed {
    [f, ..] -> f()
    [] -> 0
  }
}

pub fn main() {
  io.println(int.to_string(via_list() + via_box()))
}
