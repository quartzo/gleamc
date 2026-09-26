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

pub fn ownership_borrow_no_refcount_test() {
  let text = run("fn f(s: String) -> Nil {\n  io.println(s)\n}")
  assert !string.contains(text, "drop s")
  assert !string.contains(text, "retain")
}

pub fn ownership_borrow_param_owned_on_one_path_test() {
  let text =
    run(
      "fn f(s: String, b: Bool) -> String {\n  case b {\n    True -> s\n    False -> \"x\"\n  }\n}",
    )
  // `s` escapes on the `True` path, so it is owned and must be dropped on the
  // path where it does not.
  assert string.contains(text, "drop s")
}

pub fn ownership_borrow_propagates_no_refcount_test() {
  let text =
    run(
      "fn g(s: String) -> Int {\n  string.length(s)\n}\n\nfn f(s: String) -> Int {\n  let n = g(s)\n  string.length(s) + n\n}",
    )
  assert !string.contains(text, "retain")
  assert !string.contains(text, "drop")
}

pub fn ownership_dup_retains_test() {
  let text = run("fn dup(s: String) -> #(String, String) { #(s, s) }")
  assert string.contains(text, "retain s")
}

/// A builtin declared `Owned` (string.uppercase) consumes its argument: when
/// the caller still needs the value afterwards, it must be retained first.
pub fn ownership_ffi_owned_retains_test() {
  let text =
    run(
      "fn f(s: String) -> String {\n  let u = string.uppercase(s)\n  s <> u\n}",
    )
  assert string.contains(text, "retain s")
}

pub fn ownership_move_no_retain_test() {
  let text =
    run("fn pair(a: String, b: String) -> #(String, String) { #(a, b) }")
  assert !string.contains(text, "retain")
  assert !string.contains(text, "drop")
}

/// A fully-destructured parameter is consumed, so its owned fields are moved
/// out (no retain) and the container is not dropped.
pub fn ownership_param_field_move_no_retain_test() {
  let text =
    run(
      "type Box { Box(s: String, n: Int) }\n\nfn unbox(b: Box) -> String { b.s }",
    )
  assert !string.contains(text, "retain")
  assert !string.contains(text, "drop")
}

/// A field read by two owning extractions must not be moved (both dests would
/// alias the container's single reference); fall back to retain + drop.
pub fn ownership_repeated_field_retains_test() {
  let text =
    run(
      "type Box { Box(s: String, n: Int) }\n\nfn dup(b: Box) -> #(String, String) { #(b.s, b.s) }",
    )
  assert string.contains(text, "retain")
  assert string.contains(text, "drop")
}
