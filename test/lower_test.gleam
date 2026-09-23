import gleam/string
import gleamc/checker
import gleamc/ir
import gleamc/lower
import gleamc/parser

fn lower_text(source: String) -> String {
  let assert Ok(module) = parser.parse(source)
  let assert Ok(checked) = checker.check(module)
  let assert Ok(ir_module) =
    lower.lower_module(checked.module, checked.signatures, checked.ctors)
  ir.to_text(ir_module)
}

pub fn lower_fn_test() {
  let text = lower_text("fn id(x: Int) -> Int { x }")
  assert string.contains(text, "fn id")
  assert string.contains(text, "ret x")
}

pub fn lower_binop_test() {
  let text = lower_text("fn add(a: Int, b: Int) -> Int { a + b }")
  assert string.contains(text, "binop +")
}

pub fn lower_case_test() {
  let source =
    "type Maybe {\n  Just(value: Int)\n  None\n}\n\nfn get(m: Maybe) -> Int {\n  case m {\n    Just(v) -> v\n    None -> 0\n  }\n}"
  let text = lower_text(source)
  assert string.contains(text, "tagis")
  assert string.contains(text, "field")
  // The case is in tail position, so its arms return directly (no join).
  assert !string.contains(text, "case_end")
}

pub fn lower_call_test() {
  let text = lower_text("fn f() -> Int { g(1) }\n\nfn g(x: Int) -> Int { x }")
  assert string.contains(text, "call g")
}
