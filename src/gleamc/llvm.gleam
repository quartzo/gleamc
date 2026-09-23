//// LLVM IR code generator (backend em migração, alvo oficial).
////
//// Consome a IR após o passe de ownership e emite `.ll`. O runtime C
//// (`runtime/gleam_runtime.c`) continua sendo linkado; o IR só declara/usa
//// os símbolos `Gleamc_*`. Tail calls são emitidas com `musttail`, que
//// garante pilha constante mesmo em `-O0`.
////
//// Etapa inicial: primitivos (Int/Float/Bool/String/Nil), blocos,
//// terminadores, chamadas diretas e builtins genéricos. Tipos customizados,
//// glue e closures entram nas próximas etapas.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/string
import gleamc/ast.{type Type, TNamed, TString}
import gleamc/checker
import gleamc/ffi
import gleamc/ir
import gleamc/ownership
import gleamc/plan

type Ctx {
  Ctx(
    recursive: Dict(String, Bool),
    by_name: Dict(String, Type),
    lits: Dict(String, Int),
    blocks: Dict(String, String),
    ret: Type,
    custom_types: List(ast.CustomType),
    custom_by_name: Dict(String, ast.CustomType),
    ctors: Dict(String, checker.CtorInfo),
    tuples: List(Type),
    fn_name: String,
    entry: String,
    params: List(String),
    prefix: String,
    group: Dict(String, #(String, List(String), String)),
  )
}

// ---------------------------------------------------------------------------
// entry point
// ---------------------------------------------------------------------------

pub fn emit(
  ir_module: ir.Module,
  custom_types: List(ast.CustomType),
  ctors: Dict(String, checker.CtorInfo),
) -> String {
  // Canonical ordering: emission order must depend only on the input, never
  // on `dict` iteration order (which differs between hosts).
  let ir.Module(functions) = ir_module
  let functions =
    list.sort(functions, fn(a, b) { string.compare(a.name, b.name) })
  let custom_types =
    list.sort(custom_types, fn(a, b) {
      string.compare(type_name_of(a), type_name_of(b))
    })
  let custom_by_name =
    dict.from_list(list.map(custom_types, fn(custom) {
      let ast.CustomType(_, n, _, _, _) = custom
      #(n, custom)
    }))
  let recursive = ownership.recursive_types(ctors)
  let fields_of = ownership.type_fields(ctors)
  let tuples =
    collect_tuple_types(custom_types, functions)
    |> list.sort(fn(a, b) { string.compare(tuple_key(a), tuple_key(b)) })
  let all_groups = eligible_groups(ir_module, ctors)
  let fn_types =
    collect_fn_types(custom_types, functions)
    |> list.sort(fn(a, b) { string.compare(mangle_type(a), mangle_type(b)) })
  let env_structs =
    collect_env_structs(functions)
    |> list.sort(fn(a, b) {
      let #(an, _) = a
      let #(bn, _) = b
      string.compare(an, bn)
    })
  // Refcount audit site tags ("fn:local", "alloc:T", glue names) are only
  // meaningful when the runtime is built with -DGLEAMC_RC_AUDIT. Otherwise the
  // site argument degrades to `null` (see `cstring_arg`), so it is not worth
  // emitting tens of thousands of string globals for them.
  let audit = case ffi.get_env("GLEAMC_RC_AUDIT") {
    Ok(_) -> True
    Error(_) -> False
  }
  let site_literals = case audit {
    True -> collect_rc_sites(functions, custom_types, tuples, ctors)
    False -> []
  }
  let lit_list =
    dedupe(
      list.append(
        list.append(collect_literals(functions), glue_literals(custom_types)),
        site_literals,
      ),
      dict.new(),
      [],
    )
    |> list.sort(fn(a, b) { string.compare(a, b) })
  let lits =
    lit_list
    |> list.index_map(fn(content, index) { #(content, index) })
    |> dict.from_list

  let globals =
    string.join(
      list.index_map(lit_list, fn(content, index) {
        literal_global(content, index)
      }),
      "\n",
    )

  let type_code =
    string.join(
      list.map(custom_types, fn(custom) { custom_type_decl(custom, recursive) }),
      "\n",
    )
    <> "\n"
    <> string.join(
      list.map(tuples, fn(ty) { tuple_type_decl(ty, recursive) }),
      "\n",
    )
    <> "\n"
    <> string.join(
      list.map(fn_types, fn(ty) { fn_type_decl(ty, recursive) }),
      "\n",
    )
    <> "\n"
    <> string.join(
      list.map(env_structs, fn(entry) { env_type_decl(entry, recursive) }),
      "\n",
    )
    <> "\n"
    <> group_type_decls(all_groups, recursive)

  let builtins =
    string.join(
      list.unique(
        list.flat_map(functions, fn(function) {
          builtin_decls(function, recursive)
        }),
      ),
      "\n",
    )

  let group_fns = all_groups
  let member_names =
    list.flat_map(group_fns, fn(group) { list.map(group, fn(f) { f.name }) })
  let member_set =
    list.fold(member_names, dict.new(), fn(acc, n) { dict.insert(acc, n, True) })
  let group_defs =
    string.join(
      list.flat_map(group_fns, fn(group) {
        let #(dispatcher, wrappers) =
          emit_group(group, recursive, lits, custom_types, custom_by_name, ctors, tuples)
        list.append([dispatcher], wrappers)
      }),
      "\n\n",
    )
  let normal_fns =
    list.filter(functions, fn(function) {
      case dict.get(member_set, function.name) {
        Ok(_) -> False
        Error(_) -> True
      }
    })
  let defs =
    group_defs
    <> case group_defs {
      "" -> ""
      _ -> "\n\n"
    }
    <> string.join(
      list.map(normal_fns, fn(function) {
        emit_function(function, recursive, lits, custom_types, custom_by_name, ctors, tuples)
      }),
      "\n\n",
    )
  let wrappers =
    string.join(
      list.map(collect_wrappers(functions, recursive), fn(entry) { entry }),
      "\n\n",
    )
  let seeds =
    list.append(
      list.map(custom_types, fn(custom) {
        let ast.CustomType(_, name, _, _, _) = custom
        TNamed(name)
      }),
      tuples,
    )
  let eq_glue =
    string.join(
      list.map(seeds, fn(ty) { emit_eq_glue(recursive, custom_types, ty) }),
      "\n\n",
    )
  let cmp_glue =
    string.join(
      list.append(
        [
          emit_cmp_glue(recursive, custom_types, ast.TInt),
          emit_cmp_glue(recursive, custom_types, ast.TFloat),
          emit_cmp_glue(recursive, custom_types, ast.TBool),
          emit_cmp_glue(recursive, custom_types, TString),
          emit_cmp_glue(recursive, custom_types, TNamed("BitArray")),
          emit_cmp_glue(recursive, custom_types, ast.TNil),
        ],
        list.map(seeds, fn(ty) { emit_cmp_glue(recursive, custom_types, ty) }),
      ),
      "\n\n",
    )
  let env_drops =
    string.join(
      list.map(env_structs, fn(entry) {
        emit_env_drop(entry, recursive, fields_of, lits)
      }),
      "\n\n",
    )
  let rc_glue =
    string.join(
      list.flat_map(seeds, fn(ty) {
        [
          emit_rc_glue(lits, recursive, custom_types, fields_of, "retain", ty),
          emit_rc_glue(lits, recursive, custom_types, fields_of, "drop", ty),
        ]
      }),
      "\n\n",
    )
  let show_glue =
    string.join(
      list.append(
        [
          emit_show_glue(recursive, custom_types, lits, ast.TInt),
          emit_show_glue(recursive, custom_types, lits, ast.TFloat),
          emit_show_glue(recursive, custom_types, lits, ast.TBool),
          emit_show_glue(recursive, custom_types, lits, TString),
          emit_show_glue(recursive, custom_types, lits, TNamed("BitArray")),
          emit_show_glue(recursive, custom_types, lits, ast.TNil),
        ],
        list.map(seeds, fn(ty) {
          emit_show_glue(recursive, custom_types, lits, ty)
        }),
      ),
      "\n\n",
    )

  let main_code = case list.any(functions, fn(f) { f.name == "main" }) {
    True ->
      "\ndefine i32 @main(i32 %argc, i8** %argv) {\n"
      <> "  call void @Gleamc_set_args(i32 %argc, i8** %argv)\n"
      <> "  call i32 @Gleamc_main()\n"
      <> "  ret i32 0\n"
      <> "}\n"
    False -> ""
  }

  let out =
    string.join(
      [
        header(),
        globals,
        "\n\n",
        type_code,
        "\n\n",
        builtins,
        "\n\n",
        defs,
        "\n\n",
        wrappers,
        "\n\n",
        eq_glue,
        "\n\n",
        env_drops,
        "\n\n",
        rc_glue,
        "\n\n",
        show_glue,
        "\n\n",
        cmp_glue,
        "\n",
        main_code,
      ],
      "",
    )
  out
}

fn header() -> String {
  "target triple = \"x86_64-pc-linux-gnu\"\n\n"
  <> "%GleamcString = type { i8*, i64 }\n"
  <> "%GleamcBitArray = type { i8*, i64 }\n"
  <> "%GleamcFileResult = type { i64, %GleamcBitArray, i64 }\n\n"
  <> "declare void @Gleamc_set_args(i32, i8**)\n"
  <> "declare i8* @gleamc_alloc(i64)\n"
  <> "declare i8* @gleamc_alloc_site(i64, i8*)\n"
  <> "declare void @Gleamc_rc_retain(i8*, i8*)\n"
  <> "declare void @Gleamc_rc_release(i8*, i8*)\n"
  <> "declare %GleamcString @gleamc_string_lit(i8*, i64)\n"
  <> "declare %GleamcString @Gleamc_show_concat(%GleamcString, %GleamcString)\n"
  <> "declare %GleamcString @Gleamc_int_to_string(i64)\n"
  <> "declare %GleamcString @Gleamc_float_to_string(double)\n"
  <> "declare %GleamcString @Gleamc_bool_to_string(i1)\n"
  <> "declare %GleamcString @Gleamc_string_show(%GleamcString)\n"
  <> "declare void @Gleamc_panic(%GleamcString)\n"
  <> "declare i32 @Gleamc_io_debug(%GleamcString)\n"
  <> "declare i32 @memcmp(i8*, i8*, i64)\n"
  <> "declare i32 @Gleamc_string_compare_bytes(%GleamcString, %GleamcString)\n"
  <> "declare %GleamcString @gleamc_string_concat(%GleamcString, %GleamcString)\n"
  <> "declare i1 @gleamc_string_eq(%GleamcString, %GleamcString)\n"
  <> "declare i1 @Gleamc_bit_array_eq(%GleamcBitArray, %GleamcBitArray)\n"
  <> "declare %GleamcBitArray @Gleamc_bit_array_new(i64)\n"
  <> "declare %GleamcBitArray @Gleamc_bit_array_from_bytes(i64*, i64)\n"
}

// ---------------------------------------------------------------------------
// literals
// ---------------------------------------------------------------------------

fn collect_literals(functions: List(ir.Function)) -> List(String) {
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
  dedupe(contents, dict.new(), [])
}

fn dedupe(
  items: List(String),
  seen: Dict(String, Bool),
  acc: List(String),
) -> List(String) {
  case items {
    [] -> list.reverse(acc)
    [item, ..rest] ->
      case dict.get(seen, item) {
        Ok(_) -> dedupe(rest, seen, acc)
        Error(_) -> dedupe(rest, dict.insert(seen, item, True), [item, ..acc])
      }
  }
}

fn literal_index(lits: Dict(String, Int), content: String) -> Int {
  case dict.get(lits, content) {
    Ok(index) -> index
    Error(_) -> -1
  }
}

fn escape_bytes(value: String) -> String {
  value
  |> string.to_utf_codepoints
  |> list.map(fn(cp) {
    let byte = string.utf_codepoint_to_int(cp)
    "\\" <> hex2(byte)
  })
  |> string.join("")
}

fn hex2(byte: Int) -> String {
  let digits = "0123456789ABCDEF"
  string.slice(digits, byte / 16, 1) <> string.slice(digits, byte % 16, 1)
}

fn literal_global(content: String, index: Int) -> String {
  let size = string.byte_size(content) + 1
  "@.str."
  <> int.to_string(index)
  <> " = private unnamed_addr constant { i64, ["
  <> int.to_string(size)
  <> " x i8] } { i64 -1, ["
  <> int.to_string(size)
  <> " x i8] c\""
  <> escape_bytes(content)
  <> "\\00\" }"
}

// ---------------------------------------------------------------------------
// types
// ---------------------------------------------------------------------------

fn llvm_ty(ty: Type, recursive: Dict(String, Bool)) -> String {
  case ty {
    ast.TInt -> "i64"
    ast.TFloat -> "double"
    ast.TBool -> "i1"
    TString -> "%GleamcString"
    TNamed("void*") -> "i8*"
    TNamed("BitArray") -> "%GleamcBitArray"
    TNamed("FileResult") -> "%GleamcFileResult"
    ast.TNil -> "i32"
    ast.TVar(name) -> name
    TNamed("Nil") -> "i32"
    TNamed(name) ->
      case is_recursive(recursive, name) {
        True -> "%" <> name <> "*"
        False -> "%" <> name
      }
    ast.TApp(name, args) ->
      "%" <> name <> "_" <> string.join(list.map(args, mangle_type), "_")
    ast.TTuple(types) ->
      "%GleamcTuple_" <> string.join(list.map(types, mangle_type), "_")
    ast.TFun(_, _) -> "%GleamFn_" <> mangle_type(ty)
  }
}

fn is_recursive(recursive: Dict(String, Bool), name: String) -> Bool {
  case dict.get(recursive, name) {
    Ok(True) -> True
    _ -> False
  }
}

fn mangle_type(ty: Type) -> String {
  case ty {
    ast.TInt -> "i64"
    ast.TFloat -> "f64"
    ast.TBool -> "b"
    TString -> "str"
    TNamed("BitArray") -> "bitarray"
    TNamed("FileResult") -> "fileresult"
    ast.TNil -> "nil"
    ast.TVar(name) -> name
    TNamed("Nil") -> "nil"
    TNamed(name) -> name
    ast.TApp(name, args) ->
      name <> "_" <> string.join(list.map(args, mangle_type), "_")
    ast.TTuple(types) -> "t" <> string.join(list.map(types, mangle_type), "_")
    ast.TFun(params, ret) ->
      "fn_"
      <> string.join(list.map(params, mangle_type), "_")
      <> "_"
      <> mangle_type(ret)
  }
}

fn safe(name: String) -> String {
  name
  |> string.replace("@", "_")
  |> string.replace(".", "_")
  |> string.replace("-", "_")
}

// ---------------------------------------------------------------------------
// type declarations (custom types and tuples)
// ---------------------------------------------------------------------------

fn custom_type_decl(
  custom: ast.CustomType,
  recursive: Dict(String, Bool),
) -> String {
  let ast.CustomType(_, name, _, variants, _) = custom
  let groups =
    list.index_map(variants, fn(variant, index) {
      let ast.Variant(_, fields) = variant
      let field_tys =
        list.map(fields, fn(field) {
          let #(_, ty) = field
          llvm_ty(ty, recursive)
        })
      "%"
      <> name
      <> ".v"
      <> int.to_string(index)
      <> " = type { "
      <> string.join(field_tys, ", ")
      <> " }"
    })
  let members =
    list.index_map(variants, fn(_, index) {
      "%" <> name <> ".v" <> int.to_string(index)
    })
  "%"
  <> name
  <> " = type { i8"
  <> case members {
    [] -> " }"
    _ -> ", " <> string.join(members, ", ") <> " }"
  }
  <> "\n"
  <> string.join(groups, "\n")
}

fn tuple_type_decl(ty: Type, recursive: Dict(String, Bool)) -> String {
  case ty {
    ast.TTuple(types) ->
      "%"
      <> "GleamcTuple_"
      <> tuple_suffix(types)
      <> " = type { "
      <> string.join(
        list.map(types, fn(inner) { llvm_ty(inner, recursive) }),
        ", ",
      )
      <> " }"
    _ -> ""
  }
}

fn type_name_of(custom: ast.CustomType) -> String {
  let ast.CustomType(_, name, _, _, _) = custom
  name
}

fn tuple_key(ty: Type) -> String {
  case ty {
    ast.TTuple(types) -> tuple_suffix(types)
    _ -> mangle_type(ty)
  }
}

fn tuple_suffix(types: List(Type)) -> String {
  string.join(list.map(types, mangle_type), "_")
}

fn base_ctor_name(ctor: String, type_name: String) -> String {
  case string.split(ctor, "_" <> type_name) {
    [base, ..] -> base
    [] -> ctor
  }
}

fn variant_index(ctx: Ctx, ctor: String, type_name: String) -> Int {
  let base = base_ctor_name(ctor, type_name)
  case dict.get(ctx.custom_by_name, type_name) {
    Ok(custom) -> {
      let ast.CustomType(_, _, _, variants, _) = custom
      case find_variant_index(variants, base, type_name) {
        Ok(index) -> index
        Error(_) -> 0
      }
    }
    Error(_) -> 0
  }
}

fn find_variant_index(
  variants: List(ast.Variant),
  base: String,
  type_name: String,
) -> Result(Int, Nil) {
  case variants {
    [] -> Error(Nil)
    [variant, ..rest] -> {
      let ast.Variant(name, _) = variant
      case base_ctor_name(name, type_name) == base {
        True -> Ok(0)
        False ->
          case find_variant_index(rest, base, type_name) {
            Ok(index) -> Ok(index + 1)
            Error(_) -> Error(Nil)
          }
      }
    }
  }
}

fn collect_tuple_types(
  custom_types: List(ast.CustomType),
  functions: List(ir.Function),
) -> List(Type) {
  let from_custom =
    list.flat_map(custom_types, fn(custom) {
      let ast.CustomType(_, _, _, variants, _) = custom
      list.flat_map(variants, fn(variant) {
        let ast.Variant(_, fields) = variant
        list.flat_map(fields, fn(field) {
          let #(_, ty) = field
          tuple_types_in(ty)
        })
      })
    })
  let from_fns =
    list.flat_map(functions, fn(function) {
      let ir.Function(_, _, ret, blocks, locals) = function
      let from_locals =
        list.flat_map(locals, fn(local) {
          let ir.Local(_, ty) = local
          tuple_types_in(ty)
        })
      let from_ops =
        list.flat_map(blocks, fn(block) {
          let ir.Block(_, ops, _) = block
          list.flat_map(ops, fn(op) {
            list.flat_map(op_types(op), tuple_types_in)
          })
        })
      list.append(tuple_types_in(ret), list.append(from_locals, from_ops))
    })
    |> list.append(from_custom)
  dedupe_types(from_fns, dict.new(), [])
}

fn op_types(op: ir.Op) -> List(Type) {
  case op {
    ir.OpCall(_, _, _, ret_ty) -> [ret_ty]
    ir.OpBuiltin(_, _, _, ret_ty) -> [ret_ty]
    ir.OpTuple(_, _, ty) -> [ty]
    ir.OpBitArray(_, _, ty) -> [ty]
    ir.OpTupleGet(_, _, _, ty) -> [ty]
    ir.OpCtor(_, _, _, _, ty) -> [ty]
    ir.OpField(_, _, _, _, ty) -> [ty]
    ir.OpCopy(_, _, ty) -> [ty]
    ir.OpEnvGet(_, _, _, ty) -> [ty]
    ir.OpCallIndirect(_, _, _, ret_ty) -> [ret_ty]
    ir.OpRetain(_, ty) -> [ty]
    ir.OpDrop(_, ty) -> [ty]
    _ -> []
  }
}

fn tuple_types_in(ty: Type) -> List(Type) {
  case ty {
    ast.TTuple(types) -> [ty, ..list.flat_map(types, tuple_types_in)]
    ast.TApp(_, args) -> list.flat_map(args, tuple_types_in)
    ast.TFun(params, ret) ->
      list.append(list.flat_map(params, tuple_types_in), tuple_types_in(ret))
    _ -> []
  }
}

fn dedupe_types(
  types: List(Type),
  seen: Dict(String, Bool),
  acc: List(Type),
) -> List(Type) {
  case types {
    [] -> list.reverse(acc)
    [ty, ..rest] -> {
      let key = mangle_type(ty)
      case dict.get(seen, key) {
        Ok(_) -> dedupe_types(rest, seen, acc)
        Error(_) ->
          dedupe_types(rest, dict.insert(seen, key, True), [ty, ..acc])
      }
    }
  }
}

fn subject_struct(ctx: Ctx, operand: ir.Operand, b: Builder) {
  let #(ty_s, v, b) = read_val(ctx, operand, b)
  case operand_type(ctx.by_name, operand) {
    TNamed(name) ->
      case is_recursive(ctx.recursive, name) {
        True -> {
          let #(tmp, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  " <> tmp <> " = load %" <> name <> ", %" <> name <> "* " <> v,
            )
          #("%" <> name, tmp, b)
        }
        False -> #(ty_s, v, b)
      }
    _ -> #(ty_s, v, b)
  }
}

fn extract_value(
  struct_ty: String,
  struct_reg: String,
  indices: List(Int),
  b: Builder,
) {
  let #(tmp, b) = fresh(b)
  let idx = string.join(list.map(indices, fn(i) { int.to_string(i) }), ", ")
  let b =
    emit_line(
      b,
      "  "
        <> tmp
        <> " = extractvalue "
        <> struct_ty
        <> " "
        <> struct_reg
        <> ", "
        <> idx,
    )
  #(tmp, b)
}

// ---------------------------------------------------------------------------
// functions
// ---------------------------------------------------------------------------

fn builtin_decls(
  function: ir.Function,
  recursive: Dict(String, Bool),
) -> List(String) {
  let ir.Function(_, _, _, blocks, locals) = function
  let by_name = locals_map(locals)
  list.flat_map(blocks, fn(block) {
    let ir.Block(_, ops, _) = block
    list.filter_map(ops, fn(op) {
      case op {
        ir.OpBuiltin(_, builtin, args, ret_ty) ->
          case
            special_builtin(builtin)
            || runtime_declared("Gleamc_" <> string.replace(builtin, ".", "_"))
          {
            True -> Error(Nil)
            False -> Ok(builtin_decl(builtin, ret_ty, args, by_name, recursive))
          }
        _ -> Error(Nil)
      }
    })
  })
}

fn emit_function(
  function: ir.Function,
  recursive: Dict(String, Bool),
  lits: Dict(String, Int),
  custom_types: List(ast.CustomType),
  custom_by_name: Dict(String, ast.CustomType),
  ctors: Dict(String, checker.CtorInfo),
  tuples: List(Type),
) -> String {
  let ir.Function(name, params, ret, blocks, locals) = function
  let by_name = locals_map(locals)
  let ctx =
    Ctx(
      recursive: recursive,
      by_name: by_name,
      lits: lits,
      blocks: block_names(blocks),
      ret: ret,
      custom_types: custom_types,
      custom_by_name: custom_by_name,
      ctors: ctors,
      tuples: tuples,
      fn_name: name,
      entry: case blocks {
        [ir.Block(label, _, _), ..] -> block_name_of(blocks, label)
        [] -> "bb0"
      },
      params: params,
      prefix: "",
      group: dict.new(),
    )
  let b = Builder(next: 0, lines: [])
  let b = emit_allocas(ctx, params, locals, b)
  let b = case blocks {
    [ir.Block(label, _, _), ..] ->
      emit_line(b, "  br label %" <> block_name(ctx, label))
    [] -> b
  }
  let #(b, _) = emit_block_list(ctx, blocks, b)
  let lines = list.reverse(b.lines)
  let args =
    list.map(params, fn(param) {
      llvm_ty(local_type(by_name, param), recursive) <> " %arg." <> safe(param)
    })
  "define "
  <> llvm_ty(ret, recursive)
  <> " @Gleamc_"
  <> name
  <> "("
  <> string.join(args, ", ")
  <> ") {\n"
  <> string.join(lines, "\n")
  <> "\n}\n"
}

fn block_names(blocks: List(ir.Block)) -> Dict(String, String) {
  blocks
  |> list.index_map(fn(block, index) {
    let ir.Block(label, _, _) = block
    #(label, "bb" <> int.to_string(index))
  })
  |> dict.from_list
}

fn emit_allocas(
  ctx: Ctx,
  params: List(String),
  locals: List(ir.Local),
  b: Builder,
) -> Builder {
  let b =
    list.fold(locals, b, fn(b, local) {
      let ir.Local(name, ty) = local
      let ty_s = llvm_ty(ty, ctx.recursive)
      emit_line(b, "  " <> local_ptr(ctx, name) <> " = alloca " <> ty_s)
    })
  list.fold(params, b, fn(b, param) {
    let ty = local_type(ctx.by_name, param)
    let ty_s = llvm_ty(ty, ctx.recursive)
    emit_line(
      b,
      "  store "
        <> ty_s
        <> " %arg."
        <> safe(param)
        <> ", "
        <> ty_s
        <> "* "
        <> local_ptr(ctx, param),
    )
  })
}

fn emit_block_list(ctx: Ctx, blocks: List(ir.Block), b: Builder) {
  case blocks {
    [] -> #(b, Nil)
    [block, ..rest] -> {
      let ir.Block(label, ops, term) = block
      let b = emit_line(b, "\n" <> block_name(ctx, label) <> ":")
      let #(b, _) = emit_ops(ctx, ops, b)
      let b = emit_term(ctx, term, b)
      emit_block_list(ctx, rest, b)
    }
  }
}

fn emit_rebind(ctx: Ctx, target, args, b: Builder) -> Builder {
  let #(prefix, params, entry) = target
  let #(b, vals) = read_typed_args(ctx, args, b)
  let b =
    list.index_fold(vals, b, fn(b, pair, index) {
      let #(ty, v) = pair
      case list_at(params, index) {
        Ok(pname) ->
          emit_line(
            b,
            "  store "
              <> ty
              <> " "
              <> v
              <> ", "
              <> ty
              <> "* %l."
              <> prefix
              <> safe(pname),
          )
        Error(_) -> b
      }
    })
  emit_line(b, "  br label %" <> entry)
}

fn local_ptr(ctx: Ctx, name: String) -> String {
  "%l." <> ctx.prefix <> safe(name)
}

fn block_name_of(blocks: List(ir.Block), label: String) -> String {
  case
    list.find(blocks, fn(block) {
      let ir.Block(l, _, _) = block
      l == label
    })
  {
    Ok(ir.Block(_, _, _)) -> {
      let names = block_names(blocks)
      case dict.get(names, label) {
        Ok(found) -> found
        Error(_) -> "bb0"
      }
    }
    Error(_) -> "bb0"
  }
}

fn block_name(ctx: Ctx, label: String) -> String {
  case dict.get(ctx.blocks, label) {
    Ok(name) -> name
    Error(_) -> "bb_" <> safe(label)
  }
}

fn emit_ops(ctx: Ctx, ops: List(ir.Op), b: Builder) {
  case ops {
    [] -> #(b, Nil)
    [op, ..rest] -> {
      let #(b, _) = emit_op(ctx, op, b)
      emit_ops(ctx, rest, b)
    }
  }
}

fn emit_op(ctx: Ctx, op: ir.Op, b: Builder) {
  case op {
    ir.OpConst(dest, value) -> {
      let #(ty, val, b) = read_literal(ctx, value, b)
      let b = store_local(ctx, dest, ty, val, b)
      #(b, Nil)
    }
    ir.OpBinop(dest, op_name, left, right) -> {
      let #(lty, lv, b) = read_val(ctx, left, b)
      let #(_, rv, b) = read_val(ctx, right, b)
      let oty = operand_type(ctx.by_name, left)
      case
        op_name == "==" || op_name == "!=", is_eq_special_ty(oty)
      {
        True, True -> {
          let eq = eq_call_name(oty)
          let #(c0, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  "
                <> c0
                <> " = call i1 @"
                <> eq
                <> "("
                <> lty
                <> " "
                <> lv
                <> ", "
                <> lty
                <> " "
                <> rv
                <> ")",
            )
          case op_name {
            "==" -> {
              let b = store_local(ctx, dest, "i1", c0, b)
              #(b, Nil)
            }
            _ -> {
              let #(c1, b) = fresh(b)
              let b = emit_line(b, "  " <> c1 <> " = xor i1 " <> c0 <> ", true")
              let b = store_local(ctx, dest, "i1", c1, b)
              #(b, Nil)
            }
          }
        }
        _, _ -> {
          let #(rhs, res_ty) = binop_rhs(op_name, lty, lv, rv)
          let #(tmp, b) = fresh(b)
          let b = emit_line(b, "  " <> tmp <> " = " <> rhs)
          let b = store_local(ctx, dest, res_ty, tmp, b)
          #(b, Nil)
        }
      }
    }
    ir.OpUnop(dest, op_name, operand) -> {
      let #(ty, v, b) = read_val(ctx, operand, b)
      let #(rhs, res_ty) = unop_rhs(op_name, ty, v)
      let #(tmp, b) = fresh(b)
      let b = emit_line(b, "  " <> tmp <> " = " <> rhs)
      let b = store_local(ctx, dest, res_ty, tmp, b)
      #(b, Nil)
    }
    ir.OpCall(dest, fun, args, ret_ty) -> {
      let #(b, arg_list) = read_args(ctx, args, b)
      let ret_s = llvm_ty(ret_ty, ctx.recursive)
      let #(tmp, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> tmp
            <> " = call "
            <> ret_s
            <> " @Gleamc_"
            <> fun
            <> "("
            <> arg_list
            <> ")",
        )
      let b = store_local(ctx, dest, ret_s, tmp, b)
      #(b, Nil)
    }
    ir.OpBuiltin(dest, builtin, args, ret_ty) -> {
      case builtin {
        "gleamc.show" -> {
          let first = first_arg(args)
          let oty = operand_type(ctx.by_name, first)
          let #(_, v, b) = read_val(ctx, first, b)
          let #(r, b) = inspect_val(ctx.recursive, ctx.lits, oty, v, b)
          let b = store_local(ctx, dest, "%GleamcString", r, b)
          #(b, Nil)
        }
        "io.debug" -> {
          let first = first_arg(args)
          let oty = operand_type(ctx.by_name, first)
          let #(_, v, b) = read_val(ctx, first, b)
          let #(s, b) = inspect_val(ctx.recursive, ctx.lits, oty, v, b)
          let #(r, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  "
                <> r
                <> " = call i32 @Gleamc_io_debug(%GleamcString "
                <> s
                <> ")",
            )
          let b = store_local(ctx, dest, "i32", r, b)
          #(b, Nil)
        }
        "gleamc.key_compare" -> {
          let first = first_arg(args)
          let oty = operand_type(ctx.by_name, first)
          let #(ty_s, lv, b) = read_val(ctx, first, b)
          let second = case args {
            [_, s, ..] -> s
            _ -> ir.Lit(ir.LUnit)
          }
          let #(_, rv, b) = read_val(ctx, second, b)
          let #(c32, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  "
                <> c32
                <> " = call i32 @Gleamc_Cmp_"
                <> mangle_glue(oty)
                <> "("
                <> ty_s
                <> " "
                <> lv
                <> ", "
                <> ty_s
                <> " "
                <> rv
                <> ")",
            )
          let ret_s = llvm_ty(ret_ty, ctx.recursive)
          case ret_s {
            "i32" -> {
              let b = store_local(ctx, dest, "i32", c32, b)
              #(b, Nil)
            }
            _ -> {
              let #(r, b) = fresh(b)
              let b =
                emit_line(
                  b,
                  "  " <> r <> " = sext i32 " <> c32 <> " to " <> ret_s,
                )
              let b = store_local(ctx, dest, ret_s, r, b)
              #(b, Nil)
            }
          }
        }
        "panic" -> {
          let first = first_arg(args)
          let #(_, v, b) = read_val(ctx, first, b)
          let b =
            emit_line(b, "  call void @Gleamc_panic(%GleamcString " <> v <> ")")
          let ty_s = llvm_ty(ret_ty, ctx.recursive)
          let b = store_local(ctx, dest, ty_s, "undef", b)
          #(b, Nil)
        }
        _ -> emit_builtin_call(ctx, dest, builtin, args, ret_ty, b)
      }
    }
    ir.OpCopy(dest, src, ty) -> {
      let ty_s = llvm_ty(ty, ctx.recursive)
      let #(_, v, b) = read_val(ctx, src, b)
      let b = store_local(ctx, dest, ty_s, v, b)
      #(b, Nil)
    }
    ir.OpRetain(src, ty) -> {
      let #(ty_s, v, b) = read_val(ctx, ir.Var(src), b)
      #(
        rc_expr(
          ctx.lits,
          ctx.recursive,
          records_ctors(ctx),
          "retain",
          ty,
          ty_s,
          v,
          ctx.fn_name <> ":" <> src,
          b,
        ),
        Nil,
      )
    }
    ir.OpDrop(src, ty) -> {
      let #(ty_s, v, b) = read_val(ctx, ir.Var(src), b)
      #(
        rc_expr(
          ctx.lits,
          ctx.recursive,
          records_ctors(ctx),
          "drop",
          ty,
          ty_s,
          v,
          ctx.fn_name <> ":" <> src,
          b,
        ),
        Nil,
      )
    }
    ir.OpTuple(dest, elems, ty) -> {
      let ty_s = llvm_ty(ty, ctx.recursive)
      let #(b, fields) = read_typed_args(ctx, elems, b)
      let #(val, b) = build_struct(b, ty_s, fields)
      let b = store_local(ctx, dest, ty_s, val, b)
      #(b, Nil)
    }
    ir.OpTupleGet(dest, tuple, index, ty) -> {
      let #(ty_s, v, b) = read_val(ctx, tuple, b)
      let #(tmp, b) = extract_value(ty_s, v, [index], b)
      let b = store_local(ctx, dest, llvm_ty(ty, ctx.recursive), tmp, b)
      #(b, Nil)
    }
    ir.OpCtor(dest, ctor, type_name, args, ty) -> {
      let ty_s = llvm_ty(ty, ctx.recursive)
      let index = variant_index(ctx, ctor, type_name)
      let #(b, fields) = read_typed_args(ctx, args, b)
      let #(base, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> base
            <> " = insertvalue %"
            <> type_name
            <> " undef, i8 "
            <> int.to_string(index)
            <> ", 0",
        )
      let #(val, b) =
        insert_fields("%" <> type_name, base, fields, [index + 1], 0, b)
      case is_recursive(ctx.recursive, type_name) {
        True -> {
          let #(sz, b) = sizeof_reg(type_name, b)
          let #(p, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  "
                <> p
                <> " = call i8* @gleamc_alloc_site(i64 "
                <> sz
                <> ", "
                <> cstring_arg(ctx.lits, "alloc:" <> type_name)
                <> ")",
            )
          let #(tp, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  "
                <> tp
                <> " = bitcast i8* "
                <> p
                <> " to %"
                <> type_name
                <> "*",
            )
          let b =
            emit_line(
              b,
              "  store %"
                <> type_name
                <> " "
                <> val
                <> ", %"
                <> type_name
                <> "* "
                <> tp,
            )
          let b = store_local(ctx, dest, ty_s, tp, b)
          #(b, Nil)
        }
        False -> {
          let b = store_local(ctx, dest, ty_s, val, b)
          #(b, Nil)
        }
      }
    }
    ir.OpTagIs(dest, subject, ctor, type_name) -> {
      let #(sty, sv, b) = subject_struct(ctx, subject, b)
      let #(tag, b) = extract_value(sty, sv, [0], b)
      let index = variant_index(ctx, ctor, type_name)
      let #(tmp, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> tmp <> " = icmp eq i8 " <> tag <> ", " <> int.to_string(index),
        )
      let b = store_local(ctx, dest, "i1", tmp, b)
      #(b, Nil)
    }
    ir.OpField(dest, subject, ctor, index, ty) -> {
      let type_name = case operand_type(ctx.by_name, subject) {
        TNamed(name) -> name
        _ -> ""
      }
      let #(sty, sv, b) = subject_struct(ctx, subject, b)
      let group = variant_index(ctx, ctor, type_name) + 1
      let #(tmp, b) = extract_value(sty, sv, [group, index], b)
      let b = store_local(ctx, dest, llvm_ty(ty, ctx.recursive), tmp, b)
      #(b, Nil)
    }
    ir.OpClosure(dest, code, captures, env_ty, fn_ty) -> {
      let fn_s = llvm_ty(fn_ty, ctx.recursive)
      let cty = code_ty(fn_ty, ctx.recursive)
      let #(env_reg, b) = case captures {
        [] -> #("null", b)
        _ -> {
          let #(b, fields) = read_typed_args(ctx, captures, b)
          let #(sz, b) = sizeof_reg(env_ty, b)
          let #(p, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  "
                <> p
                <> " = call i8* @gleamc_alloc_site(i64 "
                <> sz
                <> ", "
                <> cstring_arg(ctx.lits, "alloc:env")
                <> ")",
            )
          let #(ep, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  " <> ep <> " = bitcast i8* " <> p <> " to %" <> env_ty <> "*",
            )
          let b = store_env_fields(env_ty, ep, fields, 0, b)
          #(p, b)
        }
      }
      let #(c0, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> c0
            <> " = insertvalue "
            <> fn_s
            <> " undef, "
            <> cty
            <> " @"
            <> code
            <> ", 0",
        )
      let #(c1, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> c1
            <> " = insertvalue "
            <> fn_s
            <> " "
            <> c0
            <> ", i8* "
            <> env_reg
            <> ", 1",
        )
      let #(c2, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> c2
            <> " = insertvalue "
            <> fn_s
            <> " "
            <> c1
            <> ", void (i8*)* "
            <> env_drop_ptr(env_ty)
            <> ", 2",
        )
      let b = store_local(ctx, dest, fn_s, c2, b)
      #(b, Nil)
    }
    ir.OpEnvGet(dest, env_ty, index, ty) -> {
      let ty_s = llvm_ty(ty, ctx.recursive)
      let #(envraw, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> envraw <> " = load i8*, i8** " <> local_ptr(ctx, "__env"),
        )
      let #(ep, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> ep <> " = bitcast i8* " <> envraw <> " to %" <> env_ty <> "*",
        )
      let #(fp, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> fp
            <> " = getelementptr %"
            <> env_ty
            <> ", %"
            <> env_ty
            <> "* "
            <> ep
            <> ", i32 0, i32 "
            <> int.to_string(index),
        )
      let #(v, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> v <> " = load " <> ty_s <> ", " <> ty_s <> "* " <> fp,
        )
      let b = store_local(ctx, dest, ty_s, v, b)
      #(b, Nil)
    }
    ir.OpCallIndirect(dest, fval, args, ret_ty) -> {
      let fn_ty = operand_type(ctx.by_name, fval)
      let fn_s = llvm_ty(fn_ty, ctx.recursive)
      let #(_, fv, b) = read_val(ctx, fval, b)
      let #(code, b) = extract_value(fn_s, fv, [0], b)
      let #(env, b) = extract_value(fn_s, fv, [1], b)
      let #(b, arg_list) = read_args(ctx, args, b)
      let ret_s = llvm_ty(ret_ty, ctx.recursive)
      let callargs = case arg_list {
        "" -> "i8* " <> env
        _ -> "i8* " <> env <> ", " <> arg_list
      }
      let #(tmp, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> tmp
            <> " = call "
            <> ret_s
            <> " "
            <> code
            <> "("
            <> callargs
            <> ")",
        )
      let b = store_local(ctx, dest, ret_s, tmp, b)
      #(b, Nil)
    }
    ir.OpBitArray(dest, elems, _ty) -> {
      let n = list.length(elems)
      let b = case elems {
        [] -> {
          let #(r, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  "
                <> r
                <> " = call %GleamcBitArray @Gleamc_bit_array_new(i64 0)",
            )
          store_local(ctx, dest, "%GleamcBitArray", r, b)
        }
        _ -> {
          let arr_ty = "[" <> int.to_string(n) <> " x i64]"
          let #(arr, b) = fresh(b)
          let b = emit_line(b, "  " <> arr <> " = alloca " <> arr_ty)
          let b =
            list.index_fold(elems, b, fn(b, elem, index) {
              let #(_, v, b) = read_val(ctx, elem, b)
              let #(p, b) = fresh(b)
              let b =
                emit_line(
                  b,
                  "  "
                    <> p
                    <> " = getelementptr "
                    <> arr_ty
                    <> ", "
                    <> arr_ty
                    <> "* "
                    <> arr
                    <> ", i32 0, i32 "
                    <> int.to_string(index),
                )
              emit_line(b, "  store i64 " <> v <> ", i64* " <> p)
            })
          let #(ptr, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  "
                <> ptr
                <> " = getelementptr "
                <> arr_ty
                <> ", "
                <> arr_ty
                <> "* "
                <> arr
                <> ", i32 0, i32 0",
            )
          let #(r, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  "
                <> r
                <> " = call %GleamcBitArray @Gleamc_bit_array_from_bytes(i64* "
                <> ptr
                <> ", i64 "
                <> int.to_string(n)
                <> ")",
            )
          store_local(ctx, dest, "%GleamcBitArray", r, b)
        }
      }
      #(b, Nil)
    }
  }
}

