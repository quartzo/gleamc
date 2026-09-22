//// C code generator (M4/M5): Core IR -> C11.
////
//// Consumes the IR after the ownership pass. Every `OpRetain`/`OpDrop` is
//// emitted as a runtime retain/release macro (String) or a generated glue
//// function (custom types / tuples that contain handles).

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/string
import gleamc/ast.{
  type CustomType, type Type, CustomType, TNamed, TString, TTuple, Variant,
}
import gleamc/checker
import gleamc/ir
import gleamc/ownership

// ---------------------------------------------------------------------------
// entry point
// ---------------------------------------------------------------------------

pub fn emit(
  ir_module: ir.Module,
  custom_types: List(CustomType),
  ctors: Dict(String, checker.CtorInfo),
) -> String {
  let ir.Module(functions) = ir_module
  let recursive = ownership.recursive_types(ctors)
  let tuple_types = collect_tuple_types(functions, custom_types)
  let glue_types = collect_glue_types(functions, custom_types, ctors)

  let preamble = "#include \"gleam_runtime.h\"\n\n"

  let string_lits = collect_string_literals(functions)
  let fn_types = collect_fn_types(functions)
  let env_structs = collect_env_structs(functions)
  let value_wrappers = collect_value_wrappers(functions, recursive)

  let forward_decls =
    string.join(
      list.map(
        list.filter(custom_types, fn(custom) {
          let CustomType(_, name, _, _) = custom
          is_recursive(recursive, name)
        }),
        fn(custom) {
          let CustomType(_, name, _, _) = custom
          "typedef struct " <> name <> " " <> name <> ";\n"
        },
      ),
      "",
    )

  let type_code =
    forward_decls
    <> string.join(
      list.map(tuple_types, fn(ty) { emit_tuple_type(ty, recursive) }),
      "",
    )
    <> "\n"
    <> string.join(
      list.map(custom_types, fn(custom) { emit_custom_type(custom, recursive) }),
      "\n",
    )
    <> "\n"
    <> string.join(
      list.map(env_structs, fn(entry) { emit_env_struct(entry, recursive) }),
      "",
    )
    <> string.join(
      list.map(fn_types, fn(ty) { emit_fn_type(ty, recursive) }),
      "",
    )
    <> "\n"
    <> emit_string_literals(string_lits)

  let glue_prototypes =
    string.join(
      list.flat_map(glue_types, fn(ty) {
        [
          glue_prototype("retain", ty, recursive),
          glue_prototype("drop", ty, recursive),
        ]
      }),
      "",
    )

  let glue_definitions =
    string.join(
      list.flat_map(glue_types, fn(ty) {
        [
          glue_definition("retain", ty, recursive, ctors),
          glue_definition("drop", ty, recursive, ctors),
        ]
      }),
      "\n",
    )

  let prototypes =
    string.join(
      list.map(functions, fn(function) { emit_prototype(function, recursive) }),
      "",
    )
  let definitions =
    string.join(
      list.map(functions, fn(function) { emit_function(function, recursive) }),
      "\n",
    )

  let has_main = list.any(functions, fn(function) { function.name == "main" })
  let main_code = case has_main {
    True -> "int main(void) {\n    Gleamc_main();\n    return 0;\n}\n"
    False -> ""
  }

  preamble
  <> type_code
  <> glue_prototypes
  <> "\n"
  <> glue_definitions
  <> prototypes
  <> string.join(value_wrappers, "")
  <> definitions
  <> main_code
}

// ---------------------------------------------------------------------------
// type mapping
// ---------------------------------------------------------------------------

const c_keywords = [
  "auto", "break", "case", "char", "const", "continue", "default", "do",
  "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline",
  "int", "long", "register", "restrict", "return", "short", "signed", "sizeof",
  "static", "struct", "switch", "typedef", "union", "unsigned", "void",
  "volatile", "while", "bool", "true", "false", "NULL",
]

/// Appends `_` to identifiers that clash with C keywords.
pub fn c_safe(name: String) -> String {
  case list.contains(c_keywords, name) {
    True -> name <> "_"
    False -> name
  }
}

pub fn is_recursive(recursive: Dict(String, Bool), name: String) -> Bool {
  case dict.get(recursive, name) {
    Ok(True) -> True
    _ -> False
  }
}

pub fn type_key(ty: Type) -> String {
  case ty {
    TString -> "str"
    ast.TInt -> "i64"
    ast.TFloat -> "f64"
    ast.TBool -> "b"
    ast.TNil -> "nil"
    ast.TVar(name) -> name
    TNamed(name) -> name
    ast.TApp(name, args) ->
      name <> "_" <> string.join(list.map(args, type_key), "_")
    TTuple(types) -> "t" <> string.join(list.map(types, type_key), "_")
    ast.TFun(params, ret) ->
      "fn_"
      <> string.join(list.map(params, type_key), "_")
      <> "_"
      <> type_key(ret)
  }
}

