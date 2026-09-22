//// Type alias expansion: replaces `type Name(a) = ...` aliases with the
//// underlying type wherever they appear, then drops the alias declarations.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleamc/ast.{
  type Definition, type Module, type Type, CustomType, DCustomType, DFunction,
  DImport, DTypeAlias, Function, Module, TApp, TBool, TFloat, TFun, TInt, TNamed,
  TNil, TString, TTuple, TVar, Variant,
}

pub fn expand(module: Module) -> Result(Module, String) {
  let Module(definitions) = module
  let aliases = collect_aliases(definitions)
  let kept =
    list.filter(definitions, fn(definition) {
      case definition {
        DTypeAlias(_, _, _, _) -> False
        _ -> True
      }
    })
  use definitions <- result.try(
    list.try_map(kept, fn(definition) { expand_definition(definition, aliases) }),
  )
  Ok(Module(definitions))
}

fn collect_aliases(definitions) -> Dict(String, #(List(String), Type)) {
  list.fold(definitions, dict.new(), fn(acc, definition) {
    case definition {
      DTypeAlias(_, name, generics, ty) ->
        dict.insert(acc, name, #(generics, ty))
      _ -> acc
    }
  })
}

fn expand_definition(definition, aliases) -> Result(Definition, String) {
  case definition {
    DTypeAlias(_, _, _, _) -> Ok(definition)
    DFunction(function) -> {
      let Function(is_pub, name, params, ret, body, line) = function
      use params <- result.try(
        list.try_map(params, fn(param) {
          let #(param_name, ty) = param
          use ty <- result.try(expand_type(ty, aliases, []))
          Ok(#(param_name, ty))
        }),
      )
      use ret <- result.try(expand_type(ret, aliases, []))
      Ok(DFunction(Function(is_pub, name, params, ret, body, line)))
    }
    DCustomType(custom) -> {
      let CustomType(is_pub, name, generics, variants, is_opaque) = custom
      use variants <- result.try(
        list.try_map(variants, fn(variant) {
          let Variant(variant_name, fields) = variant
          use fields <- result.try(
            list.try_map(fields, fn(field) {
              let #(field_name, ty) = field
              use ty <- result.try(expand_type(ty, aliases, []))
              Ok(#(field_name, ty))
            }),
          )
          Ok(Variant(variant_name, fields))
        }),
      )
      Ok(DCustomType(CustomType(is_pub, name, generics, variants, is_opaque)))
    }
    DImport(_) -> Ok(definition)
  }
}

fn expand_type(ty, aliases, visited) -> Result(Type, String) {
  case ty {
    TInt | TFloat | TBool | TString | TNil | TVar(_) -> Ok(ty)
    TNamed(name) ->
      case dict.get(aliases, name) {
        Ok(#(generics, body)) ->
          case generics {
            [] -> expand_alias(name, [], [], body, aliases, visited)
            _ -> Ok(ty)
          }
        Error(_) -> Ok(ty)
      }
    TApp(name, args) -> {
      use args2 <- result.try(
        list.try_map(args, fn(arg) { expand_type(arg, aliases, visited) }),
      )
      case dict.get(aliases, name) {
        Ok(#(generics, body)) ->
          case list.length(generics) == list.length(args2) {
            True -> expand_alias(name, generics, args2, body, aliases, visited)
            False ->
              Error(
                "type alias `"
                <> name
                <> "` expects "
                <> int.to_string(list.length(generics))
                <> " argument(s), found "
                <> int.to_string(list.length(args2)),
              )
          }
        Error(_) -> Ok(TApp(name, args2))
      }
    }
    TTuple(items) -> {
      use items2 <- result.try(
        list.try_map(items, fn(item) { expand_type(item, aliases, visited) }),
      )
      Ok(TTuple(items2))
    }
    TFun(params, ret) -> {
      use params2 <- result.try(
        list.try_map(params, fn(param) { expand_type(param, aliases, visited) }),
      )
      use ret2 <- result.try(expand_type(ret, aliases, visited))
      Ok(TFun(params2, ret2))
    }
  }
}

fn expand_alias(
  name,
  generics,
  args,
  body,
  aliases,
  visited,
) -> Result(Type, String) {
  case list.contains(visited, name) {
    True -> Error("recursive type alias `" <> name <> "`")
    False ->
      expand_type(substitute(list.zip(generics, args), body), aliases, [
        name,
        ..visited
      ])
  }
}

fn substitute(mapping, ty) -> Type {
  case ty {
    TVar(name) ->
      case
        list.find(mapping, fn(pair) {
          let #(generic, _) = pair
          generic == name
        })
      {
        Ok(pair) -> {
          let #(_, replacement) = pair
          replacement
        }
        Error(_) -> ty
      }
    TNamed(_) | TInt | TFloat | TBool | TString | TNil -> ty
    TApp(name, args) ->
      TApp(name, list.map(args, fn(arg) { substitute(mapping, arg) }))
    TTuple(items) ->
      TTuple(list.map(items, fn(item) { substitute(mapping, item) }))
    TFun(params, ret) ->
      TFun(
        list.map(params, fn(param) { substitute(mapping, param) }),
        substitute(mapping, ret),
      )
  }
}