fn emit_term(ctx: Ctx, term: ir.Terminator, b: Builder) {
  case term {
    ir.Jmp(label) -> emit_line(b, "  br label %" <> block_name(ctx, label))
    ir.Branch(cond, then, otherwise) -> {
      let #(_, v, b) = read_val(ctx, cond, b)
      emit_line(
        b,
        "  br i1 "
          <> v
          <> ", label %"
          <> block_name(ctx, then)
          <> ", label %"
          <> block_name(ctx, otherwise),
      )
    }
    ir.Ret(value) -> {
      let ret_ty = llvm_ty(ctx.ret, ctx.recursive)
      let #(_, v, b) = read_val(ctx, value, b)
      emit_line(b, "  ret " <> ret_ty <> " " <> v)
    }
    ir.Tailcall(fun, args) -> {
      case dict.get(ctx.group, fun) {
        Ok(target) -> emit_rebind(ctx, target, args, b)
        Error(_) ->
          case fun == ctx.fn_name {
            True ->
              emit_rebind(ctx, #(ctx.prefix, ctx.params, ctx.entry), args, b)
            False -> {
              let ret_s = llvm_ty(ctx.ret, ctx.recursive)
              let #(b, arg_list) = read_args(ctx, args, b)
              let #(r, b) = fresh(b)
              let b =
                emit_line(
                  b,
                  "  "
                    <> r
                    <> " = call "
                    <> ret_s
                    <> " @Gleamc_"
                    <> fun
                    <> "("
                    <> arg_list
                    <> ")",
                )
              emit_line(b, "  ret " <> ret_s <> " " <> r)
            }
          }
      }
    }
    ir.Unreachable -> emit_line(b, "  unreachable")
  }
}

// ---------------------------------------------------------------------------
// operands
// ---------------------------------------------------------------------------

fn read_args(ctx: Ctx, args: List(ir.Operand), b: Builder) {
  case args {
    [] -> #(b, "")
    [arg] -> {
      let #(ty, v, b) = read_val(ctx, arg, b)
      #(b, ty <> " " <> v)
    }
    [arg, ..rest] -> {
      let #(ty, v, b) = read_val(ctx, arg, b)
      let #(b, tail) = read_args(ctx, rest, b)
      #(b, ty <> " " <> v <> ", " <> tail)
    }
  }
}

fn read_val(ctx: Ctx, operand: ir.Operand, b: Builder) {
  case operand {
    ir.Var(name) -> {
      let ty = local_type(ctx.by_name, name)
      let ty_s = llvm_ty(ty, ctx.recursive)
      let #(tmp, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> tmp
            <> " = load "
            <> ty_s
            <> ", "
            <> ty_s
            <> "* "
            <> local_ptr(ctx, name),
        )
      #(ty_s, tmp, b)
    }
    ir.Lit(value) -> read_literal(ctx, value, b)
  }
}

