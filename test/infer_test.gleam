import gleamc/infer
import gleamc/merge
import gleamc/parser
import gleamc/pipeline

fn check(source: String) {
  let assert Ok(module) = parser.parse(source)
  infer.check(module)
}

pub fn generic_identity_test() {
  let assert Ok(_) = check("fn id(x: a) -> a { x }")
}

pub fn rigid_parameter_rejected_test() {
  // `a` is a declared parameter: it cannot become Int
  let assert Error(_) = check("fn f(x: a) -> Int { x }")
}

pub fn generic_type_use_test() {
  let source =
    "type Option(a) {\n  Some(value: a)\n  None\n}\n\nfn get(o: Option(Int)) -> Int {\n  case o {\n    Some(v) -> v\n    None -> 0\n  }\n}\n"
  let assert Ok(_) = check(source)
}

pub fn generic_constructor_inference_test() {
  let source =
    "type Option(a) {\n  Some(value: a)\n  None\n}\n\npub fn main() {\n  let x = Some(1)\n  io.println(int.to_string(x.value))\n}\n"
  let assert Ok(_) = check(source)
}

pub fn generic_cross_type_use_test() {
  let source =
    "fn id(x: a) -> a { x }\n\npub fn main() {\n  io.println(id(\"hi\"))\n  io.println(int.to_string(id(1)))\n}\n"
  let assert Ok(_) = check(source)
}

pub fn generic_arity_mismatch_test() {
  let source =
    "type Result(a, e) {\n  Ok(value: a)\n  Error(reason: e)\n}\n\npub fn main() {\n  let x = Ok(1)\n  io.println(int.to_string(x.value))\n}\n"
  let assert Ok(_) = check(source)
}

pub fn generic_tuple_polymorphism_test() {
  let source =
    "fn first(pair: #(a, b)) -> a {\n  case pair {\n    #(x, _) -> x\n  }\n}\n\npub fn main() {\n  io.println(first(#(1, \"a\")))\n}\n"
  // first returns an Int, but main prints it via io.println (String) -> error
  let assert Error(_) = check(source)
}

pub fn generic_first_inferred_test() {
  let source =
    "fn first(pair: #(a, b)) -> a {\n  case pair {\n    #(x, _) -> x\n  }\n}\n\npub fn main() {\n  io.println(int.to_string(first(#(1, \"a\"))))\n}\n"
  let assert Ok(_) = check(source)
}

pub fn wrong_instantiation_test() {
  let source =
    "type Option(a) {\n  Some(value: a)\n  None\n}\n\nfn want_string(o: Option(String)) -> String {\n  case o {\n    Some(v) -> v\n    None -> \"\"\n  }\n}\n\npub fn main() {\n  want_string(Some(1))\n}\n"
  let assert Error(_) = check(source)
}

pub fn generic_two_param_case_test() {
  let source =
    "type Wrapped(a) {\n  Wrapped(value: a)\n  Empty\n}\n\nfn unwrap(w: Wrapped(a), default: a) -> a {\n  case w {\n    Wrapped(v) -> v\n    Empty -> default\n  }\n}\n\npub fn main() {\n  io.println(unwrap(Wrapped(\"hi\"), \"none\"))\n  io.println(int.to_string(unwrap(Wrapped(7), 0)))\n}\n"
  let assert Ok(_) = check(source)
}

pub fn merged_generic_test() {
  let source =
    "type Wrapped(a) {\n  Wrapped(value: a)\n  Empty\n}\n\nfn unwrap(w: Wrapped(a), default: a) -> a {\n  case w {\n    Wrapped(v) -> v\n    Empty -> default\n  }\n}\n\npub fn main() {\n  io.println(unwrap(Wrapped(\"hi\"), \"none\"))\n  io.println(int.to_string(unwrap(Wrapped(7), 0)))\n}\n"
  let assert Ok(module) = parser.parse(source)
  let assert Ok(merged) = merge.merge([#("", module)])
  let assert Ok(_) = infer.check(merged)
}

pub fn duplicate_constructor_test() {
  let source =
    "type A {\n  Empty\n}\n\ntype B {\n  Empty\n}\n\npub fn main() { Nil }"
  let assert Error(_) = pipeline.compile_to_llvm(source)
}
