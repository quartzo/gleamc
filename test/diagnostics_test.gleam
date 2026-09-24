import gleam/string
import gleamc/pipeline

const source = "import gleam/int\nimport gleam/io\n\nfn f(x: Int) -> Int {\n  x + \"no\"\n}\n\npub fn main() {\n  io.println(int.to_string(f(1)))\n}\n"

pub fn type_error_has_context_test() {
  case pipeline.compile_to_llvm(source) {
    Error(message) -> {
      let has_function = string.contains(message, "in function `f`")
      let has_line = string.contains(message, "at line 4")
      case has_function && has_line {
        True -> Nil
        False -> panic as "missing diagnostic context"
      }
    }
    Ok(_) -> panic as "expected a type error"
  }
}