fn read_literal(ctx: Ctx, value: ir.Literal, b: Builder) {
  case value {
    ir.LInt(v) -> #("i64", int.to_string(v), b)
    ir.LFloat(v) -> #("double", float_text(v), b)
    ir.LBool(True) -> #("i1", "true", b)
    ir.LBool(False) -> #("i1", "false", b)
    ir.LUnit -> #("i32", "0", b)
    ir.LString(content) -> {
      let index = literal_index(ctx.lits, content)
      let size = string.byte_size(content) + 1
      let #(t0, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> t0
            <> " = insertvalue %GleamcString undef, i8* getelementptr inbounds ({ i64, ["
            <> int.to_string(size)
            <> " x i8] }, { i64, ["
            <> int.to_string(size)
            <> " x i8] }* @.str."
            <> int.to_string(index)
            <> ", i32 0, i32 1, i64 0), 0",
        )
      let #(t1, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> t1
            <> " = insertvalue %GleamcString "
            <> t0
            <> ", i64 "
            <> int.to_string(string.byte_size(content))
            <> ", 1",
        )
      #("%GleamcString", t1, b)
    }
  }
}

fn store_local(
  ctx: Ctx,
  dest: String,
  ty_s: String,
  val: String,
  b: Builder,
) -> Builder {
  emit_line(
    b,
    "  store "
      <> ty_s
      <> " "
      <> val
      <> ", "
      <> ty_s
      <> "* "
      <> local_ptr(ctx, dest),
  )
}

fn operand_type(by_name: Dict(String, Type), operand: ir.Operand) -> Type {
  case operand {
    ir.Var(name) -> local_type(by_name, name)
    ir.Lit(value) -> literal_type(value)
  }
}

