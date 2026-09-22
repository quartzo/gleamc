pub type Option(a) {
  Some(value: a)
  None
}

pub fn unwrap_or(option: Option(a), default: a) -> a {
  case option {
    Some(value) -> value
    None -> default
  }
}

pub fn map(option: Option(a), with: fn(a) -> b) -> Option(b) {
  case option {
    Some(value) -> Some(with(value))
    None -> None
  }
}

pub fn is_some(option: Option(a)) -> Bool {
  case option {
    Some(_) -> True
    None -> False
  }
}

pub fn unwrap(option: Option(a), default: a) -> a {
  unwrap_or(option, default)
}