pub fn c_type(ty: Type, recursive: Dict(String, Bool)) -> String {
  case ty {
    ast.TInt -> "int64_t"
    ast.TFloat -> "double"
    ast.TBool -> "bool"
    TString -> "GleamcString"
    ast.TNil -> "int"
    ast.TVar(name) -> name
    TNamed(name) ->
      case is_recursive(recursive, name) {
        True -> name <> "*"
        False -> name
      }
    ast.TApp(name, args) ->
      name <> "_" <> string.join(list.map(args, mangle_type), "_")
    TTuple(types) ->
      "GleamcTuple_" <> string.join(list.map(types, mangle_type), "_")
    ast.TFun(_, _) -> "GleamFn_" <> mangle_type(ty)
  }
}

fn mangle_type(ty: Type) -> String {
  case ty {
    ast.TInt -> "i64"
    ast.TFloat -> "f64"
    ast.TBool -> "b"
    TString -> "str"
    ast.TNil -> "nil"
    ast.TVar(name) -> name
    TNamed(name) -> name
    ast.TApp(name, args) ->
      name <> "_" <> string.join(list.map(args, mangle_type), "_")
    TTuple(types) -> "t" <> string.join(list.map(types, mangle_type), "_")
    ast.TFun(params, ret) ->
      "fn_"
      <> string.join(list.map(params, mangle_type), "_")
      <> "_"
      <> mangle_type(ret)
  }
}

fn float_literal(value: Float) -> String {
  let text = float.to_string(value)
  case string.contains(text, ".") {
    True -> text
    False -> text <> ".0"
  }
}

fn c_escape(value: String) -> String {
  value
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\t", "\\t")
  |> string.replace("\r", "\\r")
}

// ---------------------------------------------------------------------------
// type declarations
// ---------------------------------------------------------------------------

fn collect_fn_types(functions) -> List(Type) {
  let types =
    list.flat_map(functions, fn(function) {
      let ir.Function(_, _, ret, blocks, locals) = function
      let from_locals =
        list.map(locals, fn(local) {
          let ir.Local(_, ty) = local
          ty
        })
      let from_ops =
        list.flat_map(blocks, fn(block) {
          let ir.Block(_, ops, _) = block
          list.flat_map(ops, op_types)
        })
      [ret, ..list.append(from_locals, from_ops)]
    })
  types
  |> list.flat_map(fn_types_in)
  |> dedupe_types
}

fn fn_types_in(ty: Type) -> List(Type) {
  case ty {
    ast.TFun(params, ret) -> [
      ty,
      ..list.append(list.flat_map(params, fn_types_in), fn_types_in(ret))
    ]
    ast.TTuple(items) -> list.flat_map(items, fn_types_in)
    _ -> []
  }
}

fn emit_fn_type(ty, recursive) -> String {
  case ty {
    ast.TFun(params, ret) -> {
      let args = case params {
        [] -> "void*"
        _ ->
          "void*, "
          <> string.join(list.map(params, fn(p) { c_type(p, recursive) }), ", ")
      }
      "typedef struct {\n"
      <> "    "
      <> c_type(ret, recursive)
      <> " (*code)("
      <> args
      <> ");\n"
      <> "    void* env;\n"
      <> "    void (*env_drop)(void*);\n"
      <> "} GleamFn_"
      <> mangle_type(ty)
      <> ";\n"
    }
    _ -> ""
  }
}

fn collect_env_structs(functions) -> List(#(String, List(Type))) {
  list.fold(functions, [], fn(acc, function) {
    let by_name = locals_map(local_list(function))
    list.fold(op_list(function), acc, fn(acc, op) {
      case op {
        ir.OpClosure(_, _, captures, env_ty, _) ->
          case env_ty {
            "" -> acc
            _ ->
              case
                list.any(acc, fn(entry) {
                  let #(name, _) = entry
                  name == env_ty
                })
              {
                True -> acc
                False ->
                  list.append(acc, [
                    #(
                      env_ty,
                      list.map(captures, fn(cap) { operand_type(by_name, cap) }),
                    ),
                  ])
              }
          }
        _ -> acc
      }
    })
  })
}

fn local_list(function) {
  let ir.Function(_, _, _, _, locals) = function
  locals
}

fn op_list(function) {
  let ir.Function(_, _, _, blocks, _) = function
  list.flat_map(blocks, fn(block) {
    let ir.Block(_, ops, _) = block
    ops
  })
}