fn literal_type(value: ir.Literal) -> Type {
  case value {
    ir.LInt(_) -> ast.TInt
    ir.LFloat(_) -> ast.TFloat
    ir.LBool(_) -> ast.TBool
    ir.LUnit -> ast.TNil
    ir.LString(_) -> TString
  }
}

fn local_type(by_name: Dict(String, Type), name: String) -> Type {
  case dict.get(by_name, name) {
    Ok(ty) -> ty
    Error(_) -> ast.TNil
  }
}

fn locals_map(locals: List(ir.Local)) -> Dict(String, Type) {
  list.fold(locals, dict.new(), fn(acc, local) {
    let ir.Local(name, ty) = local
    dict.insert(acc, name, ty)
  })
}

// ---------------------------------------------------------------------------
// operators
// ---------------------------------------------------------------------------

fn binop_rhs(op: String, ty: String, left: String, right: String) {
  case op, ty {
    "<>", _ -> #(
      "call %GleamcString @gleamc_string_concat(%GleamcString "
        <> left
        <> ", %GleamcString "
        <> right
        <> ")",
      "%GleamcString",
    )
    "==", "%GleamcString" -> #(
      "call i1 @gleamc_string_eq(%GleamcString "
        <> left
        <> ", %GleamcString "
        <> right
        <> ")",
      "i1",
    )
    "==", "double" -> #("fcmp oeq double " <> left <> ", " <> right, "i1")
    "!=", "double" -> #("fcmp one double " <> left <> ", " <> right, "i1")
    "==", _ -> #("icmp eq " <> ty <> " " <> left <> ", " <> right, "i1")
    "!=", _ -> #("icmp ne " <> ty <> " " <> left <> ", " <> right, "i1")
    "&&", _ -> #("and i1 " <> left <> ", " <> right, "i1")
    "||", _ -> #("or i1 " <> left <> ", " <> right, "i1")
    _, "double" -> float_arith(op, left, right)
    _, _ -> int_arith(op, left, right)
  }
}

fn int_arith(op: String, left: String, right: String) {
  case op {
    "+" -> #("add i64 " <> left <> ", " <> right, "i64")
    "-" -> #("sub i64 " <> left <> ", " <> right, "i64")
    "*" -> #("mul i64 " <> left <> ", " <> right, "i64")
    "/" -> #("sdiv i64 " <> left <> ", " <> right, "i64")
    "%" -> #("srem i64 " <> left <> ", " <> right, "i64")
    "<" -> #("icmp slt i64 " <> left <> ", " <> right, "i1")
    ">" -> #("icmp sgt i64 " <> left <> ", " <> right, "i1")
    "<=" -> #("icmp sle i64 " <> left <> ", " <> right, "i1")
    ">=" -> #("icmp sge i64 " <> left <> ", " <> right, "i1")
    _ -> #("add i64 " <> left <> ", " <> right, "i64")
  }
}

fn float_arith(op: String, left: String, right: String) {
  case op {
    "+." -> #("fadd double " <> left <> ", " <> right, "double")
    "-." -> #("fsub double " <> left <> ", " <> right, "double")
    "*." -> #("fmul double " <> left <> ", " <> right, "double")
    "/." -> #("fdiv double " <> left <> ", " <> right, "double")
    "<." -> #("fcmp olt double " <> left <> ", " <> right, "i1")
    ">." -> #("fcmp ogt double " <> left <> ", " <> right, "i1")
    "<=." -> #("fcmp ole double " <> left <> ", " <> right, "i1")
    ">=." -> #("fcmp oge double " <> left <> ", " <> right, "i1")
    _ -> #("fadd double " <> left <> ", " <> right, "double")
  }
}

fn unop_rhs(op: String, ty: String, v: String) {
  case op {
    "!" -> #("xor i1 " <> v <> ", true", "i1")
    "-" ->
      case ty {
        "double" -> #("fneg double " <> v, "double")
        _ -> #("sub i64 0, " <> v, "i64")
      }
    "-." -> #("fneg double " <> v, "double")
    _ -> #("add i64 0, " <> v, ty)
  }
}

fn float_text(v: Float) -> String {
  let text = float.to_string(v)
  case
    string.contains(text, ".")
    || string.contains(text, "e")
    || string.contains(text, "E")
  {
    True -> text
    False -> text <> ".0"
  }
}

fn sizeof_reg(ty_name: String, b: Builder) {
  let #(p, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  "
        <> p
        <> " = getelementptr %"
        <> ty_name
        <> ", %"
        <> ty_name
        <> "* null, i32 1",
    )
  let #(sz, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  " <> sz <> " = ptrtoint %" <> ty_name <> "* " <> p <> " to i64",
    )
  #(sz, b)
}

fn store_env_fields(
  env_ty: String,
  ep: String,
  fields,
  index: Int,
  b: Builder,
) -> Builder {
  case fields {
    [] -> b
    [#(ty, v), ..rest] -> {
      let #(fp, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> fp
            <> " = getelementptr %"
            <> env_ty
            <> ", %"
            <> env_ty
            <> "* "
            <> ep
            <> ", i32 0, i32 "
            <> int.to_string(index),
        )
      let b =
        emit_line(b, "  store " <> ty <> " " <> v <> ", " <> ty <> "* " <> fp)
      store_env_fields(env_ty, ep, rest, index + 1, b)
    }
  }
}

fn list_at(items: List(String), index: Int) -> Result(String, Nil) {
  case items {
    [] -> Error(Nil)
    [first, ..rest] -> {
      case index {
        0 -> Ok(first)
        _ -> list_at(rest, index - 1)
      }
    }
  }
}

fn records_ctors(ctx: Ctx) -> Dict(String, checker.CtorInfo) {
  ctx.ctors
}

fn first_arg(args: List(ir.Operand)) -> ir.Operand {
  case args {
    [first, ..] -> first
    [] -> ir.Lit(ir.LUnit)
  }
}

fn runtime_declared(name: String) -> Bool {
  case name {
    "Gleamc_set_args"
    | "gleamc_alloc"
    | "gleamc_string_lit"
    | "Gleamc_show_concat"
    | "Gleamc_int_to_string"
    | "Gleamc_float_to_string"
    | "Gleamc_bool_to_string"
    | "Gleamc_string_show"
    | "Gleamc_panic"
    | "Gleamc_io_debug"
    | "Gleamc_string_compare_bytes"
    | "gleamc_string_concat"
    | "gleamc_string_eq"
    | "Gleamc_bit_array_eq"
    | "Gleamc_bit_array_new"
    | "Gleamc_bit_array_from_bytes"
    | "Gleamc_rc_retain"
    | "Gleamc_rc_release"
    | "gleamc_alloc_site" -> True
    _ -> False
  }
}

fn is_file_result(ty: Type) -> Bool {
  case ty {
    TNamed("FileResult") -> True
    _ -> False
  }
}

/// Runtime functions that return or take `GleamcFileResult` (a 32-byte
/// aggregate) use the C ABI: `sret` for the result and `byval` pointers for
/// arguments. Emitting them by value would mismatch clang's lowering.
fn builtin_arg_ty(by_name, recursive, arg) -> String {
  let ty = operand_type(by_name, arg)
  case is_file_result(ty) {
    True -> "ptr byval(%GleamcFileResult)"
    False -> llvm_ty(ty, recursive)
  }
}

fn builtin_decl(builtin, ret_ty, args, by_name, recursive) -> String {
  let name = "Gleamc_" <> string.replace(builtin, ".", "_")
  let arg_str =
    string.join(
      list.map(args, fn(arg) { builtin_arg_ty(by_name, recursive, arg) }),
      ", ",
    )
  case is_file_result(ret_ty) {
    True ->
      "declare void @"
      <> name
      <> "(ptr sret(%GleamcFileResult)"
      <> case arg_str {
        "" -> ""
        _ -> ", " <> arg_str
      }
      <> ")"
    False ->
      "declare "
      <> llvm_ty(ret_ty, recursive)
      <> " @"
      <> name
      <> "("
      <> arg_str
      <> ")"
  }
}

fn emit_builtin_call(ctx: Ctx, dest, builtin, args, ret_ty, b) {
  let name = "Gleamc_" <> string.replace(builtin, ".", "_")
  let ret_s = llvm_ty(ret_ty, ctx.recursive)
  let sret = is_file_result(ret_ty)
  let #(b, rev_parts) =
    list.fold(args, #(b, []), fn(acc, arg) {
      let #(b, parts) = acc
      let oty = operand_type(ctx.by_name, arg)
      case is_file_result(oty) {
        True -> {
          let #(_, v, b) = read_val(ctx, arg, b)
          let #(slot, b) = fresh(b)
          let b = emit_line(b, "  " <> slot <> " = alloca %GleamcFileResult")
          let b =
            emit_line(
              b,
              "  store %GleamcFileResult "
                <> v
                <> ", %GleamcFileResult* "
                <> slot,
            )
          #(b, ["ptr byval(%GleamcFileResult) " <> slot, ..parts])
        }
        False -> {
          let #(ty_s, v, b) = read_val(ctx, arg, b)
          #(b, [ty_s <> " " <> v, ..parts])
        }
      }
    })
  let arg_list = string.join(list.reverse(rev_parts), ", ")
  case sret {
    True -> {
      let b =
        emit_line(
          b,
          "  call void @"
          <> name
          <> "(ptr sret(%GleamcFileResult) "
          <> local_ptr(ctx, dest)
          <> case arg_list {
            "" -> ""
            _ -> ", " <> arg_list
          }
          <> ")",
        )
      #(b, Nil)
    }
    False -> {
      let #(tmp, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
          <> tmp
          <> " = call "
          <> ret_s
          <> " @"
          <> name
          <> "("
          <> arg_list
          <> ")",
        )
      let b = store_local(ctx, dest, ret_s, tmp, b)
      #(b, Nil)
    }
  }
}

fn special_builtin(name: String) -> Bool {
  case name {
    "gleamc.show" | "io.debug" | "gleamc.key_compare" | "panic" -> True
    _ -> False
  }
}

fn read_typed_args(ctx: Ctx, args: List(ir.Operand), b: Builder) {
  case args {
    [] -> #(b, [])
    [arg, ..rest] -> {
      let #(ty, v, b) = read_val(ctx, arg, b)
      let #(b, tail) = read_typed_args(ctx, rest, b)
      #(b, [#(ty, v), ..tail])
    }
  }
}

fn build_struct(b: Builder, ty_s: String, fields: List(#(String, String))) {
  case fields {
    [] -> #("undef", b)
    [#(ty, v), ..rest] -> {
      let #(tmp, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> tmp
            <> " = insertvalue "
            <> ty_s
            <> " undef, "
            <> ty
            <> " "
            <> v
            <> ", 0",
        )
      insert_fields(ty_s, tmp, rest, [], 1, b)
    }
  }
}

fn insert_fields(ty_s, base, fields, prefix: List(Int), index: Int, b) {
  case fields {
    [] -> #(base, b)
    [#(ty, v), ..rest] -> {
      let #(tmp, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> tmp
            <> " = insertvalue "
            <> ty_s
            <> " "
            <> base
            <> ", "
            <> ty
            <> " "
            <> v
            <> ", "
            <> string.join(
            list.map(list.append(prefix, [index]), fn(i) { int.to_string(i) }),
            ", ",
          ),
        )
      insert_fields(ty_s, tmp, rest, prefix, index + 1, b)
    }
  }
}

fn code_ty(fn_ty: Type, recursive: Dict(String, Bool)) -> String {
  case fn_ty {
    ast.TFun(params, ret) -> {
      let args = case params {
        [] -> "i8*"
        _ ->
          "i8*, "
          <> string.join(
            list.map(params, fn(param) { llvm_ty(param, recursive) }),
            ", ",
          )
      }
      llvm_ty(ret, recursive) <> " (" <> args <> ")*"
    }
    _ -> "void ()*"
  }
}

fn fn_type_decl(fn_ty: Type, recursive: Dict(String, Bool)) -> String {
  case fn_ty {
    ast.TFun(_, _) ->
      "%GleamFn_"
      <> mangle_type(fn_ty)
      <> " = type { "
      <> code_ty(fn_ty, recursive)
      <> ", i8*, void (i8*)* }"
    _ -> ""
  }
}

fn env_type_decl(entry, recursive: Dict(String, Bool)) -> String {
  let #(name, field_types) = entry
  let fields = list.map(field_types, fn(ty) { llvm_ty(ty, recursive) })
  "%" <> name <> " = type { " <> string.join(fields, ", ") <> " }"
}

fn collect_env_structs(
  functions: List(ir.Function),
) -> List(#(String, List(Type))) {
  let entries =
    list.fold(functions, dict.new(), fn(acc: Dict(String, List(Type)), function) {
      let by_name = locals_map(local_list(function))
      list.fold(op_list(function), acc, fn(acc, op) {
        case op {
          ir.OpClosure(_, _, captures, env_ty, _) ->
            case env_ty {
              "" -> acc
              _ ->
                case dict.get(acc, env_ty) {
                  Ok(_) -> acc
                  Error(_) ->
                    dict.insert(acc, env_ty, list.map(captures, fn(cap) {
                      operand_type(by_name, cap)
                    }))
                }
            }
          _ -> acc
        }
      })
    })
  dict.to_list(entries)
}

fn collect_fn_types(
  custom_types: List(ast.CustomType),
  functions: List(ir.Function),
) -> List(Type) {
  let from_custom =
    list.flat_map(custom_types, fn(custom) {
      let ast.CustomType(_, _, _, variants, _) = custom
      list.flat_map(variants, fn(variant) {
        let ast.Variant(_, fields) = variant
        list.flat_map(fields, fn(field) {
          let #(_, ty) = field
          fn_types_in(ty)
        })
      })
    })
  let from_fns =
    list.flat_map(functions, fn(function) {
      let ir.Function(_, _, ret, blocks, locals) = function
      let from_locals =
        list.flat_map(locals, fn(local) {
          let ir.Local(_, ty) = local
          fn_types_in(ty)
        })
      let from_ops =
        list.flat_map(blocks, fn(block) {
          let ir.Block(_, ops, _) = block
          list.flat_map(ops, fn(op) { list.flat_map(op_types(op), fn_types_in) })
        })
      list.append(fn_types_in(ret), list.append(from_locals, from_ops))
    })
  dedupe_types(list.append(from_custom, from_fns), dict.new(), [])
}

fn fn_types_in(ty: Type) -> List(Type) {
  case ty {
    ast.TFun(params, ret) -> [
      ty,
      ..list.append(list.flat_map(params, fn_types_in), fn_types_in(ret))
    ]
    ast.TTuple(types) -> list.flat_map(types, fn_types_in)
    ast.TApp(_, args) -> list.flat_map(args, fn_types_in)
    _ -> []
  }
}

fn local_list(function: ir.Function) -> List(ir.Local) {
  let ir.Function(_, _, _, _, locals) = function
  locals
}

fn op_list(function: ir.Function) -> List(ir.Op) {
  let ir.Function(_, _, _, blocks, _) = function
  list.flat_map(blocks, fn(block) {
    let ir.Block(_, ops, _) = block
    ops
  })
}

