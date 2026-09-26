import gleam/list
import gleamc/ast.{CustomType}
import gleamc/mono
import gleamc/parser
import gleamc/tmono

fn definition_names(module: tmono.TModule) -> List(String) {
  let tmono.TModule(definitions) = module
  list.filter_map(definitions, fn(definition) {
    case definition {
      tmono.TDFunction(function) -> Ok(function.name)
      tmono.TDCustomType(custom) -> {
        let CustomType(_, name, _, _, _) = custom
        Ok(name)
      }
      _ -> Error(Nil)
    }
  })
}

fn monomorphize(source: String) -> tmono.TModule {
  let assert Ok(module) = parser.parse(source)
  let assert Ok(mono_module) = mono.monomorphize(module)
  mono_module
}

pub fn generic_function_specialisation_test() {
  let mono_module =
    monomorphize(
      "fn id(x: a) -> a { x }\n\npub fn main() {\n  io.println(id(\"hi\"))\n  io.println(int.to_string(id(1)))\n}\n",
    )
  let names = definition_names(mono_module)
  assert list.contains(names, "id_String")
  assert list.contains(names, "id_Int")
  assert list.contains(names, "main")
}

pub fn generic_type_specialisation_test() {
  let mono_module =
    monomorphize(
      "type Option(a) {\n  Some(value: a)\n  None\n}\n\nfn get(o: Option(Int)) -> Int {\n  case o {\n    Some(v) -> v\n    None -> 0\n  }\n}\n\npub fn main() {\n  io.println(int.to_string(get(Some(1))))\n}\n",
    )
  let names = definition_names(mono_module)
  assert list.contains(names, "Option_Int")
  assert list.contains(names, "get")
}

pub fn two_instantiations_test() {
  let mono_module =
    monomorphize(
      "type Box(a) {\n  Box(value: a)\n}\n\npub fn main() {\n  let a = Box(1)\n  let b = Box(\"x\")\n}\n",
    )
  let names = definition_names(mono_module)
  assert list.contains(names, "Box_Int")
  assert list.contains(names, "Box_String")
}

pub fn dependency_order_test() {
  let mono_module =
    monomorphize(
      "type MaybeInt {\n  Just(value: Int)\n  Nothing\n}\n\ntype Wrapper {\n  Wrap(value: MaybeInt)\n}\n\npub fn main() {\n  let w = Wrap(Just(1))\n}\n",
    )
  let names = definition_names(mono_module)
  assert names == ["MaybeInt", "Wrapper", "main"]
}