fn emit_env_struct(entry, recursive) -> String {
  let #(name, field_types) = entry
  let fields =
    list.index_map(field_types, fn(ty, index) {
      "    " <> c_type(ty, recursive) <> " _" <> int.to_string(index) <> ";"
    })
  let drops =
    string.join(
      list.filter_map(
        list.index_map(field_types, fn(ty, index) { #(ty, index) }),
        fn(pair) {
          let #(ty, index) = pair
          case ownership.needs_drop(ty, dict.new()) || is_handle_type(ty) {
            True ->
              Ok(
                "        "
                <> glue_call("drop", ty, "v->_" <> int.to_string(index))
                <> ";",
              )
            False -> Error(Nil)
          }
        },
      ),
      "\n",
    )
  "typedef struct {\n"
  <> string.join(fields, "\n")
  <> "\n} "
  <> name
  <> ";\n"
  <> "static void "
  <> name
  <> "_drop(void* p) {\n    "
  <> name
  <> "* v = ("
  <> name
  <> "*)p;\n"
  <> "    if (v == NULL) return;\n"
  <> "    if (((GleamcHdr*)((uint8_t*)v - sizeof(GleamcHdr)))->refcount == 1) {\n"
  <> drops
  <> "\n    }\n    gleamc_release(v);\n}\n"
}

/// Types whose glue needs `needs_drop` from the real ctor registry; this is a
/// best-effort structural check used for the environment fields.
fn is_handle_type(ty) -> Bool {
  case ty {
    TString -> True
    TNamed(_) -> True
    ast.TApp(_, _) -> True
    TTuple(items) -> list.any(items, is_handle_type)
    _ -> False
  }
}

fn collect_value_wrappers(functions, recursive) -> List(String) {
  let by_name =
    list.fold(functions, dict.new(), fn(acc, f) {
      let ir.Function(name, _, _, _, _) = f
      dict.insert(acc, name, f)
    })
  let codes =
    list.flat_map(functions, fn(function) {
      list.filter_map(op_list(function), fn(op) {
        case op {
          ir.OpClosure(_, code, _, "", _) -> Ok(code)
          _ -> Error(Nil)
        }
      })
    })
  dedupe_strings(codes)
  |> list.filter_map(fn(code) {
    case string.starts_with(code, "__gv_") {
      True -> Ok(code)
      False -> Error(Nil)
    }
  })
  |> list.map(fn(code) {
    let name = string.slice(code, 5, string.length(code))
    case dict.get(by_name, name) {
      Ok(function) -> wrapper_for(function, code, recursive)
      Error(_) -> ""
    }
  })
}

fn dedupe_strings(items) {
  list.fold(items, [], fn(acc, item) {
    case list.contains(acc, item) {
      True -> acc
      False -> list.append(acc, [item])
    }
  })
}

fn wrapper_for(function, code, recursive) -> String {
  let ir.Function(name, params, ret, _, locals) = function
  let by_name = locals_map(locals)
  let decls =
    list.index_map(params, fn(param, index) {
      c_type(local_type(by_name, param), recursive)
      <> " a"
      <> int.to_string(index)
    })
  let args =
    string.join(
      list.index_map(params, fn(_, index) { "a" <> int.to_string(index) }),
      ", ",
    )
  c_type(ret, recursive)
  <> " "
  <> code
  <> "(void* __env, "
  <> string.join(decls, ", ")
  <> ") {\n    (void)__env;\n    return Gleamc_"
  <> name
  <> "("
  <> args
  <> ");\n}\n"
}

fn collect_tuple_types(
  functions: List(ir.Function),
  custom_types: List(CustomType),
) -> List(Type) {
  let types =
    list.flat_map(functions, fn(function) {
      let ir.Function(_, _, ret, blocks, locals) = function
      let from_locals =
        list.map(locals, fn(local) {
          let ir.Local(_, ty) = local
          ty
        })
      let from_ops =
        list.flat_map(blocks, fn(block) {
          let ir.Block(_, ops, _) = block
          list.flat_map(ops, op_types)
        })
      [ret, ..list.append(from_locals, from_ops)]
    })
  let from_ctors =
    list.flat_map(custom_types, fn(custom) {
      let CustomType(_, _, _, variants) = custom
      list.flat_map(variants, fn(variant) {
        let Variant(_, fields) = variant
        list.map(fields, fn(field) {
          let #(_, ty) = field
          ty
        })
      })
    })
  types
  |> list.append(from_ctors)
  |> list.flat_map(tuple_types_in)
  |> dedupe_types
  |> list.sort(fn(a, b) { int.compare(tuple_depth(a), tuple_depth(b)) })
}

fn op_types(op: ir.Op) -> List(Type) {
  case op {
    ir.OpCall(_, _, _, ty) -> [ty]
    ir.OpBuiltin(_, _, _, ty) -> [ty]
    ir.OpTuple(_, _, ty) -> [ty]
    ir.OpTupleGet(_, _, _, ty) -> [ty]
    ir.OpCtor(_, _, _, _, ty) -> [ty]
    ir.OpField(_, _, _, _, ty) -> [ty]
    ir.OpCopy(_, _, ty) -> [ty]
    ir.OpRetain(_, ty) -> [ty]
    ir.OpDrop(_, ty) -> [ty]
    _ -> []
  }
}

fn tuple_types_in(ty: Type) -> List(Type) {
  case ty {
    TTuple(types) -> [ty, ..list.flat_map(types, tuple_types_in)]
    _ -> []
  }
}

fn tuple_depth(ty: Type) -> Int {
  case ty {
    TTuple(types) ->
      case types {
        [] -> 1
        _ ->
          1
          + list.fold(types, 0, fn(acc, inner) {
            max_int(acc, tuple_depth(inner))
          })
      }
    _ -> 0
  }
}

fn dedupe_types(types: List(Type)) -> List(Type) {
  let #(_, reversed) =
    list.fold(types, #(dict.new(), []), fn(acc, ty) {
      let #(seen, kept) = acc
      let key = type_key(ty)
      case dict.get(seen, key) {
        Ok(_) -> acc
        Error(_) -> #(dict.insert(seen, key, True), [ty, ..kept])
      }
    })
  list.reverse(reversed)
}

fn emit_tuple_type(ty: Type, recursive) -> String {
  case ty {
    TTuple(types) -> {
      let fields =
        types
        |> list.index_map(fn(inner, index) {
          "    "
          <> c_type(inner, recursive)
          <> " _"
          <> int.to_string(index)
          <> ";"
        })
      "typedef struct {\n"
      <> string.join(fields, "\n")
      <> "\n} "
      <> c_type(ty, recursive)
      <> ";\n"
    }
    _ -> ""
  }
}

fn emit_custom_type(custom: CustomType, recursive) -> String {
  let CustomType(_, name, _, variants) = custom
  let tags =
    list.map(variants, fn(variant) {
      let Variant(variant_name, _) = variant
      "    TAG_" <> name <> "_" <> variant_name
    })
  let tag_def =
    "typedef enum {\n"
    <> string.join(tags, ",\n")
    <> "\n} "
    <> name
    <> "_Tag;\n"

  let union_fields =
    list.filter_map(variants, fn(variant) {
      let Variant(variant_name, fields) = variant
      case fields {
        [] -> Error(Nil)
        _ -> Ok(field_struct(variant_name, fields, recursive))
      }
    })

  let union_def = case union_fields {
    [] -> ""
    _ -> "    union {\n" <> string.join(union_fields, "\n") <> "\n    };\n"
  }

  let body = "    " <> name <> "_Tag tag;\n" <> union_def

  case is_recursive(recursive, name) {
    True -> tag_def <> "struct " <> name <> " {\n" <> body <> "};\n"
    False -> tag_def <> "typedef struct {\n" <> body <> "} " <> name <> ";\n"
  }
}

fn field_struct(variant_name, fields, recursive) -> String {
  let declarations =
    fields
    |> list.index_map(fn(field, index) {
      let #(_, ty) = field
      "        " <> c_type(ty, recursive) <> " _" <> int.to_string(index) <> ";"
    })
  "        struct {\n"
  <> string.join(declarations, "\n")
  <> "\n        } "
  <> variant_name
  <> ";"
}

// ---------------------------------------------------------------------------
// retain/drop glue
// ---------------------------------------------------------------------------

fn collect_glue_types(functions, _custom_types, ctors) -> List(Type) {
  let seeds =
    list.flat_map(functions, fn(function) {
      let ir.Function(_, _, _, blocks, _) = function
      list.flat_map(blocks, fn(block) {
        let ir.Block(_, ops, _) = block
        list.flat_map(ops, fn(op) {
          case op {
            ir.OpRetain(_, ty) | ir.OpDrop(_, ty) -> [ty]
            _ -> []
          }
        })
      })
    })
  expand_glue(seeds, ctors, [])
}

fn expand_glue(pending, ctors, acc) {
  case pending {
    [] -> acc
    [ty, ..rest] -> {
      case glue_key(ty) {
        Error(_) -> expand_glue(rest, ctors, acc)
        Ok(key) ->
          case list.any(acc, fn(existing) { type_key(existing) == key }) {
            True -> expand_glue(rest, ctors, acc)
            False -> {
              let inner = glue_fields(ty, ctors)
              expand_glue(list.append(rest, inner), ctors, [ty, ..acc])
            }
          }
      }
    }
  }
}

/// Glue is only needed for handle types other than String.
fn glue_key(ty: Type) -> Result(String, Nil) {
  case ty {
    TString -> Error(Nil)
    TTuple(_) -> Ok(type_key(ty))
    TNamed(_) -> Ok(type_key(ty))
    ast.TFun(_, _) -> Ok(type_key(ty))
    _ -> Error(Nil)
  }
}

fn glue_fields(ty: Type, ctors) -> List(Type) {
  let fields_of = ownership.type_fields(ctors)
  case ty {
    TTuple(types) ->
      list.filter(types, fn(inner) { ownership.needs_drop(inner, ctors) })
    TNamed(name) ->
      case dict.get(fields_of, name) {
        Ok(fields) ->
          list.filter(fields, fn(inner) { ownership.needs_drop(inner, ctors) })
        Error(_) -> []
      }
    _ -> []
  }
}

fn glue_fn(kind: String, ty: Type) -> String {
  "Gleamc_rc_" <> kind <> "_" <> mangle_glue(ty)
}

fn mangle_glue(ty: Type) -> String {
  case ty {
    TTuple(types) -> "tuple_" <> string.join(list.map(types, mangle_type), "_")
    TNamed(name) -> name
    ast.TFun(_, _) -> mangle_type(ty)
    _ -> mangle_type(ty)
  }
}

fn glue_prototype(kind: String, ty: Type, recursive) -> String {
  "void " <> glue_fn(kind, ty) <> "(" <> c_type(ty, recursive) <> " v);\n"
}

fn glue_definition(kind: String, ty: Type, recursive, ctors) -> String {
  case ty {
    ast.TFun(_, _) ->
      "void "
      <> glue_fn(kind, ty)
      <> "("
      <> c_type(ty, recursive)
      <> " v) {\n"
      <> case kind {
        "retain" -> "    if (v.env != NULL) gleamc_retain(v.env);\n"
        _ ->
          "    if (v.env != NULL) { if (v.env_drop != NULL) v.env_drop(v.env); else gleamc_release(v.env); }\n"
      }
      <> "}\n"
    TNamed(name) ->
      case is_recursive(recursive, name) {
        True -> recursive_glue(kind, name, ty, ctors)
        False -> byvalue_named_glue(kind, name, ty, recursive, ctors)
      }
    TTuple(types) -> {
      let body =
        string.join(
          list.map(
            list.filter(
              list.index_map(types, fn(inner, index) { #(inner, index) }),
              fn(pair) {
                let #(inner, _) = pair
                ownership.needs_drop(inner, ctors)
              },
            ),
            fn(pair) {
              let #(inner, index) = pair
              "    "
              <> glue_call(kind, inner, "v._" <> int.to_string(index))
              <> ";"
            },
          ),
          "\n",
        )
      "void "
      <> glue_fn(kind, ty)
      <> "("
      <> c_type(ty, recursive)
      <> " v) {\n"
      <> body
      <> "\n}\n"
    }
    _ -> ""
  }
}

fn byvalue_named_glue(kind, name, ty, recursive, ctors) -> String {
  let body =
    string.join(
      list.map(type_variants(name, ctors), fn(variant) {
        let #(variant_name, fields) = variant
        let handle_fields =
          list.filter(list.index_map(fields, fn(t, i) { #(t, i) }), fn(pair) {
            let #(t, _) = pair
            ownership.needs_drop(t, ctors)
          })
        "    case TAG_"
        <> name
        <> "_"
        <> variant_name
        <> ":\n"
        <> string.join(
          list.map(handle_fields, fn(pair) {
            let #(t, i) = pair
            "        "
            <> glue_call(
              kind,
              t,
              "v." <> variant_name <> "._" <> int.to_string(i),
            )
            <> ";"
          }),
          "\n",
        )
        <> "\n        break;"
      }),
      "\n",
    )
  "void "
  <> glue_fn(kind, ty)
  <> "("
  <> c_type(ty, recursive)
  <> " v) {\n    switch (v.tag) {\n"
  <> body
  <> "\n    }\n}\n"
}

/// Recursive types are refcounted heap cells: retain bumps the cell, drop
/// frees its contents only on the last reference.
fn recursive_glue(kind, name, ty, ctors) -> String {
  let signature = "void " <> glue_fn(kind, ty) <> "(" <> name <> "* v)"
  case kind {
    "retain" -> signature <> " {\n    gleamc_retain(v);\n}\n"
    _ -> {
      let drop_fields =
        string.join(
          list.map(type_variants(name, ctors), fn(variant) {
            let #(variant_name, fields) = variant
            let handle_fields =
              list.filter(
                list.index_map(fields, fn(t, i) { #(t, i) }),
                fn(pair) {
                  let #(t, _) = pair
                  ownership.needs_drop(t, ctors)
                },
              )
            case handle_fields {
              [] -> ""
              _ ->
                "        case TAG_"
                <> name
                <> "_"
                <> variant_name
                <> ":\n"
                <> string.join(
                  list.map(handle_fields, fn(pair) {
                    let #(t, i) = pair
                    "            "
                    <> glue_call(
                      "drop",
                      t,
                      "v->" <> variant_name <> "._" <> int.to_string(i),
                    )
                    <> ";"
                  }),
                  "\n",
                )
                <> "\n            break;"
            }
          }),
          "\n",
        )
      signature
      <> " {\n"
      <> "    if (v == NULL) return;\n"
      <> "    if (((GleamcHdr*)((uint8_t*)v - sizeof(GleamcHdr)))->refcount == 1) {\n"
      <> "        switch (v->tag) {\n"
      <> drop_fields
      <> "\n        }\n"
      <> "    }\n"
      <> "    gleamc_release(v);\n"
      <> "}\n"
    }
  }
}

fn glue_call(kind: String, ty: Type, expr: String) -> String {
  case ty {
    TString ->
      case kind {
        "retain" -> "gleamc_string_retain(" <> expr <> ")"
        _ -> "gleamc_string_release(" <> expr <> ")"
      }
    _ -> glue_fn(kind, ty) <> "(" <> expr <> ")"
  }
}

// ---------------------------------------------------------------------------
// functions
// ---------------------------------------------------------------------------

fn emit_prototype(function: ir.Function, recursive) -> String {
  let ir.Function(name, params, ret, _, locals) = function
  let by_name = locals_map(locals)
  let param_types =
    list.map(params, fn(param) { c_type(local_type(by_name, param), recursive) })
  c_type(ret, recursive)
  <> " Gleamc_"
  <> name
  <> "("
  <> string.join(param_types, ", ")
  <> ");\n"
}

fn emit_function(function: ir.Function, recursive) -> String {
  let ir.Function(name, params, ret, blocks, locals) = function
  let by_name = locals_map(locals)
  let param_decls =
    list.map(params, fn(param) {
      c_type(local_type(by_name, param), recursive) <> " " <> c_safe(param)
    })
  let extra_locals =
    list.filter(locals, fn(local) {
      let ir.Local(local_name, _) = local
      !list.contains(params, local_name)
    })
  let local_decls =
    string.join(
      list.map(extra_locals, fn(local) {
        let ir.Local(local_name, local_ty) = local
        "    "
        <> c_type(local_ty, recursive)
        <> " "
        <> c_safe(local_name)
        <> ";"
      }),
      "\n",
    )
  let body = string.join(list.map(blocks, emit_block(by_name, recursive)), "\n")
  c_type(ret, recursive)
  <> " Gleamc_"
  <> name
  <> "("
  <> string.join(param_decls, ", ")
  <> ") {\n"
  <> local_decls
  <> "\n"
  <> body
  <> "\n}\n"
}

fn emit_block(by_name, recursive) {
  fn(block) {
    let ir.Block(label, ops, term) = block
    label
    <> ":\n"
    <> string.join(list.map(ops, emit_op(by_name, recursive)), "\n")
    <> "\n    "
    <> emit_term(by_name, term)
  }
}

fn emit_op(by_name, recursive) {
  fn(op) {
    case op {
      ir.OpConst(dest, value) ->
        "    " <> dest <> " = " <> literal_c(value) <> ";"
      ir.OpBinop(dest, op_name, a, b) ->
        "    "
        <> dest
        <> " = "
        <> binop_c(
          op_name,
          operand_type(by_name, a),
          operand_c(by_name, a),
          operand_c(by_name, b),
        )
        <> ";"
      ir.OpUnop(dest, op_name, a) ->
        "    "
        <> dest
        <> " = ("
        <> normalize_op(op_name)
        <> operand_c(by_name, a)
        <> ");"
      ir.OpCall(dest, fun, args, _) ->
        "    "
        <> dest
        <> " = Gleamc_"
        <> fun
        <> "("
        <> call_args(by_name, args)
        <> ");"
      ir.OpBuiltin(dest, builtin, args, _) ->
        "    "
        <> dest
        <> " = "
        <> builtin_name(builtin)
        <> "("
        <> call_args(by_name, args)
        <> ");"
      ir.OpTuple(dest, elems, ty) ->
        "    "
        <> dest
        <> " = ("
        <> c_type(ty, recursive)
        <> "){ "
        <> tuple_fields(by_name, elems)
        <> " };"
      ir.OpTupleGet(dest, tuple, index, _) ->
        "    "
        <> dest
        <> " = "
        <> operand_c(by_name, tuple)
        <> "._"
        <> int.to_string(index)
        <> ";"
      ir.OpCtor(dest, ctor, type_name, args, _) ->
        case is_recursive(recursive, type_name) {
          True ->
            "    "
            <> dest
            <> " = "
            <> recursive_ctor(by_name, ctor, type_name, args)
            <> ";"
          False ->
            "    "
            <> dest
            <> " = "
            <> ctor_literal(by_name, ctor, type_name, args)
            <> ";"
        }
      ir.OpTagIs(dest, subject, ctor, type_name) ->
        "    "
        <> dest
        <> " = ("
        <> operand_access(by_name, recursive, subject)
        <> "tag == TAG_"
        <> type_name
        <> "_"
        <> ctor
        <> ");"
      ir.OpField(dest, subject, ctor, index, ty) ->
        "    "
        <> dest
        <> " = "
        <> field_access(by_name, recursive, subject, ctor, index, ty)
        <> ";"
      ir.OpCopy(dest, src, _) ->
        "    " <> dest <> " = " <> operand_c(by_name, src) <> ";"
      ir.OpClosure(dest, code, captures, env_ty, fn_ty) ->
        closure_expr(by_name, recursive, dest, code, captures, env_ty, fn_ty)
      ir.OpEnvGet(dest, env_ty, index, _) ->
        "    "
        <> dest
        <> " = (("
        <> env_ty
        <> "*)__env)->_"
        <> int.to_string(index)
        <> ";"
      ir.OpCallIndirect(dest, fval, args, _) ->
        "    "
        <> dest
        <> " = "
        <> operand_c(by_name, fval)
        <> ".code("
        <> operand_c(by_name, fval)
        <> ".env"
        <> case args {
          [] -> ""
          _ -> ", " <> call_args(by_name, args)
        }
        <> ");"
      ir.OpRetain(src, ty) -> "    " <> retain_stmt(ty, c_safe(src), recursive)
      ir.OpDrop(src, ty) -> "    " <> drop_stmt(ty, c_safe(src), recursive)
    }
  }
}

/// `subject.` or `subject->` depending on whether the subject is a recursive
/// heap cell.
fn operand_access(by_name, recursive, subject) -> String {
  let base = operand_c(by_name, subject)
  case operand_type(by_name, subject) {
    TNamed(name) ->
      case is_recursive(recursive, name) {
        True -> base <> "->"
        False -> base <> "."
      }
    _ -> base <> "."
  }
}

fn field_access(by_name, recursive, subject, ctor, index, _ty) -> String {
  operand_access(by_name, recursive, subject)
  <> ctor
  <> "._"
  <> int.to_string(index)
}

/// Builds a refcounted heap cell for a recursive constructor.
fn recursive_ctor(by_name, ctor, type_name, args) -> String {
  let assigns =
    string.join(
      list.index_map(args, fn(arg, index) {
        "        _node->"
        <> ctor
        <> "._"
        <> int.to_string(index)
        <> " = "
        <> operand_c(by_name, arg)
        <> ";"
      }),
      "\n",
    )
  "({ "
  <> type_name
  <> "* _node = ("
  <> type_name
  <> "*)gleamc_alloc(sizeof("
  <> type_name
  <> ")); _node->tag = TAG_"
  <> type_name
  <> "_"
  <> ctor
  <> ";"
  <> case assigns {
    "" -> ""
    _ -> "\n" <> assigns <> "\n    "
  }
  <> " _node; })"
}

fn emit_term(by_name, term) {
  case term {
    ir.Jmp(label) -> "goto " <> label <> ";"
    ir.Branch(cond, then, otherwise) ->
      "if ("
      <> operand_c(by_name, cond)
      <> ") { goto "
      <> then
      <> "; } else { goto "
      <> otherwise
      <> "; }"
    ir.Ret(value) -> "return " <> operand_c(by_name, value) <> ";"
    ir.Unreachable -> "abort();"
  }
}

fn binop_c(op, operand_ty, left, right) -> String {
  case op {
    "<>" -> "gleamc_string_concat(" <> left <> ", " <> right <> ")"
    "==" ->
      case operand_ty {
        TString -> "gleamc_string_eq(" <> left <> ", " <> right <> ")"
        _ -> "(" <> left <> " == " <> right <> ")"
      }
    "!=" ->
      case operand_ty {
        TString -> "(!gleamc_string_eq(" <> left <> ", " <> right <> "))"
        _ -> "(" <> left <> " != " <> right <> ")"
      }
    "&&" -> "(" <> left <> " && " <> right <> ")"
    "||" -> "(" <> left <> " || " <> right <> ")"
    _ -> "(" <> left <> " " <> normalize_op(op) <> " " <> right <> ")"
  }
}

fn normalize_op(op) -> String {
  case op {
    "+." -> "+"
    "-." -> "-"
    "*." -> "*"
    "/." -> "/"
    "<." -> "<"
    ">." -> ">"
    "<=." -> "<="
    ">=." -> ">="
    _ -> op
  }
}

fn call_args(by_name, args) -> String {
  string.join(list.map(args, fn(arg) { operand_c(by_name, arg) }), ", ")
}

fn tuple_fields(by_name, elems) -> String {
  elems
  |> list.index_map(fn(elem, index) {
    "._" <> int.to_string(index) <> " = " <> operand_c(by_name, elem)
  })
  |> string.join(", ")
}

fn ctor_literal(by_name, ctor, type_name, args) -> String {
  case args {
    [] ->
      "(" <> type_name <> "){ .tag = TAG_" <> type_name <> "_" <> ctor <> " }"
    _ ->
      "("
      <> type_name
      <> "){ .tag = TAG_"
      <> type_name
      <> "_"
      <> ctor
      <> ", ."
      <> ctor
      <> " = { "
      <> tuple_fields(by_name, args)
      <> " } }"
  }
}

fn retain_stmt(ty, expr, _recursive) -> String {
  glue_call("retain", ty, expr) <> ";"
}

fn drop_stmt(ty, expr, _recursive) -> String {
  glue_call("drop", ty, expr) <> ";"
}

fn type_variants(name: String, ctors) -> List(#(String, List(Type))) {
  list.fold(dict.to_list(ctors), [], fn(acc, entry) {
    let #(ctor, info) = entry
    let checker.CtorInfo(type_name, fields) = info
    case type_name == name {
      True ->
        list.append(acc, [
          #(
            ctor,
            list.map(fields, fn(field) {
              let #(_, field_ty) = field
              field_ty
            }),
          ),
        ])
      False -> acc
    }
  })
}

fn closure_expr(
  by_name,
  recursive,
  dest,
  code,
  captures,
  env_ty,
  fn_ty,
) -> String {
  let ty_name = c_type(fn_ty, recursive)
  case captures {
    [] ->
      "    "
      <> dest
      <> " = ("
      <> ty_name
      <> "){ .code = "
      <> code
      <> ", .env = NULL, .env_drop = NULL };"
    _ -> {
      let assigns =
        string.join(
          list.index_map(captures, fn(cap, index) {
            "_e->_"
            <> int.to_string(index)
            <> " = "
            <> operand_c(by_name, cap)
            <> ";"
          }),
          " ",
        )
      "    "
      <> dest
      <> " = ({ "
      <> env_ty
      <> "* _e = ("
      <> env_ty
      <> "*)gleamc_alloc(sizeof("
      <> env_ty
      <> ")); "
      <> assigns
      <> " ("
      <> ty_name
      <> "){ .code = "
      <> code
      <> ", .env = _e, .env_drop = "
      <> env_ty
      <> "_drop }; });"
    }
  }
}

fn builtin_name(builtin) -> String {
  "Gleamc_" <> string.replace(builtin, ".", "_")
}

// ---------------------------------------------------------------------------
// operands
// ---------------------------------------------------------------------------

fn locals_map(locals) -> Dict(String, Type) {
  list.fold(locals, dict.new(), fn(acc, local) {
    let ir.Local(local_name, local_ty) = local
    dict.insert(acc, local_name, local_ty)
  })
}

fn local_type(by_name, name) -> Type {
  case dict.get(by_name, name) {
    Ok(ty) -> ty
    Error(_) -> ast.TNil
  }
}

fn operand_c(_by_name, operand) -> String {
  case operand {
    ir.Var(name) -> c_safe(name)
    ir.Lit(value) -> literal_c(value)
  }
}

fn operand_type(by_name, operand) -> Type {
  case operand {
    ir.Var(name) -> local_type(by_name, name)
    ir.Lit(value) -> literal_type(value)
  }
}

fn literal_type(value) -> Type {
  case value {
    ir.LInt(_) -> ast.TInt
    ir.LFloat(_) -> ast.TFloat
    ir.LBool(_) -> ast.TBool
    ir.LUnit -> ast.TNil
    ir.LString(_) -> TString
  }
}

fn literal_c(value) -> String {
  case value {
    ir.LInt(v) -> int.to_string(v)
    ir.LFloat(v) -> float_literal(v)
    ir.LBool(True) -> "true"
    ir.LBool(False) -> "false"
    ir.LUnit -> "0"
    ir.LString(v) ->
      "(GleamcString){ __gl_lit_"
      <> literal_key(v)
      <> ".bytes, "
      <> int.to_string(string.byte_size(v))
      <> " }"
  }
}

// ---------------------------------------------------------------------------
// static string literals (immortal .rodata blocks, doc 03 §10 of Vesper)
// ---------------------------------------------------------------------------

fn literal_key(content: String) -> String {
  content
  |> string.to_utf_codepoints
  |> list.fold(5381, fn(acc, codepoint) {
    int_mod(acc * 33 + string.utf_codepoint_to_int(codepoint), 1_000_000_007)
  })
  |> int.to_string
}

fn int_mod(a: Int, b: Int) -> Int {
  a - a / b * b
}

fn collect_string_literals(functions) -> List(#(String, String)) {
  let contents =
    list.flat_map(functions, fn(function) {
      let ir.Function(_, _, _, blocks, _) = function
      list.flat_map(blocks, fn(block) {
        let ir.Block(_, ops, _) = block
        list.filter_map(ops, fn(op) {
          case op {
            ir.OpConst(_, ir.LString(value)) -> Ok(value)
            _ -> Error(Nil)
          }
        })
      })
    })
  dedupe_literals(contents, dict.new(), [])
}

fn dedupe_literals(contents, seen, acc) {
  case contents {
    [] -> list.reverse(acc)
    [content, ..rest] -> {
      let key = literal_key(content)
      case dict.get(seen, key) {
        Ok(_) -> dedupe_literals(rest, seen, acc)
        Error(_) ->
          dedupe_literals(rest, dict.insert(seen, key, True), [
            #(key, content),
            ..acc
          ])
      }
    }
  }
}

fn emit_string_literals(lits) -> String {
  string.join(
    list.map(lits, fn(pair) {
      let #(key, content) = pair
      let size = string.byte_size(content)
      "static const struct { GleamcHdr hdr; char bytes["
      <> int.to_string(size + 1)
      <> "]; } __gl_lit_"
      <> key
      <> " = { { GLEAMC_RC_STATIC }, \""
      <> c_escape(content)
      <> "\" };\n"
    }),
    "",
  )
}

fn max_int(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}
