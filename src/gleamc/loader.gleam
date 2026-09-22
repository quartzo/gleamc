//// Module loader: starting from an entry file, resolves `import` paths to
//// sibling `.gleam` files. Imports that do not resolve to a local file are
//// treated as builtins (e.g. `gleam/io`) and ignored.

import gleam/dict
import gleam/list
import gleam/string
import gleamc/ast.{type Module, DImport, Import, Module}
import gleamc/ffi
import gleamc/parser

/// Returns the modules to compile, entry first (name ""), each imported
/// module keyed by its import alias (last path segment).
pub fn load(entry_path: String) -> Result(List(#(String, Module)), String) {
  case ffi.read_file(entry_path) {
    Error(err) -> Error("error reading " <> entry_path <> ": " <> err)
    Ok(source) ->
      case parser.parse(source) {
        Error(err) -> Error(parser.describe_error(err))
        Ok(entry) -> {
          let root = directory_of(entry_path)
          case
            load_imports(root, imports_of(entry), dict.new(), [#("", entry)])
          {
            Error(err) -> Error(err)
            Ok(modules) -> attach_prelude(root, modules)
          }
        }
      }
  }
}

/// The implicit prelude: `gleam/result` and `gleam/list` are always available
/// (types and constructors) without an explicit import. Their own imports are
/// resolved too, so a prelude module may depend on another prelude module.
fn attach_prelude(root, modules) -> Result(List(#(String, Module)), String) {
  load_prelude(root, ["result", "list"], modules)
}

fn load_prelude(root, names, acc) -> Result(List(#(String, Module)), String) {
  case names {
    [] -> Ok(acc)
    [name, ..rest] ->
      case prelude_present(acc, name) {
        True -> load_prelude(root, rest, acc)
        False ->
          case ffi.read_file("std/" <> name <> ".gleam") {
            Error(_) -> load_prelude(root, rest, acc)
            Ok(source) ->
              case parser.parse(source) {
                Error(err) -> Error(parser.describe_error(err))
                Ok(module) ->
                  case
                    load_deps(
                      root,
                      imports_of(module),
                      dict.from_list([#(name, True)]),
                      [#(name, module), ..acc],
                    )
                  {
                    Error(err) -> Error(err)
                    Ok(acc2) -> load_prelude(root, rest, acc2)
                  }
              }
          }
      }
  }
}

fn prelude_present(modules, name) -> Bool {
  list.any(modules, fn(entry) {
    let #(alias, _) = entry
    alias == name
  })
}

/// Like `load_imports`, but prepends to the accumulated list without reversing
/// (the prelude is added on top of the already ordered user modules).
fn load_deps(
  root,
  imports,
  visited,
  acc,
) -> Result(List(#(String, Module)), String) {
  case imports {
    [] -> Ok(acc)
    [import_decl, ..rest] -> {
      let Import(path, _) = import_decl
      let key = string.join(path, "/")
      case dict.get(visited, key) {
        Ok(_) -> load_deps(root, rest, visited, acc)
        Error(_) -> {
          let visited = dict.insert(visited, key, True)
          case read_module(root, key) {
            Error(_) -> load_deps(root, rest, visited, acc)
            Ok(source) ->
              case parser.parse(source) {
                Error(err) -> Error(parser.describe_error(err))
                Ok(module) -> {
                  let alias = last_segment(path)
                  load_deps(
                    root,
                    list.append(rest, imports_of(module)),
                    visited,
                    [#(alias, module), ..acc],
                  )
                }
              }
          }
        }
      }
    }
  }
}

fn load_imports(
  root,
  imports,
  visited,
  acc,
) -> Result(List(#(String, Module)), String) {
  case imports {
    [] -> Ok(list.reverse(acc))
    [import_decl, ..rest] -> {
      let Import(path, _) = import_decl
      let key = string.join(path, "/")
      case dict.get(visited, key) {
        Ok(_) -> load_imports(root, rest, visited, acc)
        Error(_) -> {
          let visited = dict.insert(visited, key, True)
          case read_module(root, key) {
            Error(_) -> load_imports(root, rest, visited, acc)
            Ok(source) ->
              case parser.parse(source) {
                Error(err) -> Error(parser.describe_error(err))
                Ok(module) -> {
                  let alias = last_segment(path)
                  load_imports(
                    root,
                    list.append(rest, imports_of(module)),
                    visited,
                    [#(alias, module), ..acc],
                  )
                }
              }
          }
        }
      }
    }
  }
}

fn imports_of(module) {
  let Module(definitions) = module
  list.filter_map(definitions, fn(definition) {
    case definition {
      DImport(decl) -> Ok(decl)
      _ -> Error(Nil)
    }
  })
}

/// Looks for `<root>/<path>.gleam`, then `<cwd>/std/<path>.gleam`, mapping
/// `gleam/<name>` to `std/<name>.gleam`.
fn read_module(root, key) -> Result(String, Nil) {
  case ffi.read_file(root <> "/" <> key <> ".gleam") {
    Ok(source) -> Ok(source)
    Error(_) -> read_std(key)
  }
}

fn read_std(key) -> Result(String, Nil) {
  case ffi.read_file("std/" <> key <> ".gleam") {
    Ok(source) -> Ok(source)
    Error(_) ->
      case string.split(key, "/") {
        ["gleam", name] ->
          case ffi.read_file("std/" <> name <> ".gleam") {
            Ok(source) -> Ok(source)
            Error(_) -> Error(Nil)
          }
        _ -> Error(Nil)
      }
  }
}

fn last_segment(path) {
  case list.reverse(path) {
    [last, ..] -> last
    [] -> ""
  }
}

fn directory_of(path) -> String {
  case list.reverse(string.split(path, "/")) {
    [_file, ..rest] ->
      case list.reverse(rest) {
        [] -> "."
        directories -> string.join(directories, "/")
      }
    [] -> "."
  }
}
