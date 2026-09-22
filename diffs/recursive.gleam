import gleam/int
import gleam/io

type Nat {
  Suc(pred: Nat)
  Zero
}

fn to_int(n: Nat) -> Int {
  case n {
    Suc(p) -> 1 + to_int(p)
    Zero -> 0
  }
}

pub fn main() {
  io.println(int.to_string(to_int(Suc(Suc(Suc(Zero))))))
}
