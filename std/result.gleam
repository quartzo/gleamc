pub type Result(a, e) {
  Ok(value: a)
  Error(reason: e)
}

pub fn unwrap_or(result: Result(a, e), default: a) -> a {
  case result {
    Ok(value) -> value
    Error(_) -> default
  }
}

pub fn map(result: Result(a, e), with: fn(a) -> b) -> Result(b, e) {
  case result {
    Ok(value) -> Ok(with(value))
    Error(reason) -> Error(reason)
  }
}

pub fn unwrap(result: Result(a, e), default: a) -> a {
  unwrap_or(result, default)
}
