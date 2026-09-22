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

pub fn lazy_unwrap(result: Result(a, e), default: fn() -> a) -> a {
  case result {
    Ok(value) -> value
    Error(_) -> default()
  }
}

pub fn unwrap_error(result: Result(a, e), default: e) -> e {
  case result {
    Ok(_) -> default
    Error(reason) -> reason
  }
}

pub fn or(first: Result(a, e), second: Result(a, e)) -> Result(a, e) {
  case first {
    Ok(_) -> first
    Error(_) -> second
  }
}

pub fn replace(result: Result(a, e), value: b) -> Result(b, e) {
  case result {
    Ok(_) -> Ok(value)
    Error(reason) -> Error(reason)
  }
}

pub fn replace_error(result: Result(a, e), error: f) -> Result(a, f) {
  case result {
    Ok(value) -> Ok(value)
    Error(_) -> Error(error)
  }
}

pub fn values(results: List(Result(a, e))) -> List(a) {
  values_loop(results, [])
}

fn values_loop(results: List(Result(a, e)), acc: List(a)) -> List(a) {
  case results {
    [] -> list.reverse(acc)
    [result, ..rest] ->
      case result {
        Ok(value) -> values_loop(rest, [value, ..acc])
        Error(_) -> values_loop(rest, acc)
      }
  }
}

pub fn partition(results: List(Result(a, e))) -> #(List(a), List(e)) {
  partition_loop(results, [], [])
}

fn partition_loop(
  results: List(Result(a, e)),
  oks: List(a),
  errors: List(e),
) -> #(List(a), List(e)) {
  case results {
    [] -> #(oks, errors)
    [result, ..rest] ->
      case result {
        Ok(value) -> partition_loop(rest, [value, ..oks], errors)
        Error(reason) -> partition_loop(rest, oks, [reason, ..errors])
      }
  }
}