fn collect_wrappers(functions: List(ir.Function), recursive) -> List(String) {
  let by_name =
    list.fold(functions, dict.new(), fn(acc, f) { dict.insert(acc, f.name, f) })
  let codes =
    list.flat_map(functions, fn(function) {
      list.filter_map(op_list(function), fn(op) {
        case op {
          ir.OpClosure(_, code, _, "", _) -> Ok(code)
          _ -> Error(Nil)
        }
      })
    })
    |> dedupe_strings
    |> list.filter_map(fn(code) {
      case string.starts_with(code, "__gv_") {
        True -> Ok(code)
        False -> Error(Nil)
      }
    })
  list.map(codes, fn(code) {
    let name = string.slice(code, 5, string.length(code))
    case dict.get(by_name, name) {
      Ok(function) -> wrapper_def(function, code, recursive)
      Error(_) -> ""
    }
  })
}

fn dedupe_strings(items: List(String)) -> List(String) {
  dedupe(items, dict.new(), [])
}

fn wrapper_def(function: ir.Function, code: String, recursive) -> String {
  let ir.Function(name, params, ret, _, locals) = function
  let by_name = locals_map(locals)
  let decls =
    list.index_map(params, fn(param, index) {
      llvm_ty(local_type(by_name, param), recursive)
      <> " %a"
      <> int.to_string(index)
    })
  let args =
    string.join(
      list.index_map(params, fn(_, index) { "%a" <> int.to_string(index) }),
      ", ",
    )
  let ret_s = llvm_ty(ret, recursive)
  let lines = case ret_s {
    "i32" ->
      "  call "
      <> ret_s
      <> " @Gleamc_"
      <> name
      <> "("
      <> args
      <> ")\n  ret i32 0"
    _ ->
      "  %r = call "
      <> ret_s
      <> " @Gleamc_"
      <> name
      <> "("
      <> args
      <> ")\n  ret "
      <> ret_s
      <> " %r"
  }
  "define "
  <> ret_s
  <> " @"
  <> code
  <> "(i8* %env"
  <> case decls {
    [] -> ""
    _ -> ", " <> string.join(decls, ", ")
  }
  <> ") {\n"
  <> lines
  <> "\n}"
}

fn mangle_glue(ty: Type) -> String {
  case ty {
    ast.TTuple(types) ->
      "tuple_" <> string.join(list.map(types, mangle_type), "_")
    TNamed(name) -> name
    _ -> mangle_type(ty)
  }
}

fn eq_name_ty(ty: Type) -> String {
  "Gleamc_Eq_" <> mangle_glue(ty)
}

fn is_eq_special_ty(ty: Type) -> Bool {
  case ty {
    TString | TNamed("BitArray") -> True
    _ -> is_eq_aggregate_ty(ty)
  }
}

fn eq_call_name(ty: Type) -> String {
  case ty {
    TString -> "gleamc_string_eq"
    TNamed("BitArray") -> "Gleamc_bit_array_eq"
    _ -> eq_name_ty(ty)
  }
}

fn is_eq_aggregate_ty(ty: Type) -> Bool {
  case ty {
    TString | ast.TInt | ast.TFloat | ast.TBool | ast.TNil -> False
    TNamed("Nil") | TNamed("BitArray") | TNamed("void*") -> False
    TNamed(_) | ast.TTuple(_) | ast.TFun(_, _) | ast.TApp(_, _) -> True
    _ -> False
  }
}

fn variant_fields_of(
  custom_types: List(ast.CustomType),
  type_name: String,
) -> List(#(String, List(Type))) {
  case
    list.find(custom_types, fn(custom) {
      let ast.CustomType(_, n, _, _, _) = custom
      n == type_name
    })
  {
    Ok(custom) -> {
      let ast.CustomType(_, _, _, variants, _) = custom
      list.map(variants, fn(variant) {
        let ast.Variant(vn, fields) = variant
        #(
          base_ctor_name(vn, type_name),
          list.map(fields, fn(field) {
            let #(_, field_ty) = field
            field_ty
          }),
        )
      })
    }
    Error(_) -> []
  }
}

fn emit_eq_glue(
  recursive: Dict(String, Bool),
  custom_types: List(ast.CustomType),
  ty: Type,
) -> String {
  let ty_s = llvm_ty(ty, recursive)
  let name = eq_name_ty(ty)
  let b = Builder(next: 0, lines: [])
  let b =
    emit_line(
      b,
      "define i1 @" <> name <> "(" <> ty_s <> " %a, " <> ty_s <> " %b) {",
    )
  let #(b, _) = eq_body(recursive, custom_types, ty, ty_s, b)
  let lines = list.reverse(b.lines)
  string.join(lines, "\n") <> "\n}\n"
}

fn eq_body(recursive, custom_types, ty, ty_s, b) {
  case ty {
    ast.TFun(_, _) -> {
      let #(ac, b) = extract_value(ty_s, "%a", [0], b)
      let #(bc, b) = extract_value(ty_s, "%b", [0], b)
      let #(c0, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> c0
            <> " = icmp eq "
            <> code_ty(ty, recursive)
            <> " "
            <> ac
            <> ", "
            <> bc,
        )
      let #(ae, b) = extract_value(ty_s, "%a", [1], b)
      let #(be, b) = extract_value(ty_s, "%b", [1], b)
      let #(c1, b) = fresh(b)
      let b = emit_line(b, "  " <> c1 <> " = icmp eq i8* " <> ae <> ", " <> be)
      let #(r, b) = fresh(b)
      let b = emit_line(b, "  " <> r <> " = and i1 " <> c0 <> ", " <> c1)
      let b = emit_line(b, "  ret i1 " <> r)
      #(b, Nil)
    }
    ast.TTuple(types) -> {
      let #(acc, b) =
        compare_fields(
          recursive,
          "%" <> "GleamcTuple_" <> tuple_suffix(types),
          "%a",
          "%b",
          types,
          [],
          0,
          b,
        )
      let b = emit_line(b, "  ret i1 " <> acc)
      #(b, Nil)
    }
    TNamed(type_name) ->
      eq_named(recursive, custom_types, ty, type_name, ty_s, b)
    _ -> {
      let b = emit_line(b, "  ret i1 true")
      #(b, Nil)
    }
  }
}

fn eq_named(recursive, custom_types, _ty, type_name, ty_s, b) {
  let is_rec = is_recursive(recursive, type_name)
  let struct_ty = "%" <> type_name
  let b = case is_rec {
    True -> {
      let #(an, b) = fresh(b)
      let b = emit_line(b, "  " <> an <> " = icmp eq " <> ty_s <> " %a, null")
      let #(bn, b) = fresh(b)
      let b = emit_line(b, "  " <> bn <> " = icmp eq " <> ty_s <> " %b, null")
      let #(both, b) = fresh(b)
      let b = emit_line(b, "  " <> both <> " = and i1 " <> an <> ", " <> bn)
      let b =
        emit_line(b, "  br i1 " <> both <> ", label %eqtrue, label %eqnotboth")
      let b = emit_line(b, "\neqnotboth:")
      let #(either, b) = fresh(b)
      let b = emit_line(b, "  " <> either <> " = or i1 " <> an <> ", " <> bn)
      let b =
        emit_line(b, "  br i1 " <> either <> ", label %eqfalse, label %eqbody")
      let b = emit_line(b, "\neqbody:")
      let #(av, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> av <> " = load " <> struct_ty <> ", " <> ty_s <> " %a",
        )
      let #(bv, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> bv <> " = load " <> struct_ty <> ", " <> ty_s <> " %b",
        )
      #(av, bv, b)
    }
    False -> #("%a", "%b", b)
  }
  let #(av, bv, b) = b
  let #(at, b) = extract_value(struct_ty, av, [0], b)
  let #(bt, b) = extract_value(struct_ty, bv, [0], b)
  let #(ne, b) = fresh(b)
  let b = emit_line(b, "  " <> ne <> " = icmp ne i8 " <> at <> ", " <> bt)
  let b = emit_line(b, "  br i1 " <> ne <> ", label %eqfalse, label %eqswitch")
  let b = emit_line(b, "\neqfalse:")
  let b = emit_line(b, "  ret i1 false")
  let b = emit_line(b, "\neqtrue:")
  let b = emit_line(b, "  ret i1 true")
  let b = emit_line(b, "\neqswitch:")
  let variants = variant_fields_of(custom_types, type_name)
  let arms =
    list.index_map(variants, fn(variant, index) {
      let #(_, _) = variant
      " i8 " <> int.to_string(index) <> ", label %eqv" <> int.to_string(index)
    })
  let b =
    emit_line(
      b,
      "  switch i8 "
        <> at
        <> ", label %eqtrue ["
        <> string.join(arms, "")
        <> " ]",
    )
  let b =
    list.fold(
      list.index_map(variants, fn(variant, index) { #(index, variant) }),
      b,
      fn(b, entry) {
        let #(index, variant) = entry
        let #(_, fields) = variant
        let b = emit_line(b, "\neqv" <> int.to_string(index) <> ":")
        let #(acc, b) =
          compare_fields(
            recursive,
            struct_ty,
            av,
            bv,
            fields,
            [index + 1],
            0,
            b,
          )
        emit_line(b, "  ret i1 " <> acc)
      },
    )
  #(b, Nil)
}

fn compare_fields(
  recursive,
  struct_ty,
  av,
  bv,
  fields,
  prefix: List(Int),
  index: Int,
  b,
) {
  case fields {
    [] -> #("true", b)
    [ty, ..rest] -> {
      let idxs = list.append(prefix, [index])
      let #(lv, b) = extract_value(struct_ty, av, idxs, b)
      let #(rv, b) = extract_value(struct_ty, bv, idxs, b)
      let #(e, b) = eq_expr(recursive, ty, lv, rv, b)
      let #(ar, b) =
        compare_fields(recursive, struct_ty, av, bv, rest, prefix, index + 1, b)
      case ar {
        "true" -> #(e, b)
        _ -> {
          let #(r, b) = fresh(b)
          let b = emit_line(b, "  " <> r <> " = and i1 " <> e <> ", " <> ar)
          #(r, b)
        }
      }
    }
  }
}

fn eq_expr(recursive, ty, left, right, b) {
  case ty {
    TString -> {
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> r
            <> " = call i1 @gleamc_string_eq(%GleamcString "
            <> left
            <> ", %GleamcString "
            <> right
            <> ")",
        )
      #(r, b)
    }
    TNamed("BitArray") -> {
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> r
            <> " = call i1 @Gleamc_bit_array_eq(%GleamcBitArray "
            <> left
            <> ", %GleamcBitArray "
            <> right
            <> ")",
        )
      #(r, b)
    }
    ast.TInt -> {
      let #(r, b) = fresh(b)
      let b =
        emit_line(b, "  " <> r <> " = icmp eq i64 " <> left <> ", " <> right)
      #(r, b)
    }
    ast.TFloat -> {
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> r <> " = fcmp oeq double " <> left <> ", " <> right,
        )
      #(r, b)
    }
    ast.TBool -> {
      let #(r, b) = fresh(b)
      let b =
        emit_line(b, "  " <> r <> " = icmp eq i1 " <> left <> ", " <> right)
      #(r, b)
    }
    ast.TNil | TNamed("Nil") -> {
      let #(r, b) = fresh(b)
      let b =
        emit_line(b, "  " <> r <> " = icmp eq i32 " <> left <> ", " <> right)
      #(r, b)
    }
    ast.TFun(_, _) -> {
      let ty_s = llvm_ty(ty, recursive)
      let #(ac, b) = extract_value(ty_s, left, [0], b)
      let #(bc, b) = extract_value(ty_s, right, [0], b)
      let #(c0, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> c0
            <> " = icmp eq "
            <> code_ty(ty, recursive)
            <> " "
            <> ac
            <> ", "
            <> bc,
        )
      let #(ae, b) = extract_value(ty_s, left, [1], b)
      let #(be, b) = extract_value(ty_s, right, [1], b)
      let #(c1, b) = fresh(b)
      let b = emit_line(b, "  " <> c1 <> " = icmp eq i8* " <> ae <> ", " <> be)
      let #(r, b) = fresh(b)
      let b = emit_line(b, "  " <> r <> " = and i1 " <> c0 <> ", " <> c1)
      #(r, b)
    }
    _ -> {
      let ty_s = llvm_ty(ty, recursive)
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> r
            <> " = call i1 @"
            <> eq_name_ty(ty)
            <> "("
            <> ty_s
            <> " "
            <> left
            <> ", "
            <> ty_s
            <> " "
            <> right
            <> ")",
        )
      #(r, b)
    }
  }
}

fn glue_literals(custom_types: List(ast.CustomType)) -> List(String) {
  list.append(
    ["#(", "(", ")", ", ", "[", "]", "Nil", "<function>", "?"],
    list.flat_map(custom_types, fn(custom) {
      let ast.CustomType(_, name, _, variants, _) = custom
      list.map(variants, fn(variant) {
        let ast.Variant(vn, _) = variant
        base_ctor_name(vn, name)
      })
    }),
  )
}

fn literal_struct(lits, content: String, b: Builder) {
  let index = literal_index(lits, content)
  let size = string.byte_size(content) + 1
  let #(t0, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  "
        <> t0
        <> " = insertvalue %GleamcString undef, i8* getelementptr inbounds ({ i64, ["
        <> int.to_string(size)
        <> " x i8] }, { i64, ["
        <> int.to_string(size)
        <> " x i8] }* @.str."
        <> int.to_string(index)
        <> ", i32 0, i32 1, i64 0), 0",
    )
  let #(t1, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  "
        <> t1
        <> " = insertvalue %GleamcString "
        <> t0
        <> ", i64 "
        <> int.to_string(string.byte_size(content))
        <> ", 1",
    )
  #(t1, b)
}

fn concat_ss(b: Builder, x: String, y: String) {
  let #(r, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  "
        <> r
        <> " = call %GleamcString @Gleamc_show_concat(%GleamcString "
        <> x
        <> ", %GleamcString "
        <> y
        <> ")",
    )
  #(r, b)
}

fn inspect_val(recursive, lits, ty: Type, val: String, b: Builder) {
  case ty {
    ast.TFun(_, _) -> literal_struct(lits, "<function>", b)
    _ -> {
      let ty_s = llvm_ty(ty, recursive)
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> r
            <> " = call %GleamcString @Gleamc_Inspect_"
            <> mangle_glue(ty)
            <> "("
            <> ty_s
            <> " "
            <> val
            <> ")",
        )
      #(r, b)
    }
  }
}

fn emit_show_glue(recursive, custom_types, lits, ty) -> String {
  let ty_s = llvm_ty(ty, recursive)
  let name = "Gleamc_Inspect_" <> mangle_glue(ty)
  let b = Builder(next: 0, lines: [])
  let b =
    emit_line(b, "define %GleamcString @" <> name <> "(" <> ty_s <> " %a) {")
  let #(b, _) = show_body(recursive, custom_types, lits, ty, ty_s, b)
  let lines = list.reverse(b.lines)
  string.join(lines, "\n") <> "\n}\n"
}

