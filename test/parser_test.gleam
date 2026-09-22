import gleamc/ast.{
  Arm, CustomType, DCustomType, DFunction, DImport, EBinop, EBlock, ECall, ECase,
  ECtor, EInt, EVar, Function, Import, Module, PCtor, PVar, Stmt, TApp, TBool,
  TInt, TString, TTuple, TVar, Variant,
}
import gleamc/parser

pub fn parse_type_variable_test() {
  let assert Ok(Module([
    DFunction(Function(_, "id", [#("x", TVar("a"))], TVar("a"), _)),
  ])) = parser.parse("fn id(x: a) -> a { x }")
}

pub fn parse_generic_application_test() {
  let assert Ok(Module([
    DFunction(Function(_, "unwrap", [#("x", TApp("Option", [TInt]))], TInt, _)),
  ])) = parser.parse("fn unwrap(x: Option(Int)) -> Int { 1 }")
}

pub fn parse_generic_type_decl_test() {
  let assert Ok(Module([
    DCustomType(CustomType(
      True,
      "Option",
      ["a"],
      [Variant("Some", [#("value", TVar("a"))]), Variant("None", [])],
    )),
  ])) = parser.parse("pub type Option(a) {\n  Some(value: a)\n  None\n}")
}

pub fn parse_multi_param_generic_test() {
  let assert Ok(Module([
    DCustomType(CustomType(
      False,
      "Result",
      ["a", "e"],
      [
        Variant("Ok", [#("value", TVar("a"))]),
        Variant("Error", [#("reason", TVar("e"))]),
      ],
    )),
  ])) =
    parser.parse("type Result(a, e) {\n  Ok(value: a)\n  Error(reason: e)\n}")
}

pub fn parse_simple_fn_test() {
  let assert Ok(Module([
    DFunction(Function(False, "id", [#("x", TInt)], TInt, _)),
  ])) = parser.parse("fn id(x: Int) -> Int { x }")
}

pub fn parse_pub_fn_test() {
  let assert Ok(Module([
    DFunction(Function(True, "add", [#("a", TInt), #("b", TInt)], TInt, _)),
  ])) = parser.parse("pub fn add(a: Int, b: Int) -> Int { a + b }")
}

pub fn parse_precedence_test() {
  let assert Ok(Module([
    DFunction(Function(
      _,
      _,
      _,
      _,
      EBlock([Stmt(EBinop("+", EInt(1), EBinop("*", EInt(2), EInt(3))))]),
    )),
  ])) = parser.parse("fn f() -> Int { 1 + 2 * 3 }")
}

pub fn parse_pipe_desugar_test() {
  let assert Ok(Module([
    DFunction(Function(_, _, _, _, EBlock([Stmt(ECall(EVar("g"), [EInt(1)]))]))),
  ])) = parser.parse("fn f() -> Int { 1 |> g }")
}

pub fn parse_case_test() {
  let assert Ok(Module([DFunction(Function(_, "f", _, _, EBlock([Stmt(_)])))])) =
    parser.parse(
      "fn f(n: Int) -> Int {\n  case n {\n    0 -> 1\n    _ -> n\n  }\n}",
    )
}

pub fn parse_let_block_test() {
  let assert Ok(Module([DFunction(Function(_, _, _, _, EBlock([_, Stmt(_)])))])) =
    parser.parse("fn f() -> Int {\n  let x = 1\n  x\n}")
}

pub fn parse_custom_type_test() {
  let assert Ok(Module([
    DCustomType(CustomType(
      True,
      "Color",
      [],
      [Variant("Red", []), Variant("Green", [])],
    )),
  ])) = parser.parse("pub type Color {\n  Red\n  Green\n}")
}

pub fn parse_custom_type_fields_test() {
  let assert Ok(Module([
    DCustomType(CustomType(
      False,
      "Maybe",
      [],
      [Variant("Just", [#("value", TInt)]), Variant("None", [])],
    )),
  ])) = parser.parse("type Maybe {\n  Just(value: Int)\n  None\n}")
}

pub fn parse_tuple_and_string_test() {
  let assert Ok(Module([
    DFunction(Function(_, _, _, TTuple([TInt, TString]), _)),
  ])) = parser.parse("fn pair() -> #(Int, String) { #(1, \"a\") }")
}

pub fn parse_import_test() {
  let assert Ok(Module([DImport(Import(["gleam", "io"], []))])) =
    parser.parse("import gleam/io")
}

pub fn parse_import_items_test() {
  let assert Ok(Module([DImport(Import(["gleam", "io"], ["println"]))])) =
    parser.parse("import gleam/io.{println}")
}

pub fn parse_bool_type_test() {
  let assert Ok(Module([DFunction(Function(_, _, _, TBool, _))])) =
    parser.parse("fn ok() -> Bool { True }")
}

pub fn parse_list_literal_test() {
  let assert Ok(Module([
    DFunction(Function(
      _,
      "f",
      [],
      _,
      EBlock([
        Stmt(ECtor(
          "ListCons",
          [EInt(1), ECtor("ListCons", [EInt(2), ECtor("ListEmpty", [])])],
        )),
      ]),
    )),
  ])) = parser.parse("fn f() { [1, 2] }")
}

pub fn parse_list_pattern_test() {
  let assert Ok(Module([
    DFunction(Function(
      _,
      "f",
      [#("xs", _)],
      _,
      EBlock([
        Stmt(ECase(
          EVar("xs"),
          [
            Arm(
              PCtor("ListCons", [PVar("a"), PCtor("ListEmpty", [])]),
              _,
              EVar("a"),
            ),
          ],
        )),
      ]),
    )),
  ])) = parser.parse("fn f(xs: List(Int)) { case xs { [a] -> a } }")
}
