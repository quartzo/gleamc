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
import gleamc/ir
import gleamc/ownership

type Ctx {
  Ctx(
    recursive: Dict(String, Bool),
    by_name: Dict(String, Type),
    lits: Dict(String, Int),
    blocks: Dict(String, String),
    ret: Type,
    custom_types: List(ast.CustomType),
    ctors: Dict(String, checker.CtorInfo),
    tuples: List(Type),
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
  let ir.Module(functions) = ir_module
  let recursive = ownership.recursive_types(ctors)
  let tuples = collect_tuple_types(custom_types, functions)
  let fn_types = collect_fn_types(custom_types, functions)
  let env_structs = collect_env_structs(functions)
  let lit_list = collect_literals(functions)
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

  let builtins =
    string.join(
      list.unique(
        list.flat_map(functions, fn(function) {
          builtin_decls(function, recursive)
        }),
      ),
      "\n",
    )

  let defs =
    string.join(
      list.map(functions, fn(function) {
        emit_function(function, recursive, lits, custom_types, ctors, tuples)
      }),
      "\n\n",
    )
  let wrappers =
    string.join(
      list.map(collect_wrappers(functions), fn(entry) { entry }),
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

  header()
  <> globals
  <> "\n\n"
  <> type_code
  <> "\n\n"
  <> builtins
  <> "\n\n"
  <> defs
  <> "\n\n"
  <> wrappers
  <> "\n"
  <> main_code
}

fn header() -> String {
  "target triple = \"x86_64-pc-linux-gnu\"\n\n"
  <> "%GleamcString = type { i8*, i64 }\n"
  <> "%GleamcBitArray = type { i8*, i64 }\n\n"
  <> "declare void @Gleamc_set_args(i32, i8**)\n"
  <> "declare i8* @gleamc_alloc(i64)\n"
  <> "declare %GleamcString @gleamc_string_concat(%GleamcString, %GleamcString)\n"
  <> "declare i1 @gleamc_string_eq(%GleamcString, %GleamcString)\n"
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
  case
    list.find(ctx.custom_types, fn(custom) {
      let ast.CustomType(_, n, _, _, _) = custom
      n == type_name
    })
  {
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
  let idx = string.join(list.map(indices, int.to_string), ", ")
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
          Ok(
            "declare "
            <> llvm_ty(ret_ty, recursive)
            <> " @Gleamc_"
            <> string.replace(builtin, ".", "_")
            <> "("
            <> string.join(
              list.map(args, fn(arg) {
                llvm_ty(operand_type(by_name, arg), recursive)
              }),
              ", ",
            )
            <> ")",
          )
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
      ctors: ctors,
      tuples: tuples,
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
      emit_line(b, "  %l." <> safe(name) <> " = alloca " <> ty_s)
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
        <> "* %l."
        <> safe(param),
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
      let #(rhs, res_ty) = binop_rhs(op_name, lty, lv, rv)
      let #(tmp, b) = fresh(b)
      let b = emit_line(b, "  " <> tmp <> " = " <> rhs)
      let b = store_local(ctx, dest, res_ty, tmp, b)
      #(b, Nil)
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
      let #(b, arg_list) = read_args(ctx, args, b)
      let ret_s = llvm_ty(ret_ty, ctx.recursive)
      let name = "Gleamc_" <> string.replace(builtin, ".", "_")
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
    ir.OpCopy(dest, src, ty) -> {
      let ty_s = llvm_ty(ty, ctx.recursive)
      let #(_, v, b) = read_val(ctx, src, b)
      let b = store_local(ctx, dest, ty_s, v, b)
      #(b, Nil)
    }
    ir.OpRetain(_, _) | ir.OpDrop(_, _) -> {
      // Ownership ops: ownership semantics for handle types are added once
      // the glue is emitted (retain/release per type). Value types are no-ops.
      #(b, Nil)
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
        insert_fields("%" <> type_name, base, fields, index + 1, 0, b)
      case is_recursive(ctx.recursive, type_name) {
        True -> {
          let #(sz, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  "
                <> sz
                <> " = ptrtoint (%"
                <> type_name
                <> "* getelementptr (%"
                <> type_name
                <> ", %"
                <> type_name
                <> "* null, i32 1) to i64)",
            )
          let #(p, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  " <> p <> " = call i8* @gleamc_alloc(i64 " <> sz <> ")",
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
              "  " <> p <> " = call i8* @gleamc_alloc(i64 " <> sz <> ")",
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
            <> ", void (i8*)* null, 2",
        )
      let b = store_local(ctx, dest, fn_s, c2, b)
      #(b, Nil)
    }
    ir.OpEnvGet(dest, env_ty, index, ty) -> {
      let ty_s = llvm_ty(ty, ctx.recursive)
      let #(envraw, b) = fresh(b)
      let b = emit_line(b, "  " <> envraw <> " = load i8*, i8** %l.__env")
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
    _ -> {
      let b = emit_line(b, "  ; TODO op: " <> op_debug(op))
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
            <> "* %l."
            <> safe(name),
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
  _ctx: Ctx,
  dest: String,
  ty_s: String,
  val: String,
  b: Builder,
) -> Builder {
  emit_line(
    b,
    "  store " <> ty_s <> " " <> val <> ", " <> ty_s <> "* %l." <> safe(dest),
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
    "-" -> #("sub i64 0, " <> v, "i64")
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
      insert_fields(ty_s, tmp, rest, 0, 1, b)
    }
  }
}

fn insert_fields(ty_s, base, fields, group, start, b) {
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
            <> int.to_string(group)
            <> ", "
            <> int.to_string(start),
        )
      insert_fields(ty_s, tmp, rest, group, start + 1, b)
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
  list.fold(functions, [], fn(acc: List(#(String, List(Type))), function) {
    let by_name = locals_map(local_list(function))
    list.fold(op_list(function), acc, fn(acc, op) {
      case op {
        ir.OpClosure(_, _, captures, env_ty, _) ->
          case env_ty {
            "" -> acc
            _ ->
              case list.any(acc, fn(entry) { entry.0 == env_ty }) {
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

fn collect_wrappers(functions: List(ir.Function)) -> List(String) {
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
      Ok(function) -> wrapper_def(function, code)
      Error(_) -> ""
    }
  })
}

fn dedupe_strings(items: List(String)) -> List(String) {
  list.fold(items, [], fn(acc, item) {
    case list.contains(acc, item) {
      True -> acc
      False -> list.append(acc, [item])
    }
  })
}

fn wrapper_def(function: ir.Function, code: String) -> String {
  let ir.Function(name, params, ret, _, locals) = function
  let by_name = locals_map(locals)
  let recursive = dict.new()
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

fn op_debug(op: ir.Op) -> String {
  case op {
    ir.OpTuple(_, _, _) -> "tuple"
    ir.OpTupleGet(_, _, _, _) -> "tuple_get"
    ir.OpCtor(_, _, _, _, _) -> "ctor"
    ir.OpTagIs(_, _, _, _) -> "tag_is"
    ir.OpField(_, _, _, _, _) -> "field"
    ir.OpCopy(_, _, _) -> "copy"
    ir.OpClosure(_, _, _, _, _) -> "closure"
    ir.OpEnvGet(_, _, _, _) -> "env_get"
    ir.OpCallIndirect(_, _, _, _) -> "call_indirect"
    ir.OpRetain(_, _) -> "retain"
    ir.OpDrop(_, _) -> "drop"
    ir.OpBitArray(_, _, _) -> "bit_array"
    _ -> "?"
  }
}
