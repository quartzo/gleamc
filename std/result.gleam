import gleam/list

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

pub fn try(result: Result(a, e), with: fn(a) -> Result(b, e)) -> Result(b, e) {
  case result {
    Ok(value) -> with(value)
    Error(reason) -> Error(reason)
  }
}

pub fn then(result: Result(a, e), with: fn(a) -> Result(b, e)) -> Result(b, e) {
  try(result, with)
}

pub fn map_error(result: Result(a, e), with: fn(e) -> f) -> Result(a, f) {
  case result {
    Ok(value) -> Ok(value)
    Error(reason) -> Error(with(reason))
  }
}

pub fn is_ok(result: Result(a, e)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

pub fn is_error(result: Result(a, e)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

pub fn flatten(result: Result(Result(a, e), e)) -> Result(a, e) {
  case result {
    Ok(inner) -> inner
    Error(reason) -> Error(reason)
  }
}

pub fn all(results: List(Result(a, e))) -> Result(List(a), e) {
  all_loop(results, [])
}

fn all_loop(results: List(Result(a, e)), acc: List(a)) -> Result(List(a), e) {
  case results {
    [] -> Ok(list.reverse(acc))
    [result, ..rest] ->
      case result {
        Ok(value) -> all_loop(rest, [value, ..acc])
        Error(reason) -> Error(reason)
      }
  }
}
