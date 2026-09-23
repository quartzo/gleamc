import gleam/string
import gleamc/pipeline
import gleamc/plan

const mutual = "fn even(n: Int) -> Bool {
  case n {
    0 -> True
    _ -> odd(n - 1)
  }
}

fn odd(n: Int) -> Bool {
  case n {
    0 -> False
    _ -> even(n - 1)
  }
}

pub fn main() {
  even(4)
}
"

const self_rec = "fn count(n: Int, acc: Int) -> Int {
  case n {
    0 -> acc
    _ -> count(n - 1, acc + 1)
  }
}

pub fn main() {
  count(4, 0)
}
"

pub fn plan_mutual_group_test() {
  let assert Ok(planned) = pipeline.compile_to_plan(mutual)
  let text = plan.to_text(planned)
  assert string.contains(text, "groups:")
  assert string.contains(text, "[even, odd]")
  assert string.contains(text, "even -> odd")
  assert string.contains(text, "odd -> even")
}

pub fn plan_self_not_grouped_test() {
  let assert Ok(planned) = pipeline.compile_to_plan(self_rec)
  let text = plan.to_text(planned)
  assert string.contains(text, "count -> count")
  // A self recursion is not a mutual group (handled by the self-tail path).
  assert !string.contains(text, "[count, count]")
}

pub fn plan_deterministic_test() {
  let assert Ok(a) = pipeline.compile_to_plan(mutual)
  let assert Ok(b) = pipeline.compile_to_plan(mutual)
  assert plan.to_text(a) == plan.to_text(b)
}

const string_mutual = "fn ping(s: String, n: Int) -> Int {
  case n {
    0 -> 1
    _ -> pong(s, n - 1)
  }
}

fn pong(s: String, n: Int) -> Int {
  case n {
    0 -> 2
    _ -> ping(s, n - 1)
  }
}

pub fn main() {
  ping(\"x\", 3)
}
"

pub fn plan_string_mutual_test() {
  let assert Ok(planned) = pipeline.compile_to_plan(string_mutual)
  let text = plan.to_text(planned)
  assert string.contains(text, "[ping, pong]")
}

const string_mutual2 = "fn ping(s: String, n: Int) -> Int {
  case n { 0 -> 1 _ -> pong(s, n - 1) }
}
fn pong(s: String, n: Int) -> Int {
  case n { 0 -> 2 _ -> ping(s, n - 1) }
}
pub fn main() { ping(\"x\", 3) }
"

pub fn llvm_group_emit_test() {
  let assert Ok(code) = pipeline.compile_to_llvm(string_mutual2)
  assert string.contains(code, "__g_ping_pong")
  assert string.contains(code, "@__g_ping_pong")
}

pub fn plan_string_mutual2_test() {
  let assert Ok(p) = pipeline.compile_to_plan(string_mutual2)
  assert string.contains(plan.to_text(p), "[ping, pong]")
  assert string.contains(plan.to_text(p), "ping -> pong")
}