fn show_body(recursive, custom_types, lits, ty, ty_s, b) {
  case ty {
    ast.TInt -> {
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> r <> " = call %GleamcString @Gleamc_int_to_string(i64 %a)",
        )
      #(emit_line(b, "  ret %GleamcString " <> r), Nil)
    }
    ast.TFloat -> {
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> r
            <> " = call %GleamcString @Gleamc_float_to_string(double %a)",
        )
      #(emit_line(b, "  ret %GleamcString " <> r), Nil)
    }
    ast.TBool -> {
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> r <> " = call %GleamcString @Gleamc_bool_to_string(i1 %a)",
        )
      #(emit_line(b, "  ret %GleamcString " <> r), Nil)
    }
    TString -> {
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> r
            <> " = call %GleamcString @Gleamc_string_show(%GleamcString %a)",
        )
      #(emit_line(b, "  ret %GleamcString " <> r), Nil)
    }
    ast.TNil | TNamed("Nil") -> {
      let #(r, b) = literal_struct(lits, "Nil", b)
      #(emit_line(b, "  ret %GleamcString " <> r), Nil)
    }
    ast.TFun(_, _) -> {
      let #(r, b) = literal_struct(lits, "<function>", b)
      #(emit_line(b, "  ret %GleamcString " <> r), Nil)
    }
    ast.TTuple(types) -> show_tuple(recursive, lits, ty_s, types, b)
    TNamed("BitArray") -> {
      let #(r, b) = literal_struct(lits, "?", b)
      #(emit_line(b, "  ret %GleamcString " <> r), Nil)
    }
    TNamed(type_name) ->
      case list_info(custom_types, type_name) {
        Ok(info) -> show_list(recursive, lits, type_name, info, b)
        Error(_) -> show_adt(recursive, custom_types, lits, type_name, ty_s, b)
      }
    _ -> {
      let #(r, b) = literal_struct(lits, "?", b)
      #(emit_line(b, "  ret %GleamcString " <> r), Nil)
    }
  }
}

fn show_tuple(recursive, lits, ty_s, types, b) -> #(Builder, Nil) {
  let #(r0, b) = literal_struct(lits, "#(", b)
  let #(r, b) = show_tuple_fields(recursive, lits, ty_s, types, 0, r0, b)
  let #(cl, b) = literal_struct(lits, ")", b)
  let #(r, b) = concat_ss(b, r, cl)
  #(emit_line(b, "  ret %GleamcString " <> r), Nil)
}

fn show_tuple_fields(
  recursive,
  lits,
  ty_s,
  types,
  index: Int,
  r: String,
  b: Builder,
) -> #(String, Builder) {
  case types {
    [] -> #(r, b)
    [inner, ..rest] -> {
      let #(r, b) = case index {
        0 -> #(r, b)
        _ -> {
          let #(sep, b) = literal_struct(lits, ", ", b)
          concat_ss(b, r, sep)
        }
      }
      let #(fv, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> fv
            <> " = extractvalue "
            <> ty_s
            <> " %a, "
            <> int.to_string(index),
        )
      let #(sv, b) = inspect_val(recursive, lits, inner, fv, b)
      let #(r, b) = concat_ss(b, r, sv)
      show_tuple_fields(recursive, lits, ty_s, rest, index + 1, r, b)
    }
  }
}

fn list_info(custom_types, type_name) {
  let variants = variant_fields_of(custom_types, type_name)
  case
    list.find(variants, fn(variant) {
      let #(base, _) = variant
      string.starts_with(base, "ListCons")
    })
  {
    Ok(variant) -> {
      let #(cons, fields) = variant
      case fields {
        [head, tail] -> Ok(#(cons, head, tail))
        _ -> Error(Nil)
      }
    }
    Error(_) -> Error(Nil)
  }
}

fn show_adt(recursive, custom_types, lits, type_name, ty_s, b) {
  let is_rec = is_recursive(recursive, type_name)
  let struct_ty = "%" <> type_name
  let #(av, b) = case is_rec {
    True -> {
      let #(v, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> v <> " = load " <> struct_ty <> ", " <> ty_s <> " %a",
        )
      #(v, b)
    }
    False -> #("%a", b)
  }
  let #(at, b) = extract_value(struct_ty, av, [0], b)
  let variants = variant_fields_of(custom_types, type_name)
  let arms =
    list.index_map(variants, fn(_, index) {
      " i8 " <> int.to_string(index) <> ", label %v" <> int.to_string(index)
    })
  let b =
    emit_line(
      b,
      "  switch i8 "
        <> at
        <> ", label %vfall ["
        <> string.join(arms, "")
        <> " ]",
    )
  let b =
    list.fold(
      list.index_map(variants, fn(variant, index) { #(index, variant) }),
      b,
      fn(b, entry) {
        let #(index, variant) = entry
        let #(base, fields) = variant
        let b = emit_line(b, "\nv" <> int.to_string(index) <> ":")
        let #(r0, b) = literal_struct(lits, base, b)
        case fields {
          [] -> emit_line(b, "  ret %GleamcString " <> r0)
          _ -> {
            let #(open, b) = literal_struct(lits, "(", b)
            let #(r, b) = concat_ss(b, r0, open)
            let #(r, b) =
              show_adt_fields(
                recursive,
                lits,
                struct_ty,
                av,
                index + 1,
                fields,
                0,
                r,
                b,
              )
            let #(close, b) = literal_struct(lits, ")", b)
            let #(r, b) = concat_ss(b, r, close)
            emit_line(b, "  ret %GleamcString " <> r)
          }
        }
      },
    )
  let b = emit_line(b, "\nvfall:")
  let #(q, b) = literal_struct(lits, "?", b)
  let b = emit_line(b, "  ret %GleamcString " <> q)
  #(b, Nil)
}

fn show_adt_fields(
  recursive,
  lits,
  struct_ty,
  av,
  group: Int,
  fields,
  index: Int,
  r: String,
  b: Builder,
) -> #(String, Builder) {
  case fields {
    [] -> #(r, b)
    [inner, ..rest] -> {
      let #(r, b) = case index {
        0 -> #(r, b)
        _ -> {
          let #(sep, b) = literal_struct(lits, ", ", b)
          concat_ss(b, r, sep)
        }
      }
      let #(fv, b) = extract_value(struct_ty, av, [group, index], b)
      let #(sv, b) = inspect_val(recursive, lits, inner, fv, b)
      let #(r, b) = concat_ss(b, r, sv)
      show_adt_fields(
        recursive,
        lits,
        struct_ty,
        av,
        group,
        rest,
        index + 1,
        r,
        b,
      )
    }
  }
}

fn show_list(recursive, lits, type_name, info, b) {
  let #(cons, head_ty, _tail_ty) = info
  let struct_ty = "%" <> type_name
  let ptr_ty = "%" <> type_name <> "*"
  let cons_index = variant_index_of_type(lits, type_name, cons)
  let _ = cons_index
  let b = emit_line(b, "  %lr = alloca %GleamcString")
  let b = emit_line(b, "  %lcur = alloca " <> ptr_ty)
  let b = emit_line(b, "  %lfirst = alloca i1")
  let b = emit_line(b, "  store " <> ptr_ty <> " %a, " <> ptr_ty <> "* %lcur")
  let b = emit_line(b, "  store i1 true, i1* %lfirst")
  let #(s0, b) = literal_struct(lits, "[", b)
  let b = emit_line(b, "  store %GleamcString " <> s0 <> ", %GleamcString* %lr")
  let b = emit_line(b, "  br label %lloop")
  let b = emit_line(b, "\nlloop:")
  let #(cv, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  " <> cv <> " = load " <> ptr_ty <> ", " <> ptr_ty <> "* %lcur",
    )
  let #(isnull, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  " <> isnull <> " = icmp eq " <> ptr_ty <> " " <> cv <> ", null",
    )
  let b = emit_line(b, "  br i1 " <> isnull <> ", label %ldone, label %lcheck")
  let b = emit_line(b, "\nlcheck:")
  let #(sv, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  " <> sv <> " = load " <> struct_ty <> ", " <> ptr_ty <> " " <> cv,
    )
  let #(tag, b) = extract_value(struct_ty, sv, [0], b)
  let #(iscons, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  "
        <> iscons
        <> " = icmp eq i8 "
        <> tag
        <> ", "
        <> int.to_string(cons_index),
    )
  let b = emit_line(b, "  br i1 " <> iscons <> ", label %lbody, label %ldone")
  let b = emit_line(b, "\nlbody:")
  let #(fst, b) = fresh(b)
  let b = emit_line(b, "  " <> fst <> " = load i1, i1* %lfirst")
  let b = emit_line(b, "  br i1 " <> fst <> ", label %lnofirst, label %lsep")
  let b = emit_line(b, "\nlsep:")
  let #(rp, b) = fresh(b)
  let b =
    emit_line(b, "  " <> rp <> " = load %GleamcString, %GleamcString* %lr")
  let #(sepl, b) = literal_struct(lits, ", ", b)
  let #(r1, b) = concat_ss(b, rp, sepl)
  let b = emit_line(b, "  store %GleamcString " <> r1 <> ", %GleamcString* %lr")
  let b = emit_line(b, "  br label %lnofirst")
  let b = emit_line(b, "\nlnofirst:")
  let b = emit_line(b, "  store i1 false, i1* %lfirst")
  let #(sv2, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  " <> sv2 <> " = load " <> struct_ty <> ", " <> ptr_ty <> " " <> cv,
    )
  let #(head, b) = extract_value(struct_ty, sv2, [cons_index + 1, 0], b)
  let #(hs, b) = inspect_val(recursive, lits, head_ty, head, b)
  let #(rp2, b) = fresh(b)
  let b =
    emit_line(b, "  " <> rp2 <> " = load %GleamcString, %GleamcString* %lr")
  let #(r2, b) = concat_ss(b, rp2, hs)
  let b = emit_line(b, "  store %GleamcString " <> r2 <> ", %GleamcString* %lr")
  let #(sv3, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  " <> sv3 <> " = load " <> struct_ty <> ", " <> ptr_ty <> " " <> cv,
    )
  let #(tail, b) = extract_value(struct_ty, sv3, [cons_index + 1, 1], b)
  let b =
    emit_line(
      b,
      "  store " <> ptr_ty <> " " <> tail <> ", " <> ptr_ty <> "* %lcur",
    )
  let b = emit_line(b, "  br label %lloop")
  let b = emit_line(b, "\nldone:")
  let #(rp3, b) = fresh(b)
  let b =
    emit_line(b, "  " <> rp3 <> " = load %GleamcString, %GleamcString* %lr")
  let #(cl, b) = literal_struct(lits, "]", b)
  let #(r3, b) = concat_ss(b, rp3, cl)
  let b = emit_line(b, "  ret %GleamcString " <> r3)
  #(b, Nil)
}

fn variant_index_of_type(_lits, type_name, base) -> Int {
  // The list constructor is always the first variant in the custom type's
  // declaration order; the group index in the struct is variant index + 1.
  // Cons is index 0 for List types (Nil is index 1).
  let _ = type_name
  let _ = base
  0
}

fn emit_cmp_glue(recursive, custom_types, ty) -> String {
  let ty_s = llvm_ty(ty, recursive)
  let name = "Gleamc_Cmp_" <> mangle_glue(ty)
  let b = Builder(next: 0, lines: [])
  let b =
    emit_line(
      b,
      "define i32 @" <> name <> "(" <> ty_s <> " %a, " <> ty_s <> " %b) {",
    )
  let #(b, _) = cmp_body(recursive, custom_types, ty, ty_s, b)
  let lines = list.reverse(b.lines)
  string.join(lines, "\n") <> "\n}\n"
}

fn cmp_body(recursive, custom_types, ty, ty_s, b) {
  case ty {
    ast.TInt -> {
      let #(r, b) = int_cmp(b, "i64", "sgt", "slt", "%a", "%b")
      #(emit_line(b, "  ret i32 " <> r), Nil)
    }
    ast.TFloat -> {
      let #(r, b) = int_cmp(b, "double", "ogt", "olt", "%a", "%b")
      #(emit_line(b, "  ret i32 " <> r), Nil)
    }
    ast.TBool -> {
      let #(g, b) = fresh(b)
      let b = emit_line(b, "  " <> g <> " = zext i1 %a to i32")
      let #(l, b) = fresh(b)
      let b = emit_line(b, "  " <> l <> " = zext i1 %b to i32")
      let #(r, b) = fresh(b)
      let b = emit_line(b, "  " <> r <> " = sub i32 " <> g <> ", " <> l)
      #(emit_line(b, "  ret i32 " <> r), Nil)
    }
    TString -> {
      let #(c, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> c
            <> " = call i64 @Gleamc_string_compare_bytes(%GleamcString %a, %GleamcString %b)",
        )
      let #(r, b) = fresh(b)
      let b = emit_line(b, "  " <> r <> " = trunc i64 " <> c <> " to i32")
      #(emit_line(b, "  ret i32 " <> r), Nil)
    }
    ast.TNil | TNamed("Nil") | ast.TFun(_, _) -> #(
      emit_line(b, "  ret i32 0"),
      Nil,
    )
    ast.TTuple(types) -> {
      let #(r, b) =
        cmp_chain(
          recursive,
          custom_types,
          "%" <> "GleamcTuple_" <> tuple_suffix(types),
          "%a",
          "%b",
          types,
          [],
          0,
          b,
        )
      #(emit_line(b, "  ret i32 " <> r), Nil)
    }
    TNamed("BitArray") -> {
      let #(al, b) = extract_value("%GleamcBitArray", "%a", [1], b)
      let #(bl, b) = extract_value("%GleamcBitArray", "%b", [1], b)
      let #(ne, b) = fresh(b)
      let b = emit_line(b, "  " <> ne <> " = icmp ne i64 " <> al <> ", " <> bl)
      let b = emit_line(b, "  br i1 " <> ne <> ", label %blen, label %bbytes")
      let b = emit_line(b, "\nblen:")
      let #(gt, b) = fresh(b)
      let b = emit_line(b, "  " <> gt <> " = icmp sgt i64 " <> al <> ", " <> bl)
      let #(lt, b) = fresh(b)
      let b = emit_line(b, "  " <> lt <> " = icmp slt i64 " <> al <> ", " <> bl)
      let #(g, b) = fresh(b)
      let b = emit_line(b, "  " <> g <> " = zext i1 " <> gt <> " to i32")
      let #(l, b) = fresh(b)
      let b = emit_line(b, "  " <> l <> " = zext i1 " <> lt <> " to i32")
      let #(r, b) = fresh(b)
      let b = emit_line(b, "  " <> r <> " = sub i32 " <> g <> ", " <> l)
      let b = emit_line(b, "  ret i32 " <> r)
      let b = emit_line(b, "\nbbytes:")
      let #(ad, b) = extract_value("%GleamcBitArray", "%a", [0], b)
      let #(bd, b) = extract_value("%GleamcBitArray", "%b", [0], b)
      let #(m, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> m
            <> " = call i32 @memcmp(i8* "
            <> ad
            <> ", i8* "
            <> bd
            <> ", i64 "
            <> al
            <> ")",
        )
      let b = emit_line(b, "  ret i32 " <> m)
      #(b, Nil)
    }
    TNamed(type_name) -> cmp_named(recursive, custom_types, type_name, ty_s, b)
    _ -> #(emit_line(b, "  ret i32 0"), Nil)
  }
}

fn cmp_kind(num_ty: String) -> String {
  case num_ty {
    "double" -> "fcmp"
    _ -> "icmp"
  }
}

fn int_cmp(b, int_ty, gt_op, lt_op, left, right) {
  let #(gt, b) = fresh(b)
  let kind = cmp_kind(int_ty)
  let b =
    emit_line(
      b,
      "  "
        <> gt
        <> " = "
        <> kind
        <> " "
        <> gt_op
        <> " "
        <> int_ty
        <> " "
        <> left
        <> ", "
        <> right,
    )
  let #(lt, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  "
        <> lt
        <> " = "
        <> kind
        <> " "
        <> lt_op
        <> " "
        <> int_ty
        <> " "
        <> left
        <> ", "
        <> right,
    )
  let #(g, b) = fresh(b)
  let b = emit_line(b, "  " <> g <> " = zext i1 " <> gt <> " to i32")
  let #(l, b) = fresh(b)
  let b = emit_line(b, "  " <> l <> " = zext i1 " <> lt <> " to i32")
  let #(r, b) = fresh(b)
  let b = emit_line(b, "  " <> r <> " = sub i32 " <> g <> ", " <> l)
  #(r, b)
}

