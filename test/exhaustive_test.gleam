import gleam/string
import gleamc/pipeline

const non_exhaustive = "import gleam/int\nimport gleam/io\n\nfn f(a: Int, b: Int) -> Int {\n  case a, b {\n    0, 0 -> 1\n    0, _ -> 2\n  }\n}\n\npub fn main() {\n  io.println(int.to_string(f(1, 2)))\n}\n"

fn expect_error(result) {
  case result {
    Error(message) ->
      case string.contains(message, "non-exhaustive") {
        True -> Nil
        False -> panic as "unexpected error message"
      }
    Ok(_) -> panic as "expected a non-exhaustive `case` error"
  }
}

pub fn tuple_non_exhaustive_test() {
  expect_error(pipeline.compile_to_c(non_exhaustive))
}
