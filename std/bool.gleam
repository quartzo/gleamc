pub fn and(a: Bool, b: Bool) -> Bool {
  case a {
    True -> b
    False -> False
  }
}

pub fn or(a: Bool, b: Bool) -> Bool {
  case a {
    True -> True
    False -> b
  }
}

pub fn negate(bool: Bool) -> Bool {
  case bool {
    True -> False
    False -> True
  }
}

pub fn nor(a: Bool, b: Bool) -> Bool {
  negate(or(a, b))
}

pub fn nand(a: Bool, b: Bool) -> Bool {
  negate(and(a, b))
}

pub fn exclusive_or(a: Bool, b: Bool) -> Bool {
  case a, b {
    True, False -> True
    False, True -> True
    _, _ -> False
  }
}

pub fn exclusive_nor(a: Bool, b: Bool) -> Bool {
  negate(exclusive_or(a, b))
}

pub fn guard(requirement: Bool, consequence: a, alternative: fn() -> a) -> a {
  case requirement {
    True -> consequence
    False -> alternative()
  }
}

pub fn lazy_guard(
  requirement: Bool,
  consequence: fn() -> a,
  alternative: fn() -> a,
) -> a {
  case requirement {
    True -> consequence()
    False -> alternative()
  }
}