fn cmp_chain(
  recursive,
  custom_types,
  struct_ty,
  av,
  bv,
  fields,
  prefix,
  index,
  b,
) {
  case fields {
    [] -> #("0", b)
    [ty, ..rest] -> {
      let #(rest_res, b) =
        cmp_chain(
          recursive,
          custom_types,
          struct_ty,
          av,
          bv,
          rest,
          prefix,
          index + 1,
          b,
        )
      let idxs = list.append(prefix, [index])
      let #(lv, b) = extract_value(struct_ty, av, idxs, b)
      let #(rv, b) = extract_value(struct_ty, bv, idxs, b)
      let #(ci, b) = cmp_expr(recursive, custom_types, ty, lv, rv, b)
      let #(nz, b) = fresh(b)
      let b = emit_line(b, "  " <> nz <> " = icmp ne i32 " <> ci <> ", 0")
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> r
            <> " = select i1 "
            <> nz
            <> ", i32 "
            <> ci
            <> ", i32 "
            <> rest_res,
        )
      #(r, b)
    }
  }
}

fn cmp_expr(recursive, _custom_types, ty, left, right, b) {
  case ty {
    TString -> {
      let #(c, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> c
            <> " = call i64 @Gleamc_string_compare_bytes(%GleamcString "
            <> left
            <> ", %GleamcString "
            <> right
            <> ")",
        )
      let #(r, b) = fresh(b)
      let b = emit_line(b, "  " <> r <> " = trunc i64 " <> c <> " to i32")
      #(r, b)
    }
    ast.TInt -> int_cmp_i(b, "i64", "sgt", "slt", left, right)
    ast.TFloat -> int_cmp_i(b, "double", "ogt", "olt", left, right)
    ast.TBool -> {
      let #(g, b) = fresh(b)
      let b = emit_line(b, "  " <> g <> " = zext i1 " <> left <> " to i32")
      let #(l, b) = fresh(b)
      let b = emit_line(b, "  " <> l <> " = zext i1 " <> right <> " to i32")
      let #(r, b) = fresh(b)
      let b = emit_line(b, "  " <> r <> " = sub i32 " <> g <> ", " <> l)
      #(r, b)
    }
    ast.TNil | TNamed("Nil") | ast.TFun(_, _) -> #("0", b)
    _ -> {
      let ty_s = llvm_ty(ty, recursive)
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> r
            <> " = call i32 @Gleamc_Cmp_"
            <> mangle_glue(ty)
            <> "("
            <> ty_s
            <> " "
            <> left
            <> ", "
            <> ty_s
            <> " "
            <> right
            <> ")",
        )
      #(r, b)
    }
  }
}

fn int_cmp_i(b, num_ty, gt_op, lt_op, left, right) {
  let #(gt, b) = fresh(b)
  let kind = cmp_kind(num_ty)
  let b =
    emit_line(
      b,
      "  "
        <> gt
        <> " = "
        <> kind
        <> " "
        <> gt_op
        <> " "
        <> num_ty
        <> " "
        <> left
        <> ", "
        <> right,
    )
  let #(lt, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  "
        <> lt
        <> " = "
        <> kind
        <> " "
        <> lt_op
        <> " "
        <> num_ty
        <> " "
        <> left
        <> ", "
        <> right,
    )
  let #(g, b) = fresh(b)
  let b = emit_line(b, "  " <> g <> " = zext i1 " <> gt <> " to i32")
  let #(l, b) = fresh(b)
  let b = emit_line(b, "  " <> l <> " = zext i1 " <> lt <> " to i32")
  let #(r, b) = fresh(b)
  let b = emit_line(b, "  " <> r <> " = sub i32 " <> g <> ", " <> l)
  #(r, b)
}

