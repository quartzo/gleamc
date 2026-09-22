import gleam/string
import gleamc/checker
import gleamc/ir
import gleamc/lower
import gleamc/ownership
import gleamc/parser

fn run(source: String) -> String {
  let assert Ok(module) = parser.parse(source)
  let assert Ok(checked) = checker.check(module)
  let assert Ok(ir_module) =
    lower.lower_module(checked.module, checked.signatures, checked.ctors)
  let with_ownership = ownership.insert(ir_module, checked.ctors)
  ir.to_text(with_ownership)
}

pub fn ownership_drop_unused_test() {
  let text = run("fn f() -> Int {\n  let a = \"hello\"\n  1\n}")
  assert string.contains(text, "drop")
}

pub fn ownership_return_no_drop_test() {
  let text = run("fn id(s: String) -> String { s }")
  assert !string.contains(text, "drop")
}

pub fn ownership_borrow_drops_param_test() {
  let text = run("fn f(s: String) -> Nil {\n  io.println(s)\n}")
  assert string.contains(text, "drop s")
  assert !string.contains(text, "retain")
}

pub fn ownership_dup_retains_test() {
  let text = run("fn dup(s: String) -> #(String, String) { #(s, s) }")
  assert string.contains(text, "retain s")
}

pub fn ownership_move_no_retain_test() {
  let text =
    run("fn pair(a: String, b: String) -> #(String, String) { #(a, b) }")
  assert !string.contains(text, "retain")
  assert !string.contains(text, "drop")
}
