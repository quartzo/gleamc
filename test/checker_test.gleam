import gleamc/checker
import gleamc/parser

fn check(source: String) {
  let assert Ok(module) = parser.parse(source)
  case checker.elaborate(module) {
    Ok(typed) -> checker.check(typed)
    Error(err) -> Error(err)
  }
}

pub fn check_fn_ok_test() {
  let assert Ok(_) = check("fn id(x: Int) -> Int { x }")
}

pub fn check_unknown_variable_test() {
  let assert Error(_) = check("fn f() -> Int { y }")
}

pub fn check_return_mismatch_test() {
  let assert Error(_) = check("fn f() -> Int { \"x\" }")
}

pub fn check_let_inference_test() {
  let assert Ok(_) = check("fn f() -> Int {\n  let x = 1\n  x + 2\n}")
}

pub fn check_let_inference_error_test() {
  let assert Error(_) = check("fn f() -> Int {\n  let x = 1\n  x <> 2\n}")
}

pub fn check_empty_block_is_nil_test() {
  let assert Ok(_) = check("fn f() -> Nil {\n  let x = 1\n}")
}

pub fn check_io_builtin_test() {
  let assert Ok(_) = check("fn f(s: String) -> Nil {\n  io.println(s)\n}")
}

pub fn check_io_builtin_bad_arg_test() {
  let assert Error(_) = check("fn f() -> Nil {\n  io.println(1)\n}")
}

pub fn check_custom_type_case_test() {
  let source =
    "type Maybe {\n  Just(value: Int)\n  None\n}\n\nfn get(m: Maybe) -> Int {\n  case m {\n    Just(v) -> v\n    None -> 0\n  }\n}"
  let assert Ok(_) = check(source)
}

pub fn check_case_arm_mismatch_test() {
  let source =
    "type Maybe {\n  Just(value: Int)\n  None\n}\n\nfn get(m: Maybe) -> Int {\n  case m {\n    Just(v) -> v\n    None -> \"x\"\n  }\n}"
  let assert Error(_) = check(source)
}

pub fn check_bad_pattern_type_test() {
  let assert Error(_) =
    check(
      "fn f(n: Int) -> Int {\n  case n {\n    Just(v) -> v\n    _ -> 0\n  }\n}",
    )
}

pub fn check_binop_float_test() {
  let assert Ok(_) =
    check("fn f(a: Float, b: Float) -> Float { a *. b +. 1.5 }")
}

pub fn check_binop_mixed_error_test() {
  let assert Error(_) = check("fn f(a: Int, b: Float) -> Float { a + b }")
}

pub fn check_tuple_test() {
  let assert Ok(_) = check("fn f() -> #(Int, String) { #(1, \"a\") }")
}

pub fn check_call_arity_error_test() {
  let source = "fn g(a: Int, b: Int) -> Int { a + b }\n\nfn f() -> Int { g(1) }"
  let assert Error(_) = check(source)
}

pub fn check_non_exhaustive_variant_test() {
  let source =
    "type Maybe {\n  Just(value: Int)\n  None\n}\n\nfn get(m: Maybe) -> Int {\n  case m {\n    Just(v) -> v\n  }\n}\n"
  let assert Error(_) = check(source)
}

pub fn check_exhaustive_variant_test() {
  let source =
    "type Maybe {\n  Just(value: Int)\n  None\n}\n\nfn get(m: Maybe) -> Int {\n  case m {\n    Just(v) -> v\n    None -> 0\n  }\n}\n"
  let assert Ok(_) = check(source)
}

pub fn check_non_exhaustive_bool_test() {
  let assert Error(_) =
    check("fn f(b: Bool) -> Int {\n  case b {\n    True -> 1\n  }\n}")
}

pub fn check_exhaustive_bool_test() {
  let assert Ok(_) =
    check(
      "fn f(b: Bool) -> Int {\n  case b {\n    True -> 1\n    False -> 0\n  }\n}",
    )
}

pub fn check_nested_exhaustive_test() {
  let source =
    "type Inner {\n  A\n  B\n}\n\ntype Outer {\n  Wrap(value: Inner)\n}\n\nfn f(o: Outer) -> Int {\n  case o {\n    Wrap(A) -> 1\n    Wrap(B) -> 2\n  }\n}\n"
  let assert Ok(_) = check(source)
}

pub fn check_nested_non_exhaustive_test() {
  let source =
    "type Inner {\n  A\n  B\n}\n\ntype Outer {\n  Wrap(value: Inner)\n}\n\nfn f(o: Outer) -> Int {\n  case o {\n    Wrap(A) -> 1\n  }\n}\n"
  let assert Error(_) = check(source)
}