fn cmp_named(recursive, custom_types, type_name, ty_s, b) {
  let is_rec = is_recursive(recursive, type_name)
  let struct_ty = "%" <> type_name
  let #(av, bv, b) = case is_rec {
    True -> {
      let #(av, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> av <> " = load " <> struct_ty <> ", " <> ty_s <> " %a",
        )
      let #(bv, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> bv <> " = load " <> struct_ty <> ", " <> ty_s <> " %b",
        )
      #(av, bv, b)
    }
    False -> #("%a", "%b", b)
  }
  let #(at, b) = extract_value(struct_ty, av, [0], b)
  let #(bt, b) = extract_value(struct_ty, bv, [0], b)
  let #(tne, b) = fresh(b)
  let b = emit_line(b, "  " <> tne <> " = icmp ne i8 " <> at <> ", " <> bt)
  let b = emit_line(b, "  br i1 " <> tne <> ", label %ctag, label %csw")
  let b = emit_line(b, "\nctag:")
  let #(ad, b) = fresh(b)
  let b = emit_line(b, "  " <> ad <> " = zext i8 " <> at <> " to i32")
  let #(bd, b) = fresh(b)
  let b = emit_line(b, "  " <> bd <> " = zext i8 " <> bt <> " to i32")
  let #(td, b) = fresh(b)
  let b = emit_line(b, "  " <> td <> " = sub i32 " <> ad <> ", " <> bd)
  let b = emit_line(b, "  ret i32 " <> td)
  let b = emit_line(b, "\ncsw:")
  let variants = variant_fields_of(custom_types, type_name)
  let arms =
    list.index_map(variants, fn(_, index) {
      " i8 " <> int.to_string(index) <> ", label %cv" <> int.to_string(index)
    })
  let b =
    emit_line(
      b,
      "  switch i8 "
        <> at
        <> ", label %czero ["
        <> string.join(arms, "")
        <> " ]",
    )
  let b = emit_line(b, "\nczero:")
  let b = emit_line(b, "  ret i32 0")
  let b =
    list.fold(
      list.index_map(variants, fn(variant, index) { #(index, variant) }),
      b,
      fn(b, entry) {
        let #(index, variant) = entry
        let #(_, fields) = variant
        let b = emit_line(b, "\ncv" <> int.to_string(index) <> ":")
        let #(r, b) =
          cmp_chain(
            recursive,
            custom_types,
            struct_ty,
            av,
            bv,
            fields,
            [index + 1],
            0,
            b,
          )
        emit_line(b, "  ret i32 " <> r)
      },
    )
  #(b, Nil)
}

// ---------------------------------------------------------------------------
// mutual tail-call groups (single dispatcher, the trampoline)
// ---------------------------------------------------------------------------

fn eligible_groups(
  module: ir.Module,
  ctors: Dict(String, checker.CtorInfo),
) -> List(List(ir.Function)) {
  let ir.Module(functions) = module
  let by_name =
    dict.from_list(list.map(functions, fn(function) {
      let ir.Function(name, _, _, _, _) = function
      #(name, function)
    }))
  let planned = plan.plan(module)
  let groups = case planned {
    plan.Plan(_, _, groups, _, _, _) -> groups
  }
  list.filter_map(groups, fn(group) {
    let plan.Group(members, _) = group
    case lookup_all(by_name, members) {
      Ok(fns) ->
        case
          list.any(fns, fn(f) { f.name == "main" }) || !group_ok(fns, ctors)
        {
          True -> Error(Nil)
          False -> Ok(fns)
        }
      Error(_) -> Error(Nil)
    }
  })
}

fn lookup_all(
  by_name: Dict(String, ir.Function),
  names: List(String),
) -> Result(List(ir.Function), Nil) {
  case names {
    [] -> Ok([])
    [name, ..rest] ->
      case dict.get(by_name, name) {
        Ok(function) ->
          case lookup_all(by_name, rest) {
            Ok(fns) -> Ok([function, ..fns])
            Error(_) -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
  }
}

/// A mutual group is eligible when every member has the same return type and
/// only scalar locals (no handle), so the frame rebind can never dangle a
/// borrowed reference. Handle groups await the frame-claim ownership stage.
fn group_ok(
  fns: List(ir.Function),
  ctors: Dict(String, checker.CtorInfo),
) -> Bool {
  let _ = ctors
  let rets =
    list.map(fns, fn(f) {
      let ir.Function(_, _, ret, _, _) = f
      ir.describe_type(ret)
    })
  all_equal(rets) && list.length(fns) > 1
}

fn all_equal(items: List(String)) -> Bool {
  case items {
    [] -> True
    [first, ..rest] -> list.all(rest, fn(item) { item == first })
  }
}

fn group_type_decls(
  groups: List(List(ir.Function)),
  recursive: Dict(String, Bool),
) -> String {
  string.join(
    list.flat_map(groups, fn(group) {
      let gid = string.join(list.map(group, fn(f) { f.name }), "_")
      list.index_map(group, fn(function, index) {
        let ir.Function(_, params, _, _, locals) = function
        let by_name = locals_map(locals)
        "%__"
        <> gid
        <> ".m"
        <> int.to_string(index)
        <> " = type { "
        <> string.join(
          list.map(params, fn(param) {
            llvm_ty(local_type(by_name, param), recursive)
          }),
          ", ",
        )
        <> " }"
      })
    }),
    "\n",
  )
}

fn block_names_prefixed(
  blocks: List(ir.Block),
  prefix: String,
) -> Dict(String, String) {
  blocks
  |> list.index_map(fn(block, index) {
    let ir.Block(label, _, _) = block
    #(label, prefix <> "bb" <> int.to_string(index))
  })
  |> dict.from_list
}

fn entry_name(blocks: List(ir.Block), prefix: String) -> String {
  let _ = blocks
  prefix <> "bb0"
}

fn emit_group(
  group: List(ir.Function),
  recursive: Dict(String, Bool),
  lits: Dict(String, Int),
  custom_types: List(ast.CustomType),
  custom_by_name: Dict(String, ast.CustomType),
  ctors: Dict(String, checker.CtorInfo),
  tuples: List(Type),
) -> #(String, List(String)) {
  let gid = string.join(list.map(group, fn(f) { f.name }), "_")
  let disp = "__g_" <> gid
  let ret = case group {
    [first, ..] -> {
      let ir.Function(_, _, ret, _, _) = first
      ret
    }
    [] -> ast.TNil
  }
  let ret_s = llvm_ty(ret, recursive)
  let indexed =
    list.index_map(group, fn(function, index) {
      let prefix = "m" <> int.to_string(index) <> "_"
      let ir.Function(name, params, _, blocks, _) = function
      #(function, index, prefix, entry_name(blocks, prefix), name, params)
    })
  let group_map =
    indexed
    |> list.map(fn(entry) {
      let #(_, _, prefix, entry_label, name, params) = entry
      #(name, #(prefix, params, entry_label))
    })
    |> dict.from_list

  // dispatcher
  let b = Builder(next: 0, lines: [])
  let b =
    emit_line(
      b,
      "define " <> ret_s <> " @" <> disp <> "(i32 %__fn, i8* %__args) {",
    )
  let b =
    list.fold(indexed, b, fn(b, entry) {
      let #(function, _, prefix, _, _, _) = entry
      let ir.Function(_, _, _, _, locals) = function
      list.fold(locals, b, fn(b, local) {
        let ir.Local(name, ty) = local
        emit_line(
          b,
          "  %l."
            <> prefix
            <> safe(name)
            <> " = alloca "
            <> llvm_ty(ty, recursive),
        )
      })
    })
  let switch_arms =
    list.index_map(group, fn(_, index) {
      " i32 "
      <> int.to_string(index)
      <> ", label %__pro"
      <> int.to_string(index)
    })
  let b =
    emit_line(
      b,
      "  switch i32 %__fn, label %__bad [ "
        <> string.join(switch_arms, " ")
        <> " ]",
    )
  let b = emit_line(b, "\n__bad:")
  let b = emit_line(b, "  unreachable")
  // prologues
  let b =
    list.fold(indexed, b, fn(b, entry) {
      let #(function, index, prefix, entry_label, _, _) = entry
      let ir.Function(_, params, _, _, locals) = function
      let by_name = locals_map(locals)
      let struct_ty = "%__" <> gid <> ".m" <> int.to_string(index)
      let b = emit_line(b, "\n__pro" <> int.to_string(index) <> ":")
      let #(p, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> p <> " = bitcast i8* %__args to " <> struct_ty <> "*",
        )
      let b =
        list.fold(
          list.index_map(params, fn(param, field) { #(param, field) }),
          b,
          fn(b, pair) {
            let #(param, field) = pair
            let pty_s = llvm_ty(local_type(by_name, param), recursive)
            let #(gp, b) = fresh(b)
            let b =
              emit_line(
                b,
                "  "
                  <> gp
                  <> " = getelementptr "
                  <> struct_ty
                  <> ", "
                  <> struct_ty
                  <> "* "
                  <> p
                  <> ", i32 0, i32 "
                  <> int.to_string(field),
              )
            let #(v, b) = fresh(b)
            let b =
              emit_line(
                b,
                "  " <> v <> " = load " <> pty_s <> ", " <> pty_s <> "* " <> gp,
              )
            emit_line(
              b,
              "  store "
                <> pty_s
                <> " "
                <> v
                <> ", "
                <> pty_s
                <> "* %l."
                <> prefix
                <> safe(param),
            )
          },
        )
      emit_line(b, "  br label %" <> entry_label)
    })
  // member bodies
  let b =
    list.fold(indexed, b, fn(b, entry) {
      let #(function, _, prefix, entry_label, name, params) = entry
      let ir.Function(_, _, member_ret, blocks, locals) = function
      let ctx =
        Ctx(
          recursive: recursive,
          by_name: locals_map(locals),
          lits: lits,
          blocks: block_names_prefixed(blocks, prefix),
          ret: member_ret,
          custom_types: custom_types,
          custom_by_name: custom_by_name,
          ctors: ctors,
          tuples: tuples,
          fn_name: name,
          entry: entry_label,
          params: params,
          prefix: prefix,
          group: group_map,
        )
      let #(b, _) = emit_block_list(ctx, blocks, b)
      b
    })
  let dispatcher = string.join(list.reverse(b.lines), "\n") <> "\n}\n"
  let wrappers =
    list.map(indexed, fn(entry) {
      let #(function, index, _, _, _, _) = entry
      wrapper_for_group(function, index, gid, ret_s, recursive, disp)
    })
  #(dispatcher, wrappers)
}

fn wrapper_for_group(
  function: ir.Function,
  index: Int,
  gid: String,
  ret_s: String,
  recursive: Dict(String, Bool),
  disp: String,
) -> String {
  let ir.Function(name, params, _, _, locals) = function
  let by_name = locals_map(locals)
  let struct_ty = "%__" <> gid <> ".m" <> int.to_string(index)
  let decls =
    list.index_map(params, fn(param, field) {
      llvm_ty(local_type(by_name, param), recursive)
      <> " %a"
      <> int.to_string(field)
    })
  let stores =
    string.join(
      list.map(
        list.index_map(params, fn(param, field) { #(param, field) }),
        fn(pair) {
          let #(param, field) = pair
          let pty_s = llvm_ty(local_type(by_name, param), recursive)
          "  %g"
          <> int.to_string(field)
          <> " = getelementptr "
          <> struct_ty
          <> ", "
          <> struct_ty
          <> "* %__a, i32 0, i32 "
          <> int.to_string(field)
          <> "\n"
          <> "  store "
          <> pty_s
          <> " %a"
          <> int.to_string(field)
          <> ", "
          <> pty_s
          <> "* %g"
          <> int.to_string(field)
        },
      ),
      "\n",
    )
  "define "
  <> ret_s
  <> " @Gleamc_"
  <> name
  <> "("
  <> string.join(decls, ", ")
  <> ") {\n"
  <> "  %__a = alloca "
  <> struct_ty
  <> "\n"
  <> case stores {
    "" -> ""
    _ -> stores <> "\n"
  }
  <> "  %__ap = bitcast "
  <> struct_ty
  <> "* %__a to i8*\n"
  <> "  %__r = call "
  <> ret_s
  <> " @"
  <> disp
  <> "(i32 "
  <> int.to_string(index)
  <> ", i8* %__ap)\n"
  <> "  ret "
  <> ret_s
  <> " %__r\n}\n"
}

// ---------------------------------------------------------------------------
// retain/drop glue
// ---------------------------------------------------------------------------

fn cstring_arg(lits: Dict(String, Int), content: String) -> String {
  let index = literal_index(lits, content)
  case index < 0 {
    True -> "i8* null"
    False -> {
      let size = string.byte_size(content) + 1
      "i8* getelementptr inbounds ({ i64, ["
      <> int.to_string(size)
      <> " x i8] }, { i64, ["
      <> int.to_string(size)
      <> " x i8] }* @.str."
      <> int.to_string(index)
      <> ", i32 0, i32 1, i64 0)"
    }
  }
}

fn collect_rc_sites(functions, custom_types, tuples, ctors) -> List(String) {
  let _ = ctors
  let from_ops =
    list.flat_map(functions, fn(function) {
      let ir.Function(name, _, _, blocks, _) = function
      list.flat_map(blocks, fn(block) {
        let ir.Block(_, ops, _) = block
        list.filter_map(ops, fn(op) {
          case op {
            ir.OpRetain(src, _) -> Ok(name <> ":" <> src)
            ir.OpDrop(src, _) -> Ok(name <> ":" <> src)
            _ -> Error(Nil)
          }
        })
      })
    })
  let seeds =
    list.append(
      list.map(custom_types, fn(custom) {
        let ast.CustomType(_, name, _, _, _) = custom
        TNamed(name)
      }),
      tuples,
    )
  let from_glue =
    list.flat_map(seeds, fn(ty) { [rc_name("retain", ty), rc_name("drop", ty)] })
  let alloc_sites =
    list.append(
      ["alloc:env"],
      list.map(custom_types, fn(custom) {
        let ast.CustomType(_, name, _, _, _) = custom
        "alloc:" <> name
      }),
    )
  let env_sites = list.map(functions, fn(_) { "env" })
  list.append(
    list.append(list.append(from_ops, from_glue), alloc_sites),
    env_sites,
  )
}

fn env_drop_ptr(env_ty: String) -> String {
  case env_ty {
    "" -> "null"
    _ -> "@" <> env_ty <> "_drop"
  }
}

fn emit_env_drop(entry, recursive, fields_of, lits) -> String {
  let #(env_ty, field_types) = entry
  let safe_ty = safe(env_ty)
  let done = "ed_" <> safe_ty <> "_done"
  let body = "ed_" <> safe_ty <> "_body"
  let b = Builder(next: 0, lines: [])
  let b = emit_line(b, "define void @" <> env_ty <> "_drop(i8* %env) {")
  let b = emit_line(b, "  %isnull = icmp eq i8* %env, null")
  let b =
    emit_line(b, "  br i1 %isnull, label %" <> done <> ", label %" <> body)
  let b = emit_line(b, "\n" <> body <> ":")
  let #(e, b) = fresh(b)
  let b = emit_line(b, "  " <> e <> " = bitcast i8* %env to %" <> env_ty <> "*")
  let b =
    list.fold(
      list.index_map(field_types, fn(fty, index) { #(fty, index) }),
      b,
      fn(b, pair) {
        let #(fty, index) = pair
        case ownership.needs_drop_in(fty, fields_of, recursive) {
          True -> {
            let #(gp, b) = fresh(b)
            let b =
              emit_line(
                b,
                "  "
                  <> gp
                  <> " = getelementptr %"
                  <> env_ty
                  <> ", %"
                  <> env_ty
                  <> "* "
                  <> e
                  <> ", i32 0, i32 "
                  <> int.to_string(index),
              )
            let #(fv, b) = fresh(b)
            let fty_s = llvm_ty(fty, recursive)
            let b =
              emit_line(
                b,
                "  " <> fv <> " = load " <> fty_s <> ", " <> fty_s <> "* " <> gp,
              )
            rc_expr(lits, recursive, fields_of, "drop", fty, fty_s, fv, "env", b)
          }
          False -> b
        }
      },
    )
  let b =
    emit_line(
      b,
      "  call void @Gleamc_rc_release(i8* %env, "
        <> cstring_arg(lits, "env")
        <> ")",
    )
  let b = emit_line(b, "  br label %" <> done)
  let b = emit_line(b, "\n" <> done <> ":")
  let b = emit_line(b, "  ret void")
  string.join(list.reverse(b.lines), "\n") <> "\n}\n"
}

fn rc_runtime(which: String) -> String {
  case which {
    "retain" -> "retain"
    _ -> "release"
  }
}

fn rc_name(which: String, ty: Type) -> String {
  "Gleamc_Rc_" <> which <> "_" <> mangle_glue(ty)
}

fn rc_expr(
  lits: Dict(String, Int),
  _recursive,
  _fields_of,
  which,
  ty,
  ty_s,
  reg,
  site,
  b,
) -> Builder {
  case ty {
    TString | TNamed("BitArray") -> {
      let #(d, b) = extract_value(ty_s, reg, [0], b)
      emit_line(
        b,
        "  call void @Gleamc_rc_"
          <> rc_runtime(which)
          <> "(i8* "
          <> d
          <> ", "
          <> cstring_arg(lits, site)
          <> ")",
      )
    }
    ast.TFun(_, _) -> {
      // Closure value { code, env, env_drop }.
      let #(env, b) = extract_value(ty_s, reg, [1], b)
      case which {
        "retain" ->
          emit_line(
            b,
            "  call void @Gleamc_rc_retain(i8* "
              <> env
              <> ", "
              <> cstring_arg(lits, site)
              <> ")",
          )
        _ -> {
          let #(dropf, b) = extract_value(ty_s, reg, [2], b)
          let #(isnull, b) = fresh(b)
          let base = string.replace(isnull, "%", "")
          let rel = "rc_rel_" <> base
          let usedrop = "rc_ud_" <> base
          let done = "rc_done_" <> base
          let b =
            emit_line(b, "  " <> isnull <> " = icmp eq i8* " <> env <> ", null")
          let b =
            emit_line(
              b,
              "  br i1 "
                <> isnull
                <> ", label %"
                <> done
                <> ", label %"
                <> usedrop
                <> "_chk",
            )
          let b = emit_line(b, "\n" <> usedrop <> "_chk:")
          let #(dnull, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  " <> dnull <> " = icmp eq void (i8*)* " <> dropf <> ", null",
            )
          let b =
            emit_line(
              b,
              "  br i1 "
                <> dnull
                <> ", label %"
                <> rel
                <> ", label %"
                <> usedrop,
            )
          let b = emit_line(b, "\n" <> usedrop <> ":")
          let b = emit_line(b, "  call void " <> dropf <> "(i8* " <> env <> ")")
          let b = emit_line(b, "  br label %" <> done)
          let b = emit_line(b, "\n" <> rel <> ":")
          let b =
            emit_line(
              b,
              "  call void @Gleamc_rc_release(i8* "
                <> env
                <> ", "
                <> cstring_arg(lits, site)
                <> ")",
            )
          let b = emit_line(b, "  br label %" <> done)
          let b = emit_line(b, "\n" <> done <> ":")
          b
        }
      }
    }
    TNamed(_) | ast.TTuple(_) -> {
      emit_line(
        b,
        "  call void @"
          <> rc_name(which, ty)
          <> "("
          <> ty_s
          <> " "
          <> reg
          <> ")",
      )
    }
    _ -> b
  }
}

fn emit_rc_glue(
  lits: Dict(String, Int),
  recursive,
  custom_types,
  fields_of,
  which,
  ty,
) -> String {
  let ty_s = llvm_ty(ty, recursive)
  let name = rc_name(which, ty)
  let b = Builder(next: 0, lines: [])
  let b = case ty {
    ast.TTuple(types) -> {
      let b = emit_line(b, "define void @" <> name <> "(" <> ty_s <> " %v) {")
      let b =
        list.fold(
          list.index_map(types, fn(inner, index) { #(inner, index) }),
          b,
          fn(b, pair) {
            let #(inner, index) = pair
            case ownership.needs_drop_in(inner, fields_of, recursive) {
              True -> {
                let #(fv, b) = extract_value(ty_s, "%v", [index], b)
                rc_expr(
                  lits,
                  recursive,
                  fields_of,
                  which,
                  inner,
                  llvm_ty(inner, recursive),
                  fv,
                  name,
                  b,
                )
              }
              False -> b
            }
          },
        )
      emit_line(b, "  ret void")
    }
    TNamed(type_name) ->
      case is_recursive(recursive, type_name) {
        True ->
          rc_glue_recursive(
            lits,
            recursive,
            custom_types,
            fields_of,
            which,
            type_name,
            ty_s,
            name,
            b,
          )
        False ->
          rc_glue_byvalue(
            lits,
            recursive,
            custom_types,
            fields_of,
            which,
            type_name,
            ty_s,
            name,
            b,
          )
      }
    _ -> b
  }
  case list.length(b.lines) {
    0 -> ""
    _ -> string.join(list.reverse(emit_line(b, "\n}").lines), "\n") <> "\n"
  }
}

fn rc_glue_byvalue(
  lits: Dict(String, Int),
  recursive,
  custom_types,
  fields_of,
  which,
  type_name,
  ty_s,
  name,
  b,
) {
  let variants = variant_fields_of(custom_types, type_name)
  let b = emit_line(b, "define void @" <> name <> "(" <> ty_s <> " %v) {")
  let b = emit_line(b, "  %tag = extractvalue " <> ty_s <> " %v, 0")
  let arms =
    list.index_map(variants, fn(_, index) {
      " i8 " <> int.to_string(index) <> ", label %v" <> int.to_string(index)
    })
  let b =
    emit_line(
      b,
      "  switch i8 %tag, label %done [" <> string.join(arms, "") <> " ]",
    )
  let b =
    list.fold(
      list.index_map(variants, fn(variant, index) { #(variant, index) }),
      b,
      fn(b, entry) {
        let #(variant, index) = entry
        let #(_, fields) = variant
        let b = emit_line(b, "\nv" <> int.to_string(index) <> ":")
        let b =
          list.fold(
            list.index_map(fields, fn(inner, i) { #(inner, i) }),
            b,
            fn(b, fp) {
              let #(inner, i) = fp
              case ownership.needs_drop_in(inner, fields_of, recursive) {
                True -> {
                  let #(fv, b) = extract_value(ty_s, "%v", [index + 1, i], b)
                  rc_expr(
                    lits,
                    recursive,
                    fields_of,
                    which,
                    inner,
                    llvm_ty(inner, recursive),
                    fv,
                    name,
                    b,
                  )
                }
                False -> b
              }
            },
          )
        let b = emit_line(b, "  br label %done")
        b
      },
    )
  let b = emit_line(b, "\ndone:")
  emit_line(b, "  ret void")
}

fn rc_glue_recursive(
  lits: Dict(String, Int),
  recursive,
  custom_types,
  fields_of,
  which,
  type_name,
  ty_s,
  name,
  b,
) {
  let variants = variant_fields_of(custom_types, type_name)
  let b = emit_line(b, "define void @" <> name <> "(" <> ty_s <> " %v) {")
  let b = emit_line(b, "  %isnull = icmp eq " <> ty_s <> " %v, null")
  let b = emit_line(b, "  br i1 %isnull, label %done, label %notnull")
  let b = emit_line(b, "\nnotnull:")
  let b = emit_line(b, "  %vp = bitcast " <> ty_s <> " %v to i8*")
  let b = case which {
    "retain" -> {
      let b =
        emit_line(
          b,
          "  call void @Gleamc_rc_retain(i8* %vp, "
            <> cstring_arg(lits, name)
            <> ")",
        )
      emit_line(b, "  br label %done")
    }
    _ -> {
      let b = emit_line(b, "  %hp = getelementptr i8, i8* %vp, i64 -8")
      let b = emit_line(b, "  %h = bitcast i8* %hp to i64*")
      let b = emit_line(b, "  %rc = load i64, i64* %h")
      let b = emit_line(b, "  %last = icmp eq i64 %rc, 1")
      let b = emit_line(b, "  br i1 %last, label %frees, label %rel")
      let b = emit_line(b, "\nfrees:")
      let struct_ty = "%" <> type_name
      let b =
        emit_line(b, "  %av = load " <> struct_ty <> ", " <> ty_s <> " %v")
      let b = emit_line(b, "  %ftag = extractvalue " <> struct_ty <> " %av, 0")
      let arms =
        list.index_map(variants, fn(_, index) {
          " i8 " <> int.to_string(index) <> ", label %f" <> int.to_string(index)
        })
      let b =
        emit_line(
          b,
          "  switch i8 %ftag, label %rel [" <> string.join(arms, "") <> " ]",
        )
      let b =
        list.fold(
          list.index_map(variants, fn(variant, index) { #(variant, index) }),
          b,
          fn(b, entry) {
            let #(variant, index) = entry
            let #(_, fields) = variant
            let b = emit_line(b, "\nf" <> int.to_string(index) <> ":")
            let b =
              list.fold(
                list.index_map(fields, fn(inner, i) { #(inner, i) }),
                b,
                fn(b, fp) {
                  let #(inner, i) = fp
                  case ownership.needs_drop_in(inner, fields_of, recursive) {
                    True -> {
                      let #(fv, b) =
                        extract_value(struct_ty, "%av", [index + 1, i], b)
                      rc_expr(
                        lits,
                        recursive,
                        fields_of,
                        which,
                        inner,
                        llvm_ty(inner, recursive),
                        fv,
                        name,
                        b,
                      )
                    }
                    False -> b
                  }
                },
              )
            emit_line(b, "  br label %rel")
          },
        )
      let b = emit_line(b, "\nrel:")
      let b =
        emit_line(
          b,
          "  call void @Gleamc_rc_release(i8* %vp, "
            <> cstring_arg(lits, name)
            <> ")",
        )
      emit_line(b, "  br label %done")
    }
  }
  let b = emit_line(b, "\ndone:")
  emit_line(b, "  ret void")
}

// ---------------------------------------------------------------------------
// builder
// ---------------------------------------------------------------------------

type Builder {
  Builder(next: Int, lines: List(String))
}

fn fresh(b: Builder) -> #(String, Builder) {
  let Builder(next, lines) = b
  #("%t" <> int.to_string(next), Builder(next: next + 1, lines: lines))
}

fn emit_line(b: Builder, text: String) -> Builder {
  let Builder(next, lines) = b
  Builder(next: next, lines: [text, ..lines])
}
