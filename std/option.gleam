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

pub fn is_none(option: Option(a)) -> Bool {
  case option {
    Some(_) -> False
    None -> True
  }
}

pub fn then(option: Option(a), apply: fn(a) -> Option(b)) -> Option(b) {
  case option {
    Some(value) -> apply(value)
    None -> None
  }
}

pub fn or(first: Option(a), second: Option(a)) -> Option(a) {
  case first {
    Some(_) -> first
    None -> second
  }
}

pub fn to_result(option: Option(a), error: e) -> Result(a, e) {
  case option {
    Some(value) -> Ok(value)
    None -> Error(error)
  }
}

pub fn from_result(result: Result(a, e)) -> Option(a) {
  case result {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

pub fn flatten(option: Option(Option(a))) -> Option(a) {
  case option {
    Some(inner) -> inner
    None -> None
  }
}

pub fn lazy_unwrap(option: Option(a), default: fn() -> a) -> a {
  case option {
    Some(value) -> value
    None -> default()
  }
}
