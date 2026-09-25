import gleam/io
import gleam/int

// A tail-recursive loop with a data-dependent branch, so the backend cannot
// fold it into a closed form. 200M iterations.
pub fn main() {
  io.println(int.to_string(work(0, 200000000, 0)))
}

fn work(i: Int, n: Int, acc: Int) -> Int {
  case i >= n {
    True -> acc
    False -> {
      let acc = case acc > 1000000 {
        True -> acc - 1000000
        False -> acc + i
      }
      work(i + 1, n, acc)
    }
  }
}
