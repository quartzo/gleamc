pub type Order {
  Lt
  Eq
  Gt
}

pub fn to_int(order: Order) -> Int {
  case order {
    Lt -> -1
    Eq -> 0
    Gt -> 1
  }
}

pub fn negate(order: Order) -> Order {
  case order {
    Lt -> Gt
    Eq -> Eq
    Gt -> Lt
  }
}

pub fn compare(a: Order, b: Order) -> Order {
  case a, b {
    Eq, Eq -> Eq
    Lt, _ -> Lt
    _, Gt -> Lt
    _, _ -> Gt
  }
}

pub fn reverse(orderer: fn(a, a) -> Order) -> fn(a, a) -> Order {
  fn(a, b) { orderer(b, a) }
}

pub fn break_tie(a: Order, b: Order) -> Order {
  case a {
    Lt -> Lt
    Gt -> Gt
    Eq -> b
  }
}

pub fn lazy_break_tie(a: Order, comparison: fn() -> Order) -> Order {
  case a {
    Lt -> Lt
    Gt -> Gt
    Eq -> comparison()
  }
}
