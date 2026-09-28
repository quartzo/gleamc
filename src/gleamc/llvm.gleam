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
import gleam/option.{type Option, None, Some}
import gleam/string
import gleamc/abi
import gleamc/ast.{type Type, TNamed, TString}
import gleamc/checker
import gleamc/ffi
import gleamc/frame
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
    custom_by_name: Dict(String, ast.CustomType),
    ctors: Dict(String, checker.CtorInfo),
    tuples: List(Type),
    fn_name: String,
    entry: String,
    params: List(String),
    prefix: String,
    /// Parameter types of every function, keyed by name. A `musttail` call in
    /// the default calling convention requires the caller and callee prototypes
    /// to match, so a call may only be marked when these line up.
    signatures: Dict(String, List(Type)),
    /// The async machine functions, keyed by name. An `OpMachineStart` reads the
    /// callee's frame layout and step here to launch it as a task.
    machine_fns: Dict(String, ir.Function),
    /// Set for a function whose locals live in a heap frame (a closure
    /// captures them), instead of entry allocas.
    frame: Option(FrameInfo),
    /// The names of the current function's frame-owned fields. `OpMachineStart`
    /// / `TailMachine` retain an argument for the callee only when the caller
    /// frame still owns it (otherwise the value is moved and retaining leaks).
    frame_fields: Dict(String, Bool),
    /// The locals promoted to SSA values by `ssa.gleam`. Their reads and writes
    /// go through the `Builder`'s `values` map instead of a memory slot.
    reg_locals: Dict(String, Bool),
  )
}

/// Frame layout of one state machine: locals + `state` + `fut` (+ `result`).
type FrameInfo {
  FrameInfo(
    ty: String,
    /// SSA register holding the frame pointer (`%__fr` for a state machine,
    /// `%__frN` for a member of a group dispatcher).
    reg: String,
    fields: Dict(String, Int),
    state: Int,
    fut: Int,
    result: Int,
    block_index: Dict(String, Int),
  )
}

// ---------------------------------------------------------------------------
// entry point
// ---------------------------------------------------------------------------

/// Render the whole module to one string. Prefer `emit_chunks` for large
/// modules: it avoids materialising the full document in memory.
pub fn emit(
  ir_module: ir.Module,
  custom_types: List(ast.CustomType),
  ctors: Dict(String, checker.CtorInfo),
) -> String {
  string.join(emit_chunks(ir_module, custom_types, ctors), "")
}

/// Render the module as an ordered list of chunks — one per function body plus
/// the smaller sections — so a caller can stream them to a file. Joining the
/// result with `""` yields exactly the string `emit` returns.
pub fn emit_chunks(
  ir_module: ir.Module,
  custom_types: List(ast.CustomType),
  ctors: Dict(String, checker.CtorInfo),
) -> List(String) {
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
    dict.from_list(
      list.map(custom_types, fn(custom) {
        let ast.CustomType(_, n, _, _, _) = custom
        #(n, custom)
      }),
    )
  let recursive = ownership.recursive_types(ctors)
  let fields_of = ownership.type_fields(ctors)
  let tuples =
    collect_tuple_types(custom_types, functions)
    |> list.sort(fn(a, b) { string.compare(tuple_key(a), tuple_key(b)) })
  let machines = machine_set(ir_module)
  let suspends = suspend_set(ir_module)
  let signatures = function_signatures(functions)
  let machine_fns =
    list.fold(functions, dict.new(), fn(acc, function) {
      case dict.has_key(suspends, function.name) {
        True -> dict.insert(acc, function.name, function)
        False -> acc
      }
    })
  let fn_types =
    collect_fn_types(custom_types, functions)
    |> list.sort(fn(a, b) { string.compare(mangle_type(a), mangle_type(b)) })
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

  let global_decls =
    list.index_map(lit_list, fn(content, index) {
      literal_global(content, index)
    })

  let make_helpers = emit_make_helpers(custom_types, recursive)
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
      list.map(
        list.filter(functions, fn(f) { dict.has_key(machines, f.name) }),
        fn(f) { frame_type_decl(f, recursive) },
      ),
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

  let defs_bodies =
    list.map(functions, fn(function) {
      case dict.has_key(suspends, function.name) {
        True ->
          emit_machine_function(
            function,
            recursive,
            lits,
            custom_types,
            custom_by_name,
            ctors,
            tuples,
            signatures,
            machine_fns,
          )
        False ->
          case dict.has_key(machines, function.name) {
            True ->
              emit_frame_function(
                function,
                recursive,
                lits,
                custom_types,
                custom_by_name,
                ctors,
                tuples,
                signatures,
                machine_fns,
              )
            False ->
              emit_function(
                function,
                recursive,
                lits,
                custom_types,
                custom_by_name,
                ctors,
                tuples,
                signatures,
                machine_fns,
              )
          }
      }
    })
  let wrappers =
    string.join(
      list.map(collect_wrappers(functions, recursive), fn(entry) { entry }),
      "\n\n",
    )
  let buffer_seeds =
    list.map(collect_buffer_elems(custom_types, functions), fn(elem) {
      TNamed("Buffer_" <> surface_mangle(elem))
    })
  // `rc` glue is not emitted for `Buffer`: `rc_expr` releases the cell inline.
  let seeds =
    list.append(
      list.map(custom_types, fn(custom) {
        let ast.CustomType(_, name, _, _, _) = custom
        TNamed(name)
      }),
      tuples,
    )
  let glue_seeds = list.append(seeds, buffer_seeds)
  let eq_glue_fns =
    list.map(glue_seeds, fn(ty) { emit_eq_glue(recursive, custom_types, ty) })
  let cmp_glue_fns =
    list.append(
      [
        emit_cmp_glue(recursive, custom_types, ast.TInt),
        emit_cmp_glue(recursive, custom_types, ast.TFloat),
        emit_cmp_glue(recursive, custom_types, ast.TBool),
        emit_cmp_glue(recursive, custom_types, TString),
        emit_cmp_glue(recursive, custom_types, TNamed("BitArray")),
        emit_cmp_glue(recursive, custom_types, ast.TNil),
      ],
      list.map(glue_seeds, fn(ty) { emit_cmp_glue(recursive, custom_types, ty) }),
    )
  let rc_glue_fns =
    list.flat_map(seeds, fn(ty) {
      [
        emit_rc_glue(lits, recursive, custom_types, fields_of, "retain", ty),
        emit_rc_glue(lits, recursive, custom_types, fields_of, "drop", ty),
      ]
    })
  let buffer_glue_fns =
    list.map(collect_buffer_elems(custom_types, functions), fn(elem) {
      emit_buffer_glue(lits, recursive, custom_types, fields_of, elem)
    })
  let dynamic_glue_fns =
    list.filter_map(collect_box_drop_types(custom_types, functions), fn(ty) {
      case ownership.needs_drop_in(ty, fields_of, recursive) {
        True -> Ok(emit_box_glue(lits, recursive, fields_of, ty))
        False -> Error(Nil)
      }
    })
  let show_glue_fns =
    list.append(
      [
        emit_show_glue(recursive, custom_types, lits, ast.TInt),
        emit_show_glue(recursive, custom_types, lits, ast.TFloat),
        emit_show_glue(recursive, custom_types, lits, ast.TBool),
        emit_show_glue(recursive, custom_types, lits, TString),
        emit_show_glue(recursive, custom_types, lits, TNamed("BitArray")),
        emit_show_glue(recursive, custom_types, lits, ast.TNil),
      ],
      list.map(glue_seeds, fn(ty) {
        emit_show_glue(recursive, custom_types, lits, ty)
      }),
    )

  let main_code = case list.any(functions, fn(f) { f.name == "main" }) {
    True ->
      "\ndefine i32 @main(i32 %argc, i8** %argv) {\n"
      <> "  call void @Gleamc_set_args(i32 %argc, i8** %argv)\n"
      <> "  call i32 @Gleamc_main()\n"
      <> "  call void @gleamc_shutdown()\n"
      <> "  ret i32 0\n"
      <> "}\n"
    False -> ""
  }

  // Frame teardowns (the frame owns its kept-alive fields).
  let frame_fns =
    list.filter(functions, fn(f) { dict.has_key(machines, f.name) })
  let frame_drops =
    string.join(
      list.map(frame_fns, fn(f) {
        emit_frame_drop(f, recursive, fields_of, lits)
      }),
      "\n\n",
    )
  let chunks =
    list.flatten([
      [header(audit)],
      intersperse(global_decls, "\n"),
      ["\n\n", type_code, "\n\n", builtins, "\n\n"],
      [make_helpers, "\n\n"],
      intersperse(defs_bodies, "\n\n"),
      ["\n\n", frame_drops, "\n\n", wrappers, "\n\n"],
      intersperse(eq_glue_fns, "\n\n"),
      ["\n\n"],
      intersperse(rc_glue_fns, "\n\n"),
      ["\n\n"],
      intersperse(buffer_glue_fns, "\n\n"),
      ["\n\n"],
      intersperse(dynamic_glue_fns, "\n\n"),
      ["\n\n"],
      intersperse(show_glue_fns, "\n\n"),
      ["\n\n"],
      intersperse(cmp_glue_fns, "\n\n"),
      ["\n", main_code],
    ])
  // Optional call-depth probe (debug aid): the generated code bumps the
  // `@__gleamc_depth` global directly on entry (load/add/store) and before each
  // return (load/sub/store); only the limit path calls into the runtime to name
  // the function that went deepest and abort. It rewrites the whole document,
  // so it collapses the chunks back into one.
  case ffi.get_env("GLEAMC_CALL_DEPTH") {
    Ok(_) -> [instrument_depth(string.join(chunks, ""))]
    Error(_) -> chunks
  }
}

/// `[a, sep, b, sep, c]`: the chunk-list form of `string.join(items, sep)`.
fn intersperse(items: List(String), sep: String) -> List(String) {
  case items {
    [] -> []
    [only] -> [only]
    [first, ..rest] -> [first, sep, ..intersperse(rest, sep)]
  }
}

fn define_name(line: String) -> String {
  case string.split(line, "@") {
    [_, rest, ..] ->
      case string.split(rest, "(") {
        [name, ..] -> name
        [] -> ""
      }
    _ -> ""
  }
}

fn is_terminator(t: String) -> Bool {
  list.any(
    ["br ", "ret ", "switch ", "unreachable", "indirectbr ", "resume "],
    fn(prefix) { string.starts_with(t, prefix) },
  )
}

fn depth_leave(k: Int) -> #(List(String), Int) {
  let a = "%__dla" <> int.to_string(k)
  let b = "%__dlb" <> int.to_string(k)
  #(
    [
      "  " <> a <> " = load i64, i64* @__gleamc_depth",
      "  " <> b <> " = sub i64 " <> a <> ", 1",
      "  store i64 " <> b <> ", i64* @__gleamc_depth",
    ],
    k + 1,
  )
}

fn instrument_depth(ll: String) -> String {
  // The entry bump is inserted just before the entry block's terminator, not
  // right after `define`: a branch at the very top would move the function's
  // `alloca`s out of the entry block and turn them into dynamic stack
  // adjustments on every call.
  let #(rev, globals, _n, _k, _entry) =
    list.fold(string.split(ll, "\n"), #([], [], 0, 0, []), fn(acc, line) {
      let #(rev, globals, n, k, entry) = acc
      let trimmed = string.trim(line)
      case string.starts_with(line, "define ") {
        True -> {
          let name = define_name(line)
          let len_s = int.to_string(string.byte_size(name) + 1)
          let ng = "@__depthfn_" <> int.to_string(n)
          let glob =
            ng
            <> " = private unnamed_addr constant ["
            <> len_s
            <> " x i8] c\""
            <> name
            <> "\\00\""
          let ptr =
            "i8* getelementptr inbounds (["
            <> len_s
            <> " x i8], ["
            <> len_s
            <> " x i8]* "
            <> ng
            <> ", i32 0, i32 0)"
          let a = "%__dta" <> int.to_string(n)
          let b = "%__dtb" <> int.to_string(n)
          let m = "%__dtm" <> int.to_string(n)
          let h = "%__dth" <> int.to_string(n)
          let die = "__dtdie" <> int.to_string(n)
          let ok = "__dtok" <> int.to_string(n)
          let entry = [
            "  " <> a <> " = load i64, i64* @__gleamc_depth",
            "  " <> b <> " = add i64 " <> a <> ", 1",
            "  store i64 " <> b <> ", i64* @__gleamc_depth",
            "  " <> m <> " = load i64, i64* @gleamc_depth_max",
            "  " <> h <> " = icmp sge i64 " <> b <> ", " <> m,
            "  br i1 " <> h <> ", label %" <> die <> ", label %" <> ok,
            die <> ":",
            "  call void @gleamc_depth_die(" <> ptr <> ")",
            "  unreachable",
            ok <> ":",
          ]
          #(push(rev, [line]), [glob, ..globals], n + 1, k, entry)
        }
        False ->
          case entry {
            [] ->
              case string.starts_with(trimmed, "ret ") {
                True -> {
                  let #(leave, k) = depth_leave(k)
                  #(push(rev, list.append(leave, [line])), globals, n, k, [])
                }
                False -> #(push(rev, [line]), globals, n, k, [])
              }
            _ ->
              case is_terminator(trimmed) {
                True -> {
                  let #(entry, k) = case string.starts_with(trimmed, "ret ") {
                    True -> {
                      let #(leave, k) = depth_leave(k)
                      #(list.append(entry, leave), k)
                    }
                    False -> #(entry, k)
                  }
                  #(push(rev, list.append(entry, [line])), globals, n, k, [])
                }
                False -> #(push(rev, [line]), globals, n, k, entry)
              }
          }
      }
    })
  string.join(list.reverse(rev), "\n")
  <> "\ndeclare void @gleamc_depth_die(i8*)\n"
  <> "@gleamc_depth_max = external global i64\n"
  <> "@__gleamc_depth = internal global i64 0\n"
  <> string.join(list.reverse(globals), "\n")
  <> "\n"
}

fn push(rev: List(String), chunk: List(String)) -> List(String) {
  list.fold(chunk, rev, fn(acc, line) { [line, ..acc] })
}

fn header(audit: Bool) -> String {
  "target triple = \"x86_64-pc-linux-gnu\"\n\n"
  <> "%GleamcString = type { i8*, i64 }\n"
  <> "%GleamcBitArray = type { i8*, i64 }\n"
  <> "%GleamcFileResult = type { i64, %GleamcBitArray, i64 }\n\n"
  <> "declare void @Gleamc_set_args(i32, i8**)\n"
  <> "declare i8* @gleamc_alloc(i64)\n"
  <> "declare i8* @gleamc_alloc0(i64)\n"
  <> "declare i8* @gleamc_alloc_site(i64, i8*)\n"
  <> rc_defs(audit)
  <> "declare void @Gleamc_uv_await_nil(i8*)\n"
  <> "declare i64 @Gleamc_uv_value_int(i8*)\n"
  <> "declare i64 @Gleamc_uv_result(i8*)\n"
  <> "declare %GleamcBitArray @Gleamc_uv_await_bytes(i8*)\n"
  <> "declare i8* @Gleamc_uv_await_box(i8*)\n"
  <> "declare i8* @gleamc_box_alloc(i64)\n"
  <> "declare i8* @gleamc_box_alloc_meta(i64, void (i8*)*)\n"
  <> "declare void @gleamc_box_free(i8*)\n"
  <> "declare void @gleamc_box_free_moved(i8*)\n"
  <> "declare void @Gleamc_subject_retain(i64)\n"
  <> "declare void @Gleamc_subject_release(i64)\n"
  <> "declare void @Gleamc_selector_retain(i64)\n"
  <> "declare void @Gleamc_selector_release(i64)\n"
  <> "declare void @Gleamc_task_ffi_retain(i8*)\n"
  <> "declare void @Gleamc_task_ffi_release(i8*)\n"
  <> "declare i64 @Gleamc_process_ffi_new_subject()\n"
  <> "declare i32 @Gleamc_process_ffi_send(i64, i8*)\n"
  <> "declare i8* @Gleamc_process_ffi_receive(i64)\n"
  <> "declare i32 @Gleamc_process_ffi_unreceive(i64, i8*)\n"
  <> "declare i1 @Gleamc_process_ffi_has_message(i64)\n"
  <> "declare i64 @Gleamc_process_ffi_mailbox_len(i64)\n"
  <> "declare i1 @Gleamc_process_ffi_monitor_eq(i64, i64)\n"
  <> "declare i64 @Gleamc_process_ffi_subject_handle(i64)\n"
  <> "declare i64 @Gleamc_process_ffi_subject_owner(i64)\n"
  <> "declare i64 @Gleamc_process_ffi_subject_name(i64)\n"
  <> "declare i64 @Gleamc_process_ffi_name_of_int(i64)\n"
  <> "declare i64 @Gleamc_process_ffi_monitor_to_int(i64)\n"
  <> "declare i32 @Gleamc_process_ffi_flush_messages()\n"
  <> "declare i64 @Gleamc_process_ffi_selector_merge(i64, i64)\n"
  <> "declare i64 @Gleamc_process_ffi_selector_watch_owned(i64)\n"
  <> "declare i8* @Gleamc_process_ffi_selector_other_raw(i64)\n"
  <> "declare i1 @Gleamc_process_ffi_traps(i64)\n"
  <> "declare i32 @Gleamc_process_ffi_send_exit(i64)\n"
  <> "declare i32 @Gleamc_process_ffi_send_exit_message(i64, i8*)\n"
  <> "declare i8* @Gleamc_dynamic_new(i32, i8*, void (i8*)*)\n"
  <> "declare void @Gleamc_dynamic_retain(i8*)\n"
  <> "declare void @Gleamc_dynamic_release(i8*)\n"
  <> "declare i64 @Gleamc_dynamic_ffi_classify(i8*)\n"
  <> "declare i8* @Gleamc_dynamic_bits(i8*)\n"
  <> "declare i64 @Gleamc_process_ffi_send_after(i64, i64, i8*)\n"
  <> "declare i64 @Gleamc_process_ffi_cancel_timer(i64)\n"
  <> "declare i64 @gleamc_task_id(i8*)\n"
  <> "declare i8* @gleamc_task_start(i1 (i8*)*, i8*, i8**, void (i8*, i8*)*, i8*, void (i8*)*)\n"
  <> "declare i8* @gleamc_task_async(i1 (i8*)*, i8*, i8**, void (i8*, i8*)*, void (i8*)*, i8*)\n"
  <> "declare i8* @gleamc_task_spawn(i1 (i8*)*, i8*, i8**, void (i8*)*)\n"
  <> "declare void @gleamc_task_tail(i1 (i8*)*, i8*, void (i8*, i8*)*, i8**, void (i8*)*)\n"
  <> "declare void @gleamc_run_until(i8*)\n"
  <> "declare void @gleamc_shutdown()\n"
  <> "declare %GleamcString @gleamc_string_lit(i8*, i64)\n"
  <> "declare %GleamcString @Gleamc_show_concat(%GleamcString, %GleamcString)\n"
  <> "declare %GleamcString @Gleamc_int_to_string(i64)\n"
  <> "declare %GleamcString @Gleamc_float_to_string(double)\n"
  <> "declare %GleamcString @Gleamc_bool_to_string(i1)\n"
  <> "declare %GleamcString @Gleamc_string_show(%GleamcString)\n"
  <> "declare i64 @Gleamc_hash_string(%GleamcString)\n"
  <> "declare i64 @Gleamc_hash_i64(i64)\n"
  <> "declare i64 @Gleamc_hash_f64(double)\n"
  <> "declare i8* @Gleamc_buffer_new(i64, i64, void (i8*)*)\n"
  <> "declare i64 @Gleamc_buffer_len(i8*)\n"
  <> "declare i8* @Gleamc_buffer_slot(i8*, i64)\n"
  <> "declare i8* @Gleamc_buffer_cow(i8*, i64, void (i8*)*, void (i8*)*)\n"
  <> "declare void @Gleamc_buffer_retain(i8*)\n"
  <> "declare void @Gleamc_buffer_release(i8*)\n"
  <> "declare i1 @Gleamc_buffer_is_null(i8*)\n"
  <> "declare void @Gleamc_buffer_take(i8*, i64, void (i8*)*, i8*)\n"
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

/// `Gleamc_rc_retain`/`Gleamc_rc_release`. In a normal build they are defined
/// here as `linkonce_odr ... alwaysinline`, so `clang` folds the fast path into
/// every call site (the reference-count header sits 8 bytes before the
/// payload); the runtime keeps an out-of-line copy for any non-inlined call.
/// The audit build must keep the runtime's instrumented versions, so it only
/// sees declarations.
fn rc_defs(audit: Bool) -> String {
  case audit {
    True ->
      "declare void @Gleamc_rc_retain(i8*, i8*)\n"
      <> "declare void @Gleamc_rc_release(i8*, i8*)\n"
    False ->
      "declare void @gleamc_release_slow(i8*)\n"
      <> "define linkonce_odr void @Gleamc_rc_retain(i8* %p, i8* %site) alwaysinline {\n"
      <> "entry:\n"
      <> "  %isnull = icmp eq i8* %p, null\n"
      <> "  br i1 %isnull, label %done, label %chk\n"
      <> "chk:\n"
      <> "  %hp = getelementptr i8, i8* %p, i64 -8\n"
      <> "  %hpc = bitcast i8* %hp to i64*\n"
      <> "  %rc = load i64, i64* %hpc\n"
      <> "  %isstatic = icmp eq i64 %rc, -1\n"
      <> "  br i1 %isstatic, label %done, label %inc\n"
      <> "inc:\n"
      <> "  %rc1 = add i64 %rc, 1\n"
      <> "  store i64 %rc1, i64* %hpc\n"
      <> "  br label %done\n"
      <> "done:\n"
      <> "  ret void\n"
      <> "}\n"
      <> "define linkonce_odr void @Gleamc_rc_release(i8* %p, i8* %site) alwaysinline {\n"
      <> "entry:\n"
      <> "  %isnull = icmp eq i8* %p, null\n"
      <> "  br i1 %isnull, label %done, label %chk\n"
      <> "chk:\n"
      <> "  %hp = getelementptr i8, i8* %p, i64 -8\n"
      <> "  %hpc = bitcast i8* %hp to i64*\n"
      <> "  %rc = load i64, i64* %hpc\n"
      <> "  %isstatic = icmp eq i64 %rc, -1\n"
      <> "  br i1 %isstatic, label %done, label %dec\n"
      <> "dec:\n"
      <> "  %rc1 = add i64 %rc, -1\n"
      <> "  store i64 %rc1, i64* %hpc\n"
      <> "  %iszero = icmp eq i64 %rc1, 0\n"
      <> "  br i1 %iszero, label %slow, label %done\n"
      <> "slow:\n"
      <> "  call void @gleamc_release_slow(i8* %hp)\n"
      <> "  br label %done\n"
      <> "done:\n"
      <> "  ret void\n"
      <> "}\n"
  }
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
    // Internal async handle (`GleamcFuture*`); never visible to Gleam.
    TNamed("Future") -> "i8*"
    // A process identifier (a stable task id), a scheduled-send timer, a
    // selector handle and a name (a subject handle).
    TNamed("Pid") -> "i64"
    TNamed("Monitor") -> "i64"
    TNamed("Timer") -> "i64"
    TNamed("Selector") -> "i64"
    TNamed("Name") -> "i64"
    // A refcounted selector handle (`GleamcSelector*` as i64).
    TNamed("SelectorHandle") -> "i64"
    // A boxed dynamic value (`GleamcDynamic*`).
    TNamed("Dynamic") -> "i8*"
    // Async I/O handle (a file descriptor); opaque scalar.
    TNamed("Handle") -> "i64"
    ast.TNil -> "i32"
    ast.TVar(name) -> name
    TNamed("Nil") -> "i32"
    TNamed(name) ->
      case ast.buffer_elem_name(name) {
        // `Buffer(a)` is an opaque refcounted cell.
        Ok(_) -> "i8*"
        Error(_) ->
          case ast.subject_elem_name(name), ast.task_elem_name(name) {
            // `Subject(a)` is a handle (i64); `Task(a)` is a future (`i8*`).
            Ok(_), _ -> "i64"
            _, Ok(_) -> "i8*"
            _, Error(_) ->
              case ast.selector_elem_name(name) {
                // `Selector(a)` is a handle (i64).
                Ok(_) -> "i64"
                Error(_) ->
                  case ast.name_elem_name(name) {
                    // `Name(a)` is a subject handle (i64).
                    Ok(_) -> "i64"
                    Error(_) ->
                      case is_recursive(recursive, name) {
                        True -> "%" <> name <> "*"
                        False -> "%" <> name
                      }
                  }
              }
          }
      }
    // `Buffer(a)` is a type-erased refcounted cell (opaque `void*`).
    ast.TApp("Buffer", _) -> "i8*"
    // `Subject(a)` is an opaque mailbox handle (pointer as i64); `Task(a)` is
    // the completion future itself (`i8*`).
    ast.TApp("Subject", _) -> "i64"
    ast.TApp("Task", _) -> "i8*"
    ast.TApp("Timer", _) -> "i64"
    ast.TApp("Selector", _) -> "i64"
    ast.TApp("Name", _) -> "i64"
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

/// Constructor helpers the C runtime calls to build the monitor/exit messages
/// (`Down`, `ExitMessage`), whose LLVM layout is compiler-owned. Emitted only
/// when the std process module's types are present. An `ExitReason` field is
/// passed as an `i64` code and built inline.
fn emit_make_helpers(custom_types, recursive) -> String {
  let by_name =
    dict.from_list(
      list.map(custom_types, fn(custom) {
        let ast.CustomType(_, name, _, _, _) = custom
        #(name, custom)
      }),
    )
  let exit_reason = find_type(by_name, "ExitReason")
  case exit_reason {
    Error(_) -> ""
    Ok(_) ->
      [#("Down", "ProcessDown"), #("ExitMessage", "ExitMessage")]
      |> list.filter_map(fn(pair) {
        let #(suffix, ctor) = pair
        case find_type(by_name, suffix) {
          Ok(custom) -> Ok(emit_make_helper(custom, ctor, recursive))
          Error(_) -> Error(Nil)
        }
      })
      |> string.join("\n\n")
  }
}

/// A custom type whose (possibly module-qualified) name ends with `_<suffix>` or
/// equals it: `Down`/`process_Down`.
fn find_type(by_name, suffix) -> Result(ast.CustomType, Nil) {
  case dict.get(by_name, suffix) {
    Ok(custom) -> Ok(custom)
    Error(_) ->
      dict.to_list(by_name)
      |> list.find_map(fn(pair) {
        let #(name, custom) = pair
        case string.ends_with(name, "_" <> suffix) {
          True -> Ok(custom)
          False -> Error(Nil)
        }
      })
  }
}

fn is_exit_reason_type(ty: Type) -> Bool {
  case ty {
    TNamed(name) -> string.ends_with(name, "ExitReason")
    _ -> False
  }
}

fn make_param_ty(ty: Type, recursive) -> String {
  case is_exit_reason_type(ty) {
    True -> "i64"
    False -> llvm_ty(ty, recursive)
  }
}

fn emit_make_helper(custom, ctor, recursive) -> String {
  let ast.CustomType(_, type_name, _, variants, _) = custom
  let #(index, fields) = variant_index_fields(variants, ctor)
  let ty_s = "%" <> type_name
  let var_ty = ty_s <> ".v" <> int.to_string(index)
  let params =
    list.index_map(fields, fn(field, i) {
      let #(_, ty) = field
      make_param_ty(ty, recursive) <> " %f" <> int.to_string(i)
    })
  let b = new_builder()
  let b =
    emit_line(
      b,
      "define i8* @Gleamc_make_"
        <> type_name
        <> "_"
        <> ctor
        <> "("
        <> string.join(params, ", ")
        <> ") {",
    )
  let #(payload, b) =
    list.fold(
      list.index_map(fields, fn(f, i) { #(f, i) }),
      #("undef", b),
      fn(acc, pair) {
        let #(field, i) = pair
        let #(base, b) = acc
        let #(_, ty) = field
        case is_exit_reason_type(ty) {
          True -> {
            let er_ty = llvm_ty(ty, recursive)
            let #(rc, b) = fresh(b)
            let b =
              emit_line(
                b,
                "  " <> rc <> " = trunc i64 %f" <> int.to_string(i) <> " to i8",
              )
            let #(er, b) = fresh(b)
            let b =
              emit_line(
                b,
                "  "
                  <> er
                  <> " = insertvalue "
                  <> er_ty
                  <> " undef, i8 "
                  <> rc
                  <> ", 0",
              )
            let #(v, b) = fresh(b)
            let b =
              emit_line(
                b,
                "  "
                  <> v
                  <> " = insertvalue "
                  <> var_ty
                  <> " "
                  <> base
                  <> ", "
                  <> er_ty
                  <> " "
                  <> er
                  <> ", "
                  <> int.to_string(i),
              )
            #(v, b)
          }
          _ -> {
            let fty = llvm_ty(ty, recursive)
            let #(v, b) = fresh(b)
            let b =
              emit_line(
                b,
                "  "
                  <> v
                  <> " = insertvalue "
                  <> var_ty
                  <> " "
                  <> base
                  <> ", "
                  <> fty
                  <> " %f"
                  <> int.to_string(i)
                  <> ", "
                  <> int.to_string(i),
              )
            #(v, b)
          }
        }
      },
    )
  let #(d0, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  "
        <> d0
        <> " = insertvalue "
        <> ty_s
        <> " undef, i8 "
        <> int.to_string(index)
        <> ", 0",
    )
  let #(d1, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  "
        <> d1
        <> " = insertvalue "
        <> ty_s
        <> " "
        <> d0
        <> ", "
        <> var_ty
        <> " "
        <> payload
        <> ", "
        <> int.to_string(index + 1),
    )
  let #(raw, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  "
        <> raw
        <> " = call i8* @gleamc_box_alloc_meta(i64 "
        <> ty_size_expr(TNamed(type_name), recursive)
        <> ", void (i8*)* @Gleamc_BoxDrop_"
        <> mangle_glue(TNamed(type_name))
        <> "_drop)",
    )
  let #(p, b) = fresh(b)
  let b =
    emit_line(b, "  " <> p <> " = bitcast i8* " <> raw <> " to " <> ty_s <> "*")
  let b =
    emit_line(b, "  store " <> ty_s <> " " <> d1 <> ", " <> ty_s <> "* " <> p)
  let b = emit_line(b, "  ret i8* " <> raw)
  let b = emit_line(b, "}")
  string.join(list.reverse(b.lines), "\n") <> "\n"
}

fn variant_index_fields(variants, ctor) -> #(Int, List(#(String, Type))) {
  list.fold(
    list.index_map(variants, fn(v, i) { #(v, i) }),
    #(0, []),
    fn(acc, pair) {
      let #(variant, i) = pair
      let ast.Variant(name, fields) = variant
      // Monomorphisation renames a constructor to `<Base>_<Type>` (e.g.
      // `ProcessDown_process_Down`), so match on the base name.
      let base = case list.last(string.split(name, ".")) {
        Ok(last) -> last
        Error(_) -> name
      }
      case base == ctor || string.starts_with(base, ctor <> "_") {
        True -> #(i, fields)
        False -> acc
      }
    },
  )
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
          let ir.Local(_, ty, _) = local
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
    ir.OpClosureEnv(_, _, ty) -> [ty]
    ir.OpRetain(src, ty) ->
      case src == frame.frame_local {
        True -> []
        False -> [ty]
      }
    ir.OpDrop(src, ty) ->
      case src == frame.frame_local {
        True -> []
        False -> [ty]
      }
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
            || runtime_declared(builtin_symbol(builtin))
          {
            True -> Error(Nil)
            False -> Ok(builtin_decl(builtin, ret_ty, args, by_name, recursive))
          }
        _ -> Error(Nil)
      }
    })
  })
}

/// The set of functions emitted with a heap frame (a closure captures one of
/// their locals).
fn machine_set(module: ir.Module) -> Dict(String, Bool) {
  frame.machine_functions(module)
  |> list.fold(dict.new(), fn(acc, name) { dict.insert(acc, name, True) })
}

/// The functions emitted as a `_step` + wrapper state machine: those that
/// suspend or that delegate to another machine (an async tail call).
fn suspend_set(module: ir.Module) -> Dict(String, Bool) {
  let ir.Module(functions) = module
  let targets = frame.task_targets(module)
  list.fold(functions, dict.new(), fn(acc, function) {
    case
      frame.has_suspend(function)
      || frame.has_tail_machine(function)
      || list.contains(targets, function.name)
    {
      True -> dict.insert(acc, function.name, True)
      False -> acc
    }
  })
}

/// Parameter types of every function, keyed by name. Used to decide whether a
/// `musttail` call has matching caller/callee prototypes.
fn function_signatures(
  functions: List(ir.Function),
) -> Dict(String, List(Type)) {
  list.fold(functions, dict.new(), fn(acc, function) {
    let ir.Function(name, params, _, _, locals) = function
    let by_name = locals_map(locals)
    dict.insert(acc, name, list.map(params, fn(p) { local_type(by_name, p) }))
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
  signatures: Dict(String, List(Type)),
  machine_fns: Dict(String, ir.Function),
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
      signatures: signatures,
      machine_fns: machine_fns,
      frame: None,
      frame_fields: dict.new(),
      reg_locals: reg_locals_map(locals),
    )
  let b = new_builder()
  let b = seed_reg_params(ctx, params, b)
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
  let ret_s = llvm_ty(ret, recursive)
  let sret = abi.ret_needs_sret(ret, recursive)
  let params_s = case sret {
    True ->
      "ptr sret("
      <> ret_s
      <> ") %__out"
      <> case args {
        [] -> ""
        _ -> ", " <> string.join(args, ", ")
      }
    False -> string.join(args, ", ")
  }
  "define "
  <> case sret {
    True -> "void"
    False -> ret_s
  }
  <> " @Gleamc_"
  <> name
  <> "("
  <> params_s
  <> ") {\n"
  <> string.join(lines, "\n")
  <> "\n}\n"
}

// ---------------------------------------------------------------------------
// state machine: frame struct + step + driver wrapper
// ---------------------------------------------------------------------------

fn function_name(function: ir.Function) -> String {
  let ir.Function(name, _, _, _, _) = function
  name
}

fn unique_locals(locals: List(ir.Local)) -> List(ir.Local) {
  let #(_, rev) =
    list.fold(locals, #(dict.new(), []), fn(acc, local) {
      let #(seen, rev) = acc
      let ir.Local(name, _, _) = local
      case dict.get(seen, name) {
        Ok(_) -> acc
        Error(_) -> #(dict.insert(seen, name, True), [local, ..rev])
      }
    })
  list.reverse(rev)
}

fn is_nil_type(ty: Type) -> Bool {
  case ty {
    ast.TNil -> True
    TNamed("Nil") -> True
    _ -> False
  }
}

fn block_index_of(blocks: List(ir.Block)) -> Dict(String, Int) {
  list.index_map(blocks, fn(block, index) {
    let ir.Block(label, _, _) = block
    #(label, index)
  })
  |> dict.from_list
}

fn frame_info(function: ir.Function, _recursive) -> FrameInfo {
  let ir.Function(name, _, ret, blocks, locals) = function
  let uniq = unique_locals(locals)
  let fields =
    dict.from_list(
      list.index_map(uniq, fn(local, index) {
        let ir.Local(n, _, _) = local
        #(n, index)
      }),
    )
  let state = list.length(uniq)
  let fut = state + 1
  let result = case is_nil_type(ret) {
    True -> fut
    False -> fut + 1
  }
  FrameInfo(
    "%__frame_" <> safe(name),
    "%__fr",
    fields,
    state,
    fut,
    result,
    block_index_of(blocks),
  )
}

/// The set of locals owned by a function's frame (see `frame.frame_field_names`).
fn frame_field_set(function: ir.Function) -> Dict(String, Bool) {
  list.fold(frame.frame_field_names(function), dict.new(), fn(acc, name) {
    dict.insert(acc, name, True)
  })
}

/// Whether an argument to a machine start / tail call still has a reference held
/// by the caller frame (only frame fields do), i.e. whether the callee needs an
/// extra retain.
fn arg_needs_retain(ctx: Ctx, arg: ir.Operand) -> Bool {
  case arg {
    ir.Var(name) -> dict.has_key(ctx.frame_fields, name)
    ir.Lit(_) -> False
  }
}

/// The teardown of a frame type `%__frame_<fn>`: at refcount 1->0 it drops the
/// frame-owned fields (the ones `ownership` keeps live), then frees the cell.
fn frame_drop_sym(fr_ty: String) -> String {
  string.drop_start(fr_ty, 1) <> "_drop"
}

fn emit_frame_drop(function, recursive, fields_of, lits) -> String {
  let ir.Function(name, params, ret, _, locals) = function
  let info = frame_info(function, recursive)
  let FrameInfo(fr_ty, _, fields, _, _, result_idx, _) = info
  let by_name = locals_map(locals)
  // The frame's owned fields are the values stored into it (the demote emits an
  // `OpFrameSet` per field), plus the result slot of a machine: `copy_result`
  // retains the result for the caller, so the frame keeps (and must release)
  // its own reference.
  let owned =
    list.fold(op_list(function), dict.new(), fn(acc, op) {
      case op {
        ir.OpFrameSet(_, slot, value) -> {
          let ty = operand_type(by_name, value)
          case ownership.needs_drop_in(ty, fields_of, recursive) {
            True -> dict.insert(acc, slot, ty)
            False -> acc
          }
        }
        _ -> acc
      }
    })
  let owned = case
    frame.has_suspend(function) || frame.has_tail_machine(function)
  {
    True -> {
      // The machine wrapper / `OpMachineStart` places the arguments in the
      // frame (there is no `OpFrameSet` for them), so the frame owns them.
      let with_params =
        list.fold(params, owned, fn(acc, param) {
          let ty = case dict.get(by_name, param) {
            Ok(t) -> t
            Error(_) -> ast.TNil
          }
          case ownership.needs_drop_in(ty, fields_of, recursive) {
            True ->
              case dict.get(fields, param) {
                Ok(slot) -> dict.insert(acc, slot, ty)
                Error(_) -> acc
              }
            False -> acc
          }
        })
      case ownership.needs_drop_in(ret, fields_of, recursive) {
        True -> dict.insert(with_params, result_idx, ret)
        False -> with_params
      }
    }
    False -> owned
  }
  let owned = dict.to_list(owned)
  let done = "fd_" <> safe(name) <> "_done"
  let body = "fd_" <> safe(name) <> "_body"
  let teardown = "fd_" <> safe(name) <> "_teardown"
  let rel = "fd_" <> safe(name) <> "_rel"
  let b = new_builder()
  let b =
    emit_line(b, "define void @" <> frame_drop_sym(fr_ty) <> "(i8* %env) {")
  let b = emit_line(b, "  %isnull = icmp eq i8* %env, null")
  let b =
    emit_line(b, "  br i1 %isnull, label %" <> done <> ", label %" <> body)
  let b = emit_line(b, "\n" <> body <> ":")
  let #(hp, b) = fresh(b)
  let #(hh, b) = fresh(b)
  let #(rc, b) = fresh(b)
  let #(last, b) = fresh(b)
  let b = emit_line(b, "  " <> hp <> " = getelementptr i8, i8* %env, i64 -8")
  let b = emit_line(b, "  " <> hh <> " = bitcast i8* " <> hp <> " to i64*")
  let b = emit_line(b, "  " <> rc <> " = load i64, i64* " <> hh)
  let b = emit_line(b, "  " <> last <> " = icmp eq i64 " <> rc <> ", 1")
  let b =
    emit_line(
      b,
      "  br i1 " <> last <> ", label %" <> teardown <> ", label %" <> rel,
    )
  let b = emit_line(b, "\n" <> teardown <> ":")
  let #(e, b) = fresh(b)
  let b = emit_line(b, "  " <> e <> " = bitcast i8* %env to " <> fr_ty <> "*")
  let b =
    list.fold(owned, b, fn(b, pair) {
      let #(slot, ty) = pair
      let #(gp, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> gp
            <> " = getelementptr "
            <> fr_ty
            <> ", "
            <> fr_ty
            <> "* "
            <> e
            <> ", i32 0, i32 "
            <> int.to_string(slot),
        )
      let ty_s = llvm_ty(ty, recursive)
      let #(fv, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> fv <> " = load " <> ty_s <> ", " <> ty_s <> "* " <> gp,
        )
      rc_expr(lits, recursive, fields_of, "drop", ty, ty_s, fv, "frame", b)
    })
  // Release a captured environment (retained when the frame was allocated by
  // the wrapper or `OpTaskStartClosure`).
  let b = case frame.env_capture(function) {
    Ok(env_ty) ->
      case dict.get(fields, "__env") {
        Ok(slot) -> {
          let #(gp, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  "
                <> gp
                <> " = getelementptr "
                <> fr_ty
                <> ", "
                <> fr_ty
                <> "* "
                <> e
                <> ", i32 0, i32 "
                <> int.to_string(slot),
            )
          let #(ev, b) = fresh(b)
          let b = emit_line(b, "  " <> ev <> " = load i8*, i8** " <> gp)
          emit_line(
            b,
            "  call void @"
              <> frame_drop_sym("%" <> env_ty)
              <> "(i8* "
              <> ev
              <> ")",
          )
        }
        Error(_) -> b
      }
    Error(_) -> b
  }
  let b =
    emit_line(
      b,
      "  call void @Gleamc_rc_release(i8* %env, "
        <> cstring_arg(lits, "frame")
        <> ")",
    )
  let b = emit_line(b, "  br label %" <> done)
  let b = emit_line(b, "\n" <> rel <> ":")
  let b =
    emit_line(
      b,
      "  call void @Gleamc_rc_release(i8* %env, "
        <> cstring_arg(lits, "frame")
        <> ")",
    )
  let b = emit_line(b, "  br label %" <> done)
  let b = emit_line(b, "\n" <> done <> ":")
  let b = emit_line(b, "  ret void")
  string.join(list.reverse(b.lines), "\n") <> "\n}\n"
}

fn frame_type_decl(function: ir.Function, recursive) -> String {
  let ir.Function(_, _, ret, _, locals) = function
  let field_tys =
    list.map(unique_locals(locals), fn(local) {
      let ir.Local(_, ty, _) = local
      llvm_ty(ty, recursive)
    })
  let tail = case is_nil_type(ret) {
    True -> ["i32", "i8*"]
    False -> ["i32", "i8*", llvm_ty(ret, recursive)]
  }
  "%__frame_"
  <> safe(function_name(function))
  <> " = type { "
  <> string.join(list.append(field_tys, tail), ", ")
  <> " }"
}

/// Reads an awaited value from a pending future into `dest` and releases the
/// future. `Gleamc_uv_await_*` drives the loop to completion; the scheduler has
/// already waited, so it returns immediately.
fn emit_await_read(
  ctx: Ctx,
  dest: String,
  fut_v: String,
  b: Builder,
) -> Builder {
  let dest_ty = local_type(ctx.by_name, dest)
  let b = case is_nil_type(dest_ty) {
    True ->
      emit_line(b, "  call void @Gleamc_uv_await_nil(i8* " <> fut_v <> ")")
    False ->
      case dest_ty {
        TNamed("BitArray") -> {
          let #(val, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  "
                <> val
                <> " = call %GleamcBitArray @Gleamc_uv_await_bytes(i8* "
                <> fut_v
                <> ")",
            )
          store_local(ctx, dest, "%GleamcBitArray", val, b)
        }
        _ -> {
          let b =
            emit_line(
              b,
              "  call void @Gleamc_uv_await_nil(i8* " <> fut_v <> ")",
            )
          let #(val, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  "
                <> val
                <> " = call i64 @Gleamc_uv_result(i8* "
                <> fut_v
                <> ")",
            )
          store_local(ctx, dest, "i64", val, b)
        }
      }
  }
  emit_line(b, "  call void @Gleamc_rc_release(i8* " <> fut_v <> ", i8* null)")
}

/// Boxed await (`process_ffi.receive` / `task_ffi.await`): the future carries a box
/// (`value_p`); move the payload into `dest`, free the (now empty) box, then
/// release the future. Works for any destination representation.
fn emit_await_box(
  ctx: Ctx,
  dest: String,
  fut_v: String,
  release: Bool,
  b: Builder,
) -> Builder {
  let dest_ty = local_type(ctx.by_name, dest)
  let #(box, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  " <> box <> " = call i8* @Gleamc_uv_await_box(i8* " <> fut_v <> ")",
    )
  let b = case is_nil_type(dest_ty) {
    True -> b
    False -> {
      let ty_s = llvm_ty(dest_ty, ctx.recursive)
      let #(slot, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> slot <> " = bitcast i8* " <> box <> " to " <> ty_s <> "*",
        )
      let #(val, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> val <> " = load " <> ty_s <> ", " <> ty_s <> "* " <> slot,
        )
      store_local(ctx, dest, ty_s, val, b)
    }
  }
  let b = emit_line(b, "  call void @gleamc_box_free_moved(i8* " <> box <> ")")
  case release {
    True ->
      emit_line(
        b,
        "  call void @Gleamc_rc_release(i8* " <> fut_v <> ", i8* null)",
      )
    False -> b
  }
}

/// Emits the blocks of a machine `step`: a suspension stores the pending future
/// and the resume state and returns "not done"; a resume block reads the awaited
/// value; a `Ret` stores the result and returns "done".
fn emit_machine_blocks(
  ctx: Ctx,
  info: FrameInfo,
  resumes: Dict(String, #(String, ir.ResumeMode)),
  blocks: List(ir.Block),
  b: Builder,
) {
  let FrameInfo(
    fr_ty,
    _reg,
    _fields,
    state_idx,
    fut_idx,
    _result_idx,
    block_index,
  ) = info
  case blocks {
    [] -> #(b, Nil)
    [block, ..rest] -> {
      let ir.Block(label, ops, term) = block
      let b = emit_line(b, "\n" <> block_name(ctx, label) <> ":")
      let b = case dict.get(resumes, label) {
        Ok(#(dest, mode)) -> {
          let #(fp, b) = frame_gep("%__fr", fr_ty, fut_idx, b)
          let #(fv, b) = fresh(b)
          let b = emit_line(b, "  " <> fv <> " = load i8*, i8** " <> fp)
          let b = case mode {
            // A started machine already wrote the result into `dest`; just
            // release the completion future.
            ir.Machine ->
              emit_line(
                b,
                "  call void @Gleamc_rc_release(i8* " <> fv <> ", i8* null)",
              )
            ir.Host -> emit_await_read(ctx, dest, fv, b)
            ir.Boxed -> emit_await_box(ctx, dest, fv, True, b)
            ir.BoxedBorrow -> emit_await_box(ctx, dest, fv, False, b)
          }
          let #(fp2, b) = frame_gep("%__fr", fr_ty, fut_idx, b)
          emit_line(b, "  store i8* null, i8** " <> fp2)
        }
        Error(_) -> b
      }
      let b = case term {
        // A machine tail call delegates to the callee and returns to the driver.
        ir.TailMachine(fun, args) -> {
          let #(b, _) = emit_ops(ctx, ops, b)
          emit_machine_tail(ctx, info, fun, args, b)
        }
        _ -> {
          let #(b, _) = emit_ops(ctx, ops, b)
          case term {
            ir.Suspend(fut, _dest, resume, _machine) -> {
              let #(_, fv, b) = read_val(ctx, fut, b)
              let #(fp, b) = frame_gep("%__fr", fr_ty, fut_idx, b)
              let b = emit_line(b, "  store i8* " <> fv <> ", i8** " <> fp)
              let resume_idx = case dict.get(block_index, resume) {
                Ok(i) -> i
                Error(_) -> 0
              }
              let #(sp, b) = frame_gep("%__fr", fr_ty, state_idx, b)
              let b =
                emit_line(
                  b,
                  "  store i32 " <> int.to_string(resume_idx) <> ", i32* " <> sp,
                )
              emit_line(b, "  ret i1 false")
            }
            _ -> emit_machine_term(ctx, info, term, b)
          }
        }
      }
      emit_machine_blocks(ctx, info, resumes, rest, b)
    }
  }
}

fn emit_machine_term(
  ctx: Ctx,
  info: FrameInfo,
  term: ir.Terminator,
  b: Builder,
) {
  let FrameInfo(fr_ty, _reg, _fields, _state, _fut, result_idx, _) = info
  let ret_ty = llvm_ty(ctx.ret, ctx.recursive)
  case term {
    ir.Ret(value) ->
      case is_nil_type(ctx.ret) {
        True -> emit_line(b, "  ret i1 true")
        False -> {
          let #(_, v, b) = read_val(ctx, value, b)
          let #(rp, b) = frame_gep("%__fr", fr_ty, result_idx, b)
          let b =
            emit_line(
              b,
              "  store " <> ret_ty <> " " <> v <> ", " <> ret_ty <> "* " <> rp,
            )
          emit_line(b, "  ret i1 true")
        }
      }
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
    // A tail call from a suspending function is a plain call: the machine cannot
    // keep the caller's frame across it. Store the result and finish the step.
    ir.Tailcall(fun, args) -> {
      let #(b, arg_list) = read_args(ctx, args, b)
      case abi.ret_needs_sret(ctx.ret, ctx.recursive) {
        True -> {
          let ret_s = llvm_ty(ctx.ret, ctx.recursive)
          let #(tmp, b) = fresh(b)
          let b = emit_line(b, "  " <> tmp <> " = alloca " <> ret_s)
          let b =
            emit_line(
              b,
              "  call void @Gleamc_"
                <> fun
                <> "(ptr sret("
                <> ret_s
                <> ") "
                <> tmp
                <> case arg_list {
                "" -> ""
                _ -> ", " <> arg_list
              }
                <> ")",
            )
          let #(r, b) = fresh(b)
          let b =
            emit_line(b, "  " <> r <> " = load " <> ret_s <> ", ptr " <> tmp)
          emit_machine_finish(ctx, info, r, b)
        }
        False -> {
          let #(r, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  "
                <> r
                <> " = call "
                <> ret_ty
                <> " @Gleamc_"
                <> fun
                <> "("
                <> arg_list
                <> ")",
            )
          emit_machine_finish(ctx, info, r, b)
        }
      }
    }
    ir.TailcallIndirect(fval, args) -> {
      let fn_ty = operand_type(ctx.by_name, fval)
      let fn_s = llvm_ty(fn_ty, ctx.recursive)
      let #(_, fv, b) = read_val(ctx, fval, b)
      let #(code, b) = extract_value(fn_s, fv, [0], b)
      let #(env, b) = extract_value(fn_s, fv, [1], b)
      let #(b, arg_list) = read_args(ctx, args, b)
      case abi.ret_needs_sret(ctx.ret, ctx.recursive) {
        True -> {
          let ret_s = llvm_ty(ctx.ret, ctx.recursive)
          let #(tmp, b) = fresh(b)
          let b = emit_line(b, "  " <> tmp <> " = alloca " <> ret_s)
          let b =
            emit_line(
              b,
              "  call void "
                <> code
                <> "(ptr sret("
                <> ret_s
                <> ") "
                <> tmp
                <> ", i8* "
                <> env
                <> case arg_list {
                "" -> ""
                _ -> ", " <> arg_list
              }
                <> ")",
            )
          let #(r, b) = fresh(b)
          let b =
            emit_line(b, "  " <> r <> " = load " <> ret_s <> ", ptr " <> tmp)
          emit_machine_finish(ctx, info, r, b)
        }
        False -> {
          let callargs = case arg_list {
            "" -> "i8* " <> env
            _ -> "i8* " <> env <> ", " <> arg_list
          }
          let #(r, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  "
                <> r
                <> " = call "
                <> ret_ty
                <> " "
                <> code
                <> "("
                <> callargs
                <> ")",
            )
          emit_machine_finish(ctx, info, r, b)
        }
      }
    }
    // Handled by `emit_machine_blocks` before reaching here.
    ir.Suspend(_, _, _, _) -> emit_line(b, "  unreachable")
    ir.TailMachine(_, _) -> emit_line(b, "  unreachable")
    ir.Unreachable -> emit_line(b, "  unreachable")
  }
}

/// Stores a step's result in the frame (unless nil) and returns "done".
fn emit_machine_finish(
  ctx: Ctx,
  info: FrameInfo,
  value: String,
  b: Builder,
) -> Builder {
  let FrameInfo(fr_ty, _reg, _fields, _state, _fut, result_idx, _) = info
  let ret_ty = llvm_ty(ctx.ret, ctx.recursive)
  let b = case is_nil_type(ctx.ret) {
    True -> b
    False -> {
      let #(rp, b) = frame_gep("%__fr", fr_ty, result_idx, b)
      emit_line(
        b,
        "  store " <> ret_ty <> " " <> value <> ", " <> ret_ty <> "* " <> rp,
      )
    }
  }
  emit_line(b, "  ret i1 true")
}

/// Lowers a tail async call: build the callee's frame with the arguments,
/// release this machine's frame (there is no continuation), and delegate the
/// current task to the callee. The driver retargets the task, so a tail-call
/// chain keeps a constant number of tasks and native frames.
fn emit_machine_tail(
  ctx: Ctx,
  info: FrameInfo,
  fun: String,
  args: List(ir.Operand),
  b: Builder,
) -> Builder {
  case dict.get(ctx.machine_fns, fun) {
    Error(_) -> emit_line(b, "  ret i1 false")
    Ok(callee) -> {
      let cinfo = frame_info(callee, ctx.recursive)
      let FrameInfo(cfr_ty, _creg, cfields, cstate, cfut, _cresult, _) = cinfo
      let ir.Function(_, cparams, cret, _, _) = callee
      let #(raw, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> raw
            <> " = call i8* @gleamc_alloc0(i64 ptrtoint ("
            <> cfr_ty
            <> "* getelementptr ("
            <> cfr_ty
            <> ", "
            <> cfr_ty
            <> "* null, i32 1) to i64))",
        )
      let #(cfrp, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> cfrp <> " = bitcast i8* " <> raw <> " to " <> cfr_ty <> "*",
        )
      let #(sp, b) = frame_gep(cfrp, cfr_ty, cstate, b)
      let b = emit_line(b, "  store i32 0, i32* " <> sp)
      let #(fp, b) = frame_gep(cfrp, cfr_ty, cfut, b)
      let b = emit_line(b, "  store i8* null, i8** " <> fp)
      let b =
        list.fold(list.index_map(args, fn(a, i) { #(a, i) }), b, fn(b, pair) {
          let #(arg, i) = pair
          case list_nth(cparams, i) {
            Ok(pname) -> {
              let #(ty, v, b) = read_val(ctx, arg, b)
              let aty = operand_type(ctx.by_name, arg)
              // Only an argument the *caller frame still owns* needs a retain:
              // the caller frame is released here and drops its fields. A moved
              // local already hands its reference to the callee.
              let b = case arg_needs_retain(ctx, arg) {
                True ->
                  rc_expr(
                    ctx.lits,
                    ctx.recursive,
                    dict.new(),
                    "retain",
                    aty,
                    ty,
                    v,
                    "machine_tail",
                    b,
                  )
                False -> b
              }
              // A capturing callee owns a reference to its environment for the
              // life of its frame (released by the frame drop).
              let b = case pname == "__env" {
                True ->
                  case frame.env_capture(callee) {
                    Ok(_) ->
                      emit_line(
                        b,
                        "  call void @Gleamc_rc_retain(i8* "
                          <> v
                          <> ", i8* null)",
                      )
                    Error(_) -> b
                  }
                False -> b
              }
              let slot = case dict.get(cfields, pname) {
                Ok(found) -> found
                Error(_) -> 0
              }
              let #(ptr, b) = frame_gep(cfrp, cfr_ty, slot, b)
              emit_line(
                b,
                "  store " <> ty <> " " <> v <> ", " <> ty <> "* " <> ptr,
              )
            }
            Error(_) -> b
          }
        })
      // Release this machine's frame: the task no longer refers to it.
      let FrameInfo(fr_ty, _reg, _fields, _state, _fut, _result, _) = info
      let #(caller_frp, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> caller_frp <> " = bitcast " <> fr_ty <> "* %__fr to i8*",
        )
      let b =
        emit_line(
          b,
          "  call void @"
            <> frame_drop_sym(fr_ty)
            <> "(i8* "
            <> caller_frp
            <> ")",
        )
      let #(futp, b) = frame_gep(cfrp, cfr_ty, cfut, b)
      let copy = case is_nil_type(cret) {
        True -> "void (i8*, i8*)* null"
        False ->
          "void (i8*, i8*)* bitcast (void ("
          <> cfr_ty
          <> "*, i8*)* @"
          <> copy_sym(cfr_ty)
          <> " to void (i8*, i8*)*)"
      }
      let step =
        "i1 (i8*)* bitcast (i1 ("
        <> cfr_ty
        <> "*)* @Gleamc_"
        <> fun
        <> "_step to i1 (i8*)*)"
      let fd =
        "void (i8*)* bitcast (void ("
        <> cfr_ty
        <> "*)* @"
        <> frame_drop_sym(cfr_ty)
        <> " to void (i8*)*)"
      let b =
        emit_line(
          b,
          "  call void @gleamc_task_tail("
            <> step
            <> ", i8* "
            <> raw
            <> ", "
            <> copy
            <> ", i8** "
            <> futp
            <> ", "
            <> fd
            <> ")",
        )
      emit_line(b, "  ret i1 false")
    }
  }
}

/// An async function is a flat state machine: a `_step` that switches on a
/// frame `state`, and a wrapper that starts a task and drives it through
/// `gleamc_run_until`. A suspension hands the future to libuv and yields; the
/// resume block reads the value; a `TailMachine` delegates to another machine
/// through `gleamc_task_tail`. The driver task owns the frame and runs its
/// teardown when the machine finishes or delegates (the step suppresses
/// `OpDrop(frame)`).
fn emit_machine_function(
  function: ir.Function,
  recursive,
  lits,
  custom_types,
  custom_by_name,
  ctors,
  tuples,
  signatures,
  machine_fns,
) -> String {
  let ir.Function(name, params, ret, raw_blocks, locals) = function
  let blocks =
    list.map(raw_blocks, fn(block) {
      let ir.Block(label, ops, term) = block
      ir.Block(
        label,
        list.filter(ops, fn(op) {
          case op {
            ir.OpDrop(src, _) -> src != frame.frame_local
            _ -> True
          }
        }),
        term,
      )
    })
  let info = frame_info(function, recursive)
  let FrameInfo(
    fr_ty,
    _fr_reg,
    _fields,
    state_idx,
    _fut_idx,
    _result_idx,
    _block_index,
  ) = info
  let ctx =
    Ctx(
      recursive: recursive,
      by_name: locals_map(locals),
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
      signatures: signatures,
      machine_fns: machine_fns,
      frame: Some(info),
      frame_fields: frame_field_set(function),
      reg_locals: dict.new(),
    )
  let resumes =
    list.fold(blocks, dict.new(), fn(acc, block) {
      case block.term {
        ir.Suspend(_, dest, resume, machine) ->
          dict.insert(acc, resume, #(dest, machine))
        _ -> acc
      }
    })
  let b = new_builder()
  let b =
    emit_line(
      b,
      "define i1 @Gleamc_" <> name <> "_step(" <> fr_ty <> "* %__fr) {",
    )
  let b = emit_frame_locals(ctx, fr_ty, locals, b)
  let #(sp, b) = frame_gep("%__fr", fr_ty, state_idx, b)
  let #(sv, b) = fresh(b)
  let b = emit_line(b, "  " <> sv <> " = load i32, i32* " <> sp)
  let arms =
    list.index_map(blocks, fn(block, index) {
      let ir.Block(label, _, _) = block
      " i32 " <> int.to_string(index) <> ", label %" <> block_name(ctx, label)
    })
  let b =
    emit_line(
      b,
      "  switch i32 "
        <> sv
        <> ", label %__bad [ "
        <> string.join(arms, " ")
        <> " ]",
    )
  let b = emit_line(b, "\n__bad:")
  let b = emit_line(b, "  unreachable")
  let #(b, _) = emit_machine_blocks(ctx, info, resumes, blocks, b)
  let step = string.join(list.reverse(b.lines), "\n") <> "\n}\n"
  let wrapper = emit_machine_wrapper(function, info, recursive)
  let copy = emit_copy_result(function, recursive, lits)
  step <> "\n" <> copy <> "\n" <> wrapper
}

fn emit_machine_wrapper(
  function: ir.Function,
  info: FrameInfo,
  recursive: Dict(String, Bool),
) -> String {
  let ir.Function(name, params, ret, _, locals) = function
  let FrameInfo(fr_ty, _reg, fields, state_idx, fut_idx, _result_idx, _) = info
  let by_name = locals_map(locals)
  let ret_ty = llvm_ty(ret, recursive)
  let nil = is_nil_type(ret)
  let sret = abi.ret_needs_sret(ret, recursive)
  let args =
    list.map(params, fn(param) {
      llvm_ty(local_type(by_name, param), recursive) <> " %arg." <> safe(param)
    })
  let sig_args = case sret {
    True ->
      "ptr sret("
      <> ret_ty
      <> ") %__out"
      <> case args {
        [] -> ""
        _ -> ", " <> string.join(args, ", ")
      }
    False -> string.join(args, ", ")
  }
  let b = new_builder()
  let b =
    emit_line(
      b,
      "define "
        <> case sret {
        True -> "void"
        False -> ret_ty
      }
        <> " @Gleamc_"
        <> name
        <> "("
        <> sig_args
        <> ") {",
    )
  let b =
    emit_line(
      b,
      "  %__fr_raw = call i8* @gleamc_alloc0(i64 ptrtoint ("
        <> fr_ty
        <> "* getelementptr ("
        <> fr_ty
        <> ", "
        <> fr_ty
        <> "* null, i32 1) to i64))",
    )
  let b = emit_line(b, "  %__fr = bitcast i8* %__fr_raw to " <> fr_ty <> "*")
  let b = emit_line(b, "  %__frp = bitcast " <> fr_ty <> "* %__fr to i8*")
  let b =
    list.fold(params, b, fn(b, param) {
      let pty = llvm_ty(local_type(by_name, param), recursive)
      let index = case dict.get(fields, param) {
        Ok(found) -> found
        Error(_) -> 0
      }
      let #(ptr, b) = frame_gep("%__fr", fr_ty, index, b)
      emit_line(
        b,
        "  store "
          <> pty
          <> " %arg."
          <> safe(param)
          <> ", "
          <> pty
          <> "* "
          <> ptr,
      )
    })
  // A capturing machine owns a reference to its environment for the life of the
  // frame (released by the frame drop).
  let b = case frame.env_capture(function) {
    Ok(_) ->
      emit_line(b, "  call void @Gleamc_rc_retain(i8* %arg.__env, i8* null)")
    Error(_) -> b
  }
  let #(sp, b) = frame_gep("%__fr", fr_ty, state_idx, b)
  let b = emit_line(b, "  store i32 0, i32* " <> sp)
  let #(fp, b) = frame_gep("%__fr", fr_ty, fut_idx, b)
  let b = emit_line(b, "  store i8* null, i8** " <> fp)
  let #(futp, b) = frame_gep("%__fr", fr_ty, fut_idx, b)
  let #(dst_arg, b) = case sret {
    True -> #("i8* %__out", b)
    False ->
      case nil {
        True -> #("i8* null", b)
        False -> {
          let b = emit_line(b, "  %__out = alloca " <> ret_ty)
          #("i8* %__out", b)
        }
      }
  }
  let copy = case nil {
    True -> "void (i8*, i8*)* null"
    False ->
      "void (i8*, i8*)* bitcast (void ("
      <> fr_ty
      <> "*, i8*)* @"
      <> copy_sym(fr_ty)
      <> " to void (i8*, i8*)*)"
  }
  let step =
    "i1 (i8*)* bitcast (i1 ("
    <> fr_ty
    <> "*)* @Gleamc_"
    <> name
    <> "_step to i1 (i8*)*)"
  let fd =
    "void (i8*)* bitcast (void ("
    <> fr_ty
    <> "*)* @"
    <> frame_drop_sym(fr_ty)
    <> " to void (i8*)*)"
  let #(donef, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  "
        <> donef
        <> " = call i8* @gleamc_task_start("
        <> step
        <> ", i8* %__frp, i8** "
        <> futp
        <> ", "
        <> copy
        <> ", "
        <> dst_arg
        <> ", "
        <> fd
        <> ")",
    )
  let b = emit_line(b, "  call void @gleamc_run_until(i8* " <> donef <> ")")
  // The root does not await its own completion future.
  let b =
    emit_line(
      b,
      "  call void @Gleamc_rc_release(i8* " <> donef <> ", i8* null)",
    )
  let b = case sret {
    True -> emit_line(b, "  ret void")
    False ->
      case nil {
        True -> emit_line(b, "  ret i32 0")
        False -> {
          let #(rv, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  " <> rv <> " = load " <> ret_ty <> ", " <> ret_ty <> "* %__out",
            )
          emit_line(b, "  ret " <> ret_ty <> " " <> rv)
        }
      }
  }
  string.join(list.reverse(b.lines), "\n") <> "\n}\n"
}

/// Copies a machine's result out of its frame into a caller slot. The driver
/// calls it when the machine finishes, before releasing the frame.
fn emit_copy_result(
  function: ir.Function,
  recursive: Dict(String, Bool),
  lits,
) -> String {
  let ir.Function(_, _, ret, _, _) = function
  let info = frame_info(function, recursive)
  let FrameInfo(fr_ty, _reg, _fields, _state, _fut, result_idx, _) = info
  let ret_ty = llvm_ty(ret, recursive)
  let b = new_builder()
  let b =
    emit_line(
      b,
      "define void @"
        <> copy_sym(fr_ty)
        <> "("
        <> fr_ty
        <> "* %__fr, i8* %dst) {",
    )
  let b = case is_nil_type(ret) {
    True -> b
    False -> {
      let #(rp, b) = frame_gep("%__fr", fr_ty, result_idx, b)
      let #(v, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> v <> " = load " <> ret_ty <> ", " <> ret_ty <> "* " <> rp,
        )
      // The frame owns the result and drops it when released; take a reference
      // for the caller, whose copy is handed over as an owned value.
      let b =
        rc_expr(
          lits,
          recursive,
          dict.new(),
          "retain",
          ret,
          ret_ty,
          v,
          "copy_result",
          b,
        )
      let #(dp, b) = fresh(b)
      let b =
        emit_line(b, "  " <> dp <> " = bitcast i8* %dst to " <> ret_ty <> "*")
      emit_line(
        b,
        "  store " <> ret_ty <> " " <> v <> ", " <> ret_ty <> "* " <> dp,
      )
    }
  }
  let b = emit_line(b, "  ret void")
  string.join(list.reverse(b.lines), "\n") <> "\n}\n"
}

/// Emits the `step` (switch on state) and the wrapper that drives it through
/// `gleamc_run_until`. Locals live in the frame, so they survive a suspension.
/// A function that only needs a heap frame (a closure captures its locals) but
/// never suspends: allocate the frame, store the arguments, run the body once
/// and return the value. No step/state/fut/scheduler.
fn emit_frame_function(
  function: ir.Function,
  recursive,
  lits,
  custom_types,
  custom_by_name,
  ctors,
  tuples,
  signatures,
  machine_fns,
) -> String {
  let ir.Function(name, params, ret, blocks, locals) = function
  let info = frame_info(function, recursive)
  let FrameInfo(fr_ty, _fr_reg, fields, _state, _fut, _result, _block_index) =
    info
  let by_name = locals_map(locals)
  let ret_ty = llvm_ty(ret, recursive)
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
      signatures: signatures,
      machine_fns: machine_fns,
      frame: Some(info),
      frame_fields: frame_field_set(function),
      reg_locals: dict.new(),
    )
  let args =
    list.map(params, fn(param) {
      llvm_ty(local_type(by_name, param), recursive) <> " %arg." <> safe(param)
    })
  let sret = abi.ret_needs_sret(ret, recursive)
  let params_s = case sret {
    True ->
      "ptr sret("
      <> ret_ty
      <> ") %__out"
      <> case args {
        [] -> ""
        _ -> ", " <> string.join(args, ", ")
      }
    False -> string.join(args, ", ")
  }
  let b = new_builder()
  let b =
    emit_line(
      b,
      "define "
        <> case sret {
        True -> "void"
        False -> ret_ty
      }
        <> " @Gleamc_"
        <> name
        <> "("
        <> params_s
        <> ") {",
    )
  let b =
    emit_line(
      b,
      "  %__fr_raw = call i8* @gleamc_alloc0(i64 ptrtoint ("
        <> fr_ty
        <> "* getelementptr ("
        <> fr_ty
        <> ", "
        <> fr_ty
        <> "* null, i32 1) to i64))",
    )
  let b = emit_line(b, "  %__fr = bitcast i8* %__fr_raw to " <> fr_ty <> "*")
  let b = emit_line(b, "  %__frp = bitcast " <> fr_ty <> "* %__fr to i8*")
  let b =
    list.fold(params, b, fn(b, param) {
      let pty = llvm_ty(local_type(by_name, param), recursive)
      let index = case dict.get(fields, param) {
        Ok(found) -> found
        Error(_) -> 0
      }
      let #(ptr, b) = frame_gep("%__fr", fr_ty, index, b)
      emit_line(
        b,
        "  store "
          <> pty
          <> " %arg."
          <> safe(param)
          <> ", "
          <> pty
          <> "* "
          <> ptr,
      )
    })
  // Retain the captured environment (released by the frame drop).
  let b = case frame.env_capture(function) {
    Ok(_) ->
      emit_line(b, "  call void @Gleamc_rc_retain(i8* %arg.__env, i8* null)")
    Error(_) -> b
  }
  let b = emit_frame_locals(ctx, fr_ty, locals, b)
  let b = emit_line(b, "  br label %" <> ctx.entry)
  let #(b, _) = emit_block_list(ctx, blocks, b)
  string.join(list.reverse(b.lines), "\n") <> "\n}\n"
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
      let ir.Local(name, ty, storage) = local
      case storage {
        ir.Reg -> b
        ir.Slot -> {
          let ty_s = llvm_ty(ty, ctx.recursive)
          emit_line(b, "  " <> local_ptr(ctx, name) <> " = alloca " <> ty_s)
        }
      }
    })
  list.fold(params, b, fn(b, param) {
    case dict.has_key(ctx.reg_locals, param) {
      True -> b
      False -> {
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
      }
    }
  })
}

/// Bind every promoted parameter to its incoming `%arg.<name>` register, so
/// `read_val` finds it in the `Builder`'s value map instead of loading a slot.
fn seed_reg_params(ctx: Ctx, params: List(String), b: Builder) -> Builder {
  list.fold(params, b, fn(b, param) {
    case dict.has_key(ctx.reg_locals, param) {
      True ->
        Builder(
          ..b,
          values: dict.insert(b.values, param, "%arg." <> safe(param)),
        )
      False -> b
    }
  })
}

fn emit_block_list(ctx: Ctx, blocks: List(ir.Block), b: Builder) {
  case blocks {
    [] -> #(b, Nil)
    [block, ..rest] -> {
      let ir.Block(label, ops, term) = block
      let b = emit_line(b, "\n" <> block_name(ctx, label) <> ":")
      let b = case term {
        ir.Ret(_) | ir.Tailcall(_, _) | ir.TailcallIndirect(_, _) -> {
          let #(body, drops) = split_drops(ops)
          let #(b, _) = emit_ops(ctx, body, b)
          emit_exit_term(ctx, term, drops, b)
        }
        _ -> {
          let #(b, _) = emit_ops(ctx, ops, b)
          emit_term(ctx, term, b)
        }
      }
      emit_block_list(ctx, rest, b)
    }
  }
}

/// Splits a trailing run of `OpDrop`s off an op list, so a terminator's
/// operands can be read before the values they use are released.
fn split_drops(ops: List(ir.Op)) -> #(List(ir.Op), List(ir.Op)) {
  let rev = list.reverse(ops)
  let drops = list.take_while(rev, is_drop)
  #(list.reverse(list.drop(rev, list.length(drops))), list.reverse(drops))
}

fn is_drop(op: ir.Op) -> Bool {
  case op {
    ir.OpDrop(_, _) -> True
    _ -> False
  }
}

fn emit_drops(ctx: Ctx, drops: List(ir.Op), b: Builder) -> Builder {
  case drops {
    [] -> b
    [op, ..rest] -> {
      let #(b, _) = emit_op(ctx, op, b)
      emit_drops(ctx, rest, b)
    }
  }
}

/// Emits a terminator that leaves the function (`Ret`, `Tailcall`,
/// `TailcallIndirect`). Operands are read first, then the trailing drops are
/// emitted, then the transfer — so a `musttail` call is immediately followed by
/// its `ret`.
fn emit_exit_term(
  ctx: Ctx,
  term: ir.Terminator,
  drops: List(ir.Op),
  b: Builder,
) {
  case term {
    ir.Ret(value) -> {
      let ret_ty = llvm_ty(ctx.ret, ctx.recursive)
      let #(_, v, b) = read_val(ctx, value, b)
      let b = emit_drops(ctx, drops, b)
      case abi.ret_needs_sret(ctx.ret, ctx.recursive) {
        True -> {
          let b =
            emit_line(b, "  store " <> ret_ty <> " " <> v <> ", ptr %__out")
          emit_line(b, "  ret void")
        }
        False -> emit_line(b, "  ret " <> ret_ty <> " " <> v)
      }
    }
    ir.Tailcall(fun, args) -> {
      let #(b, arg_list) = read_args(ctx, args, b)
      let b = emit_drops(ctx, drops, b)
      emit_tail_call(ctx, "@Gleamc_" <> fun, arg_list, musttail_ok(ctx, fun), b)
    }
    ir.TailcallIndirect(fval, args) -> {
      // A function value that owns a frame (a local closure) must stay alive
      // through the call: its environment is the callee's frame, and releasing
      // the closure drops that frame. So the closure's own drops are emitted
      // *after* the call, not before; the call cannot be `musttail`.
      let fn_ty = operand_type(ctx.by_name, fval)
      let fn_s = llvm_ty(fn_ty, ctx.recursive)
      let #(_, fv, b) = read_val(ctx, fval, b)
      let #(code, b) = extract_value(fn_s, fv, [0], b)
      let #(env, b) = extract_value(fn_s, fv, [1], b)
      let #(b, arg_list) = read_args(ctx, args, b)
      let ret_s = llvm_ty(ctx.ret, ctx.recursive)
      case abi.ret_needs_sret(ctx.ret, ctx.recursive) {
        True -> {
          let b =
            emit_line(
              b,
              "  call void "
                <> code
                <> "(ptr sret("
                <> ret_s
                <> ") %__out"
                <> ", i8* "
                <> env
                <> case arg_list {
                "" -> ""
                _ -> ", " <> arg_list
              }
                <> ")",
            )
          let b = emit_drops(ctx, drops, b)
          emit_line(b, "  ret void")
        }
        False -> {
          let callargs = case arg_list {
            "" -> "i8* " <> env
            _ -> "i8* " <> env <> ", " <> arg_list
          }
          let #(r, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  "
                <> r
                <> " = call "
                <> ret_s
                <> " "
                <> code
                <> "("
                <> callargs
                <> ")",
            )
          let b = emit_drops(ctx, drops, b)
          emit_line(b, "  ret " <> ret_s <> " " <> r)
        }
      }
    }
    _ -> emit_term(ctx, term, b)
  }
}

/// Emits a tail transfer: `musttail` when the return type allows it, otherwise a
/// plain call followed by `ret`. A `musttail` call must be immediately followed
/// by its `ret`; a large aggregate return goes through an sret pointer and
/// aborts the backend under `musttail`, so it falls back to a normal call.
fn emit_tail_call(
  ctx: Ctx,
  callee: String,
  args: String,
  musttail_ok: Bool,
  b: Builder,
) -> Builder {
  let ret_s = llvm_ty(ctx.ret, ctx.recursive)
  let marker = case musttail_ok {
    True -> "musttail call "
    False -> "call "
  }
  case abi.ret_needs_sret(ctx.ret, ctx.recursive) {
    True -> {
      let b =
        emit_line(
          b,
          "  "
            <> marker
            <> "void "
            <> callee
            <> "(ptr sret("
            <> ret_s
            <> ") %__out"
            <> case args {
            "" -> ""
            _ -> ", " <> args
          }
            <> ")",
        )
      emit_line(b, "  ret void")
    }
    False -> {
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> r
            <> " = "
            <> marker
            <> ret_s
            <> " "
            <> callee
            <> "("
            <> args
            <> ")",
        )
      emit_line(b, "  ret " <> ret_s <> " " <> r)
    }
  }
}

/// Whether a return value of `ty` is lowered to an `sret` out pointer by the C
/// ABI (a large aggregate). Such a value must be returned through an **explicit**
/// sret parameter: `musttail` forbids the automatic sret conversion, but an
/// explicit one is a plain pointer argument that can be forwarded unchanged.
fn musttail_ok(ctx: Ctx, fun: String) -> Bool {
  prototype_matches(ctx, fun)
}

fn prototype_matches(ctx: Ctx, fun: String) -> Bool {
  case dict.get(ctx.signatures, fun) {
    Error(_) -> False
    Ok(callee_params) -> {
      let caller =
        list.map(ctx.params, fn(param) {
          llvm_ty(local_type(ctx.by_name, param), ctx.recursive)
        })
      let callee =
        list.map(callee_params, fn(ty) { llvm_ty(ty, ctx.recursive) })
      caller == callee
    }
  }
}

fn local_ptr(ctx: Ctx, name: String) -> String {
  "%l." <> ctx.prefix <> safe(name)
}

/// The address of a local. A frame function has already emitted `%l.<name>` as a
/// GEP into the frame (`emit_frame_locals`); a plain function has emitted it as
/// an entry alloca. Either way `%l.<name>` is the address.
fn local_addr(ctx: Ctx, name: String, b: Builder) -> #(String, Builder) {
  #(local_ptr(ctx, name), b)
}

/// The current frame pointer for `base`. The frame pointer is the fixed `%__fr`
/// for every frame function, so this is the identity.
fn frame_base(base: String, _fr_ty: String, b: Builder) -> #(String, Builder) {
  #(base, b)
}

/// The generated symbol that copies a machine's result out of its frame.
fn copy_sym(fr_ty: String) -> String {
  string.drop_start(fr_ty, 1) <> "_copy_result"
}

fn list_nth(items: List(a), index: Int) -> Result(a, Nil) {
  case items {
    [] -> Error(Nil)
    [first, ..rest] ->
      case index {
        0 -> Ok(first)
        _ -> list_nth(rest, index - 1)
      }
  }
}

fn frame_gep(
  base: String,
  fr_ty: String,
  index: Int,
  b: Builder,
) -> #(String, Builder) {
  let #(base, b) = frame_base(base, fr_ty, b)
  let #(reg, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  "
        <> reg
        <> " = getelementptr inbounds "
        <> fr_ty
        <> ", "
        <> fr_ty
        <> "* "
        <> base
        <> ", i32 0, i32 "
        <> int.to_string(index),
    )
  #(reg, b)
}

/// In a machine `step`, locals are frame fields: pre-emit `%l.<name>` as a GEP
/// so every existing `local_ptr(ctx, name)` keeps working unchanged.
fn emit_frame_locals(
  ctx: Ctx,
  fr_ty: String,
  locals: List(ir.Local),
  b: Builder,
) {
  list.fold(unique_locals(locals), b, fn(b, local) {
    let ir.Local(name, _, _) = local
    case ctx.frame {
      Some(FrameInfo(_, fr_reg, fields, _, _, _, _)) ->
        case dict.get(fields, name) {
          Ok(index) -> {
            let #(base, b) = frame_base(fr_reg, fr_ty, b)
            emit_line(
              b,
              "  "
                <> local_ptr(ctx, name)
                <> " = getelementptr inbounds "
                <> fr_ty
                <> ", "
                <> fr_ty
                <> "* "
                <> base
                <> ", i32 0, i32 "
                <> int.to_string(index),
            )
          }
          Error(_) -> b
        }
      None -> b
    }
  })
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

fn emit_op(ctx: Ctx, op: ir.Op, b: Builder) -> #(Builder, Nil) {
  case op {
    ir.OpConst(dest, value) -> emit_op_const(ctx, dest, value, b)
    ir.OpBinop(dest, op_name, left, right) ->
      emit_op_binop(ctx, dest, op_name, left, right, b)
    ir.OpUnop(dest, op_name, operand) ->
      emit_op_unop(ctx, dest, op_name, operand, b)
    ir.OpCall(dest, fun, args, ret_ty) ->
      emit_op_call(ctx, dest, fun, args, ret_ty, b)
    ir.OpMachineStart(fut, fun, args, result_dest) ->
      emit_op_machine_start(ctx, fut, fun, args, result_dest, b)
    ir.OpTaskStart(fut, fun, args, into_future) ->
      emit_op_task_start(ctx, fut, fun, args, into_future, b)
    ir.OpTaskStartClosure(fut, fun, closure, into_future) ->
      emit_op_task_start_closure(ctx, fut, fun, closure, into_future, b)
    ir.OpBuiltin(dest, builtin, args, ret_ty) ->
      emit_op_builtin(ctx, dest, builtin, args, ret_ty, b)
    ir.OpCopy(dest, src, ty) -> emit_op_copy(ctx, dest, src, ty, b)
    ir.OpPhi(dest, incoming) -> emit_op_phi(ctx, dest, incoming, b)
    ir.OpRetain(src, ty) -> emit_op_retain(ctx, src, ty, b)
    ir.OpDrop(src, ty) -> emit_op_drop(ctx, src, ty, b)
    ir.OpTuple(dest, elems, ty) -> emit_op_tuple(ctx, dest, elems, ty, b)
    ir.OpTupleGet(dest, tuple, index, ty) ->
      emit_op_tuple_get(ctx, dest, tuple, index, ty, b)
    ir.OpCtor(dest, ctor, type_name, args, ty) ->
      emit_op_ctor(ctx, dest, ctor, type_name, args, ty, b)
    ir.OpTagIs(dest, subject, ctor, type_name) ->
      emit_op_tag_is(ctx, dest, subject, ctor, type_name, b)
    ir.OpField(dest, subject, ctor, index, ty) ->
      emit_op_field(ctx, dest, subject, ctor, index, ty, b)
    ir.OpClosure(dest, code, _, env_ty, fn_ty) ->
      emit_op_closure(ctx, dest, code, env_ty, fn_ty, b)
    ir.OpEnvGet(dest, env_ty, index, ty) ->
      emit_op_env_get(ctx, dest, env_ty, index, ty, b)
    ir.OpCallIndirect(dest, fval, args, ret_ty) ->
      emit_op_call_indirect(ctx, dest, fval, args, ret_ty, b)
    ir.OpClosureEnv(dest, closure, ty) ->
      emit_op_closure_env(ctx, dest, closure, ty, b)
    ir.OpBitArray(dest, elems, _) -> emit_op_bit_array(ctx, dest, elems, b)
    ir.OpFrameNew(_, _) -> emit_op_frame_new(ctx, b)
    ir.OpFrameGet(dest, _, index, ty) ->
      emit_op_frame_get(ctx, dest, index, ty, b)
    ir.OpFrameSet(_, index, value) -> emit_op_frame_set(ctx, index, value, b)
  }
}

fn emit_op_const(
  ctx: Ctx,
  dest: String,
  value: ir.Literal,
  b: Builder,
) -> #(Builder, Nil) {
  let #(ty, val, b) = read_literal(ctx, value, b)
  let b = store_local(ctx, dest, ty, val, b)
  #(b, Nil)
}

fn emit_op_binop(
  ctx: Ctx,
  dest: String,
  op_name: String,
  left: ir.Operand,
  right: ir.Operand,
  b: Builder,
) -> #(Builder, Nil) {
  let #(lty, lv, b) = read_val(ctx, left, b)
  let #(_, rv, b) = read_val(ctx, right, b)
  let oty = operand_type(ctx.by_name, left)
  case op_name == "==" || op_name == "!=", is_eq_special_ty(oty) {
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

fn emit_op_unop(
  ctx: Ctx,
  dest: String,
  op_name: String,
  operand: ir.Operand,
  b: Builder,
) -> #(Builder, Nil) {
  let #(ty, v, b) = read_val(ctx, operand, b)
  let #(rhs, res_ty) = unop_rhs(op_name, ty, v)
  let #(tmp, b) = fresh(b)
  let b = emit_line(b, "  " <> tmp <> " = " <> rhs)
  let b = store_local(ctx, dest, res_ty, tmp, b)
  #(b, Nil)
}

fn emit_op_call(
  ctx: Ctx,
  dest: String,
  fun: String,
  args: List(ir.Operand),
  ret_ty: Type,
  b: Builder,
) -> #(Builder, Nil) {
  let #(b, arg_list) = read_args(ctx, args, b)
  let ret_s = llvm_ty(ret_ty, ctx.recursive)
  case abi.ret_needs_sret(ret_ty, ctx.recursive) {
    // The callee writes the aggregate into `dest`'s own slot.
    True -> {
      let #(destp, b) = local_addr(ctx, dest, b)
      let b =
        emit_line(
          b,
          "  call void @Gleamc_"
            <> fun
            <> "(ptr sret("
            <> ret_s
            <> ") "
            <> destp
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
            <> " @Gleamc_"
            <> fun
            <> "("
            <> arg_list
            <> ")",
        )
      let b = store_local(ctx, dest, ret_s, tmp, b)
      #(b, Nil)
    }
  }
}

fn emit_op_machine_start(
  ctx: Ctx,
  fut: String,
  fun: String,
  args: List(ir.Operand),
  result_dest: String,
  b: Builder,
) -> #(Builder, Nil) {
  case dict.get(ctx.machine_fns, fun) {
    Error(_) -> #(b, Nil)
    Ok(callee) -> {
      let info = frame_info(callee, ctx.recursive)
      let FrameInfo(fr_ty, _reg, fields, state_idx, fut_idx, _result_idx, _) =
        info
      let ir.Function(_, cparams, cret, _, _) = callee
      let #(raw, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> raw
            <> " = call i8* @gleamc_alloc0(i64 ptrtoint ("
            <> fr_ty
            <> "* getelementptr ("
            <> fr_ty
            <> ", "
            <> fr_ty
            <> "* null, i32 1) to i64))",
        )
      let #(frp, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> frp <> " = bitcast i8* " <> raw <> " to " <> fr_ty <> "*",
        )
      let #(sp, b) = frame_gep(frp, fr_ty, state_idx, b)
      let b = emit_line(b, "  store i32 0, i32* " <> sp)
      let #(fp, b) = frame_gep(frp, fr_ty, fut_idx, b)
      let b = emit_line(b, "  store i8* null, i8** " <> fp)
      let b =
        list.fold(list.index_map(args, fn(a, i) { #(a, i) }), b, fn(b, pair) {
          let #(arg, i) = pair
          case list_nth(cparams, i) {
            Ok(pname) -> {
              let #(ty, v, b) = read_val(ctx, arg, b)
              // The callee owns its arguments. Retain only when the caller
              // frame still owns the value (it releases it later); a moved
              // local already hands its reference to the callee.
              let aty = operand_type(ctx.by_name, arg)
              let b = case arg_needs_retain(ctx, arg) {
                True ->
                  rc_expr(
                    ctx.lits,
                    ctx.recursive,
                    dict.new(),
                    "retain",
                    aty,
                    ty,
                    v,
                    "machine_start",
                    b,
                  )
                False -> b
              }
              // A capturing callee owns a reference to its environment for the
              // life of its frame (released by the frame drop).
              let b = case pname == "__env" {
                True ->
                  case frame.env_capture(callee) {
                    Ok(_) ->
                      emit_line(
                        b,
                        "  call void @Gleamc_rc_retain(i8* "
                          <> v
                          <> ", i8* null)",
                      )
                    Error(_) -> b
                  }
                False -> b
              }
              let slot = case dict.get(fields, pname) {
                Ok(found) -> found
                Error(_) -> 0
              }
              let #(ptr, b) = frame_gep(frp, fr_ty, slot, b)
              emit_line(
                b,
                "  store " <> ty <> " " <> v <> ", " <> ty <> "* " <> ptr,
              )
            }
            Error(_) -> b
          }
        })
      let #(futp, b) = frame_gep(frp, fr_ty, fut_idx, b)
      let copy = case is_nil_type(cret) {
        True -> "void (i8*, i8*)* null"
        False ->
          "void (i8*, i8*)* bitcast (void ("
          <> fr_ty
          <> "*, i8*)* @"
          <> copy_sym(fr_ty)
          <> " to void (i8*, i8*)*)"
      }
      let #(dst_arg, b) = case is_nil_type(cret) {
        True -> #("i8* null", b)
        False -> {
          let #(dstp, b) = local_addr(ctx, result_dest, b)
          #("i8* " <> dstp, b)
        }
      }
      let step =
        "i1 (i8*)* bitcast (i1 ("
        <> fr_ty
        <> "*)* @Gleamc_"
        <> fun
        <> "_step to i1 (i8*)*)"
      let fd =
        "void (i8*)* bitcast (void ("
        <> fr_ty
        <> "*)* @"
        <> frame_drop_sym(fr_ty)
        <> " to void (i8*)*)"
      let #(donef, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> donef
            <> " = call i8* @gleamc_task_start("
            <> step
            <> ", i8* "
            <> raw
            <> ", i8** "
            <> futp
            <> ", "
            <> copy
            <> ", "
            <> dst_arg
            <> ", "
            <> fd
            <> ")",
        )
      let b = store_local(ctx, fut, "i8*", donef, b)
      #(b, Nil)
    }
  }
}

fn emit_op_task_start(
  ctx: Ctx,
  fut: String,
  fun: String,
  args: List(ir.Operand),
  into_future: Bool,
  b: Builder,
) -> #(Builder, Nil) {
  case dict.get(ctx.machine_fns, fun) {
    Error(_) -> #(b, Nil)
    Ok(callee) -> {
      let info = frame_info(callee, ctx.recursive)
      let FrameInfo(fr_ty, _reg, fields, state_idx, fut_idx, _result_idx, _) =
        info
      let ir.Function(_, cparams, cret, _, _) = callee
      let #(raw, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> raw
            <> " = call i8* @gleamc_alloc0(i64 ptrtoint ("
            <> fr_ty
            <> "* getelementptr ("
            <> fr_ty
            <> ", "
            <> fr_ty
            <> "* null, i32 1) to i64))",
        )
      let #(frp, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> frp <> " = bitcast i8* " <> raw <> " to " <> fr_ty <> "*",
        )
      let #(sp, b) = frame_gep(frp, fr_ty, state_idx, b)
      let b = emit_line(b, "  store i32 0, i32* " <> sp)
      let #(fp, b) = frame_gep(frp, fr_ty, fut_idx, b)
      let b = emit_line(b, "  store i8* null, i8** " <> fp)
      let b =
        list.fold(list.index_map(args, fn(a, i) { #(a, i) }), b, fn(b, pair) {
          let #(arg, i) = pair
          case list_nth(cparams, i) {
            Ok(pname) -> {
              let #(ty, v, b) = read_val(ctx, arg, b)
              let aty = operand_type(ctx.by_name, arg)
              let b = case arg_needs_retain(ctx, arg) {
                True ->
                  rc_expr(
                    ctx.lits,
                    ctx.recursive,
                    dict.new(),
                    "retain",
                    aty,
                    ty,
                    v,
                    "task_start",
                    b,
                  )
                False -> b
              }
              let slot = case dict.get(fields, pname) {
                Ok(found) -> found
                Error(_) -> 0
              }
              let #(ptr, b) = frame_gep(frp, fr_ty, slot, b)
              emit_line(
                b,
                "  store " <> ty <> " " <> v <> ", " <> ty <> "* " <> ptr,
              )
            }
            Error(_) -> b
          }
        })
      let #(futp, b) = frame_gep(frp, fr_ty, fut_idx, b)
      let copy = case is_nil_type(cret) {
        True -> "void (i8*, i8*)* null"
        False ->
          "void (i8*, i8*)* bitcast (void ("
          <> fr_ty
          <> "*, i8*)* @"
          <> copy_sym(fr_ty)
          <> " to void (i8*, i8*)*)"
      }
      let step =
        "i1 (i8*)* bitcast (i1 ("
        <> fr_ty
        <> "*)* @Gleamc_"
        <> fun
        <> "_step to i1 (i8*)*)"
      let fd =
        "void (i8*)* bitcast (void ("
        <> fr_ty
        <> "*)* @"
        <> frame_drop_sym(fr_ty)
        <> " to void (i8*)*)"
      // `task.async` boxes the worker's result so `task_ffi.await` can move any
      // type out; a nil result needs no box.
      let #(box, b) = case is_nil_type(cret) {
        True -> #("null", b)
        False -> {
          let #(bx, b) = fresh(b)
          let b = emit_box_alloc(ctx, bx, cret, b)
          #(bx, b)
        }
      }
      let #(donef, b) = fresh(b)
      let b = case into_future {
        True ->
          emit_line(
            b,
            "  "
              <> donef
              <> " = call i8* @gleamc_task_async("
              <> step
              <> ", i8* "
              <> raw
              <> ", i8** "
              <> futp
              <> ", "
              <> copy
              <> ", "
              <> fd
              <> ", i8* "
              <> box
              <> ")",
          )
        False ->
          emit_line(
            b,
            "  "
              <> donef
              <> " = call i8* @gleamc_task_spawn("
              <> step
              <> ", i8* "
              <> raw
              <> ", i8** "
              <> futp
              <> ", "
              <> fd
              <> ")",
          )
      }
      // `task.async` keeps the completion future as the `Task(a)` handle;
      // `process.spawn` returns the stable `Pid` (the task's id).
      let b = case into_future {
        True -> store_local(ctx, fut, "i8*", donef, b)
        False -> {
          let #(id, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  " <> id <> " = call i64 @gleamc_task_id(i8* " <> donef <> ")",
            )
          store_local(ctx, fut, "i64", id, b)
        }
      }
      #(b, Nil)
    }
  }
}

fn emit_op_task_start_closure(
  ctx: Ctx,
  fut: String,
  fun: String,
  closure: ir.Operand,
  into_future: Bool,
  b: Builder,
) -> #(Builder, Nil) {
  case dict.get(ctx.machine_fns, fun) {
    Error(_) -> #(b, Nil)
    Ok(callee) -> {
      let info = frame_info(callee, ctx.recursive)
      let FrameInfo(fr_ty, _reg, fields, state_idx, fut_idx, _result_idx, _) =
        info
      let ir.Function(_, cparams, cret, _, _) = callee
      // Read the closure value and take its environment (field 1).
      let clo_ty = operand_type(ctx.by_name, closure)
      let clo_s = llvm_ty(clo_ty, ctx.recursive)
      let #(_, fv, b) = read_val(ctx, closure, b)
      let #(env, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> env <> " = extractvalue " <> clo_s <> " " <> fv <> ", 1",
        )
      // The task's frame owns a reference to the environment; the frame
      // drop releases it.
      let b = case frame.env_capture(callee) {
        Ok(_) ->
          emit_line(
            b,
            "  call void @Gleamc_rc_retain(i8* " <> env <> ", i8* null)",
          )
        Error(_) -> b
      }
      let #(raw, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> raw
            <> " = call i8* @gleamc_alloc0(i64 ptrtoint ("
            <> fr_ty
            <> "* getelementptr ("
            <> fr_ty
            <> ", "
            <> fr_ty
            <> "* null, i32 1) to i64))",
        )
      let #(frp, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> frp <> " = bitcast i8* " <> raw <> " to " <> fr_ty <> "*",
        )
      let #(sp, b) = frame_gep(frp, fr_ty, state_idx, b)
      let b = emit_line(b, "  store i32 0, i32* " <> sp)
      let #(fp, b) = frame_gep(frp, fr_ty, fut_idx, b)
      let b = emit_line(b, "  store i8* null, i8** " <> fp)
      // Store the environment into the callee's `__env` field (param 0).
      let b = case cparams {
        [first_param, ..] -> {
          let slot = case dict.get(fields, first_param) {
            Ok(found) -> found
            Error(_) -> 0
          }
          let #(ptr, b) = frame_gep(frp, fr_ty, slot, b)
          emit_line(b, "  store i8* " <> env <> ", i8** " <> ptr)
        }
        [] -> b
      }
      let #(futp, b) = frame_gep(frp, fr_ty, fut_idx, b)
      let copy = case is_nil_type(cret) {
        True -> "void (i8*, i8*)* null"
        False ->
          "void (i8*, i8*)* bitcast (void ("
          <> fr_ty
          <> "*, i8*)* @"
          <> copy_sym(fr_ty)
          <> " to void (i8*, i8*)*)"
      }
      let step =
        "i1 (i8*)* bitcast (i1 ("
        <> fr_ty
        <> "*)* @Gleamc_"
        <> fun
        <> "_step to i1 (i8*)*)"
      let fd =
        "void (i8*)* bitcast (void ("
        <> fr_ty
        <> "*)* @"
        <> frame_drop_sym(fr_ty)
        <> " to void (i8*)*)"
      let #(box, b) = case is_nil_type(cret) {
        True -> #("null", b)
        False -> {
          let #(bx, b) = fresh(b)
          let b = emit_box_alloc(ctx, bx, cret, b)
          #(bx, b)
        }
      }
      let #(donef, b) = fresh(b)
      let b = case into_future {
        True ->
          emit_line(
            b,
            "  "
              <> donef
              <> " = call i8* @gleamc_task_async("
              <> step
              <> ", i8* "
              <> raw
              <> ", i8** "
              <> futp
              <> ", "
              <> copy
              <> ", "
              <> fd
              <> ", i8* "
              <> box
              <> ")",
          )
        False ->
          emit_line(
            b,
            "  "
              <> donef
              <> " = call i8* @gleamc_task_spawn("
              <> step
              <> ", i8* "
              <> raw
              <> ", i8** "
              <> futp
              <> ", "
              <> fd
              <> ")",
          )
      }
      // `task.async` keeps the completion future as the `Task(a)` handle;
      // `process.spawn` returns the stable `Pid` (the task's id).
      let b = case into_future {
        True -> store_local(ctx, fut, "i8*", donef, b)
        False -> {
          let #(id, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  " <> id <> " = call i64 @gleamc_task_id(i8* " <> donef <> ")",
            )
          store_local(ctx, fut, "i64", id, b)
        }
      }
      #(b, Nil)
    }
  }
}

fn emit_op_builtin(
  ctx: Ctx,
  dest: String,
  builtin: String,
  args: List(ir.Operand),
  ret_ty: Type,
  b: Builder,
) -> #(Builder, Nil) {
  case builtin {
    "gleamc.show" -> {
      let first = first_arg(args)
      let oty = operand_type(ctx.by_name, first)
      let #(_, v, b) = read_val(ctx, first, b)
      let #(r, b) = inspect_val(ctx.recursive, ctx.lits, oty, v, b)
      let b = store_local(ctx, dest, "%GleamcString", r, b)
      #(b, Nil)
    }
    "gleamc.hash" -> {
      let first = first_arg(args)
      let oty = operand_type(ctx.by_name, first)
      let #(_, v, b) = read_val(ctx, first, b)
      let #(r, b) = case oty {
        TString -> {
          let #(r, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  "
                <> r
                <> " = call i64 @Gleamc_hash_string(%GleamcString "
                <> v
                <> ")",
            )
          #(r, b)
        }
        ast.TInt -> {
          let #(r, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  " <> r <> " = call i64 @Gleamc_hash_i64(i64 " <> v <> ")",
            )
          #(r, b)
        }
        ast.TFloat -> {
          let #(r, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  " <> r <> " = call i64 @Gleamc_hash_f64(double " <> v <> ")",
            )
          #(r, b)
        }
        ast.TBool -> {
          let #(z, b) = fresh(b)
          let b = emit_line(b, "  " <> z <> " = zext i1 " <> v <> " to i64")
          let #(r, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  " <> r <> " = call i64 @Gleamc_hash_i64(i64 " <> z <> ")",
            )
          #(r, b)
        }
        _ -> {
          // Structural keys (tuples, lists, custom types): hash the
          // canonical `inspect` text. Equal values share a hash.
          let #(s, b) = inspect_val(ctx.recursive, ctx.lits, oty, v, b)
          let #(r, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  "
                <> r
                <> " = call i64 @Gleamc_hash_string(%GleamcString "
                <> s
                <> ")",
            )
          #(r, b)
        }
      }
      let b = store_local(ctx, dest, "i64", r, b)
      #(b, Nil)
    }
    "process_ffi.send" -> {
      // Box the message (ownership moves into the box) and hand the box to
      // the mailbox; the receiver moves the payload out.
      let #(subject_arg, msg_arg) = case args {
        [s, m, ..] -> #(s, m)
        _ -> #(ir.Lit(ir.LUnit), ir.Lit(ir.LUnit))
      }
      let #(_, subject, b) = read_val(ctx, subject_arg, b)
      let #(ty, value, b) = read_val(ctx, msg_arg, b)
      let #(box, b) = fresh(b)
      let b = emit_box_alloc(ctx, box, operand_type(ctx.by_name, msg_arg), b)
      let #(slot, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> slot <> " = bitcast i8* " <> box <> " to " <> ty <> "*",
        )
      let b =
        emit_line(
          b,
          "  store " <> ty <> " " <> value <> ", " <> ty <> "* " <> slot,
        )
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> r
            <> " = call i32 @Gleamc_process_ffi_send(i64 "
            <> subject
            <> ", i8* "
            <> box
            <> ")",
        )
      let b = store_local(ctx, dest, "i32", r, b)
      #(b, Nil)
    }
    // `send_exit_message(pid, message)`: box the `ExitMessage` and deliver it
    // to the target's exit inbox (or terminate it).
    "process_ffi.send_exit_message" -> {
      let #(pid_arg, msg_arg) = case args {
        [p, m, ..] -> #(p, m)
        _ -> #(ir.Lit(ir.LUnit), ir.Lit(ir.LUnit))
      }
      let #(_, pid, b) = read_val(ctx, pid_arg, b)
      let #(ty, value, b) = read_val(ctx, msg_arg, b)
      let #(box, b) = fresh(b)
      let b = emit_box_alloc(ctx, box, operand_type(ctx.by_name, msg_arg), b)
      let #(slot, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> slot <> " = bitcast i8* " <> box <> " to " <> ty <> "*",
        )
      let b =
        emit_line(
          b,
          "  store " <> ty <> " " <> value <> ", " <> ty <> "* " <> slot,
        )
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> r
            <> " = call i32 @Gleamc_process_ffi_send_exit_message(i64 "
            <> pid
            <> ", i8* "
            <> box
            <> ")",
        )
      let b = store_local(ctx, dest, "i32", r, b)
      #(b, Nil)
    }
    "process_ffi.unreceive" -> {
      let #(subject_arg, msg_arg) = case args {
        [s, m, ..] -> #(s, m)
        _ -> #(ir.Lit(ir.LUnit), ir.Lit(ir.LUnit))
      }
      let #(_, subject, b) = read_val(ctx, subject_arg, b)
      let #(ty, value, b) = read_val(ctx, msg_arg, b)
      let #(box, b) = fresh(b)
      let b = emit_box_alloc(ctx, box, operand_type(ctx.by_name, msg_arg), b)
      let #(slot, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> slot <> " = bitcast i8* " <> box <> " to " <> ty <> "*",
        )
      let b =
        emit_line(
          b,
          "  store " <> ty <> " " <> value <> ", " <> ty <> "* " <> slot,
        )
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> r
            <> " = call i32 @Gleamc_process_ffi_unreceive(i64 "
            <> subject
            <> ", i8* "
            <> box
            <> ")",
        )
      let b = store_local(ctx, dest, "i32", r, b)
      #(b, Nil)
    }
    "process_ffi.send_after" -> {
      // Box the message and schedule a libuv timer that sends it.
      let #(subject_arg, delay_arg, msg_arg) = case args {
        [s, d, m, ..] -> #(s, d, m)
        _ -> #(ir.Lit(ir.LUnit), ir.Lit(ir.LUnit), ir.Lit(ir.LUnit))
      }
      let #(_, subject, b) = read_val(ctx, subject_arg, b)
      let #(_, delay, b) = read_val(ctx, delay_arg, b)
      let #(ty, value, b) = read_val(ctx, msg_arg, b)
      let #(box, b) = fresh(b)
      let b = emit_box_alloc(ctx, box, operand_type(ctx.by_name, msg_arg), b)
      let #(slot, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> slot <> " = bitcast i8* " <> box <> " to " <> ty <> "*",
        )
      let b =
        emit_line(
          b,
          "  store " <> ty <> " " <> value <> ", " <> ty <> "* " <> slot,
        )
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> r
            <> " = call i64 @Gleamc_process_ffi_send_after(i64 "
            <> subject
            <> ", i64 "
            <> delay
            <> ", i8* "
            <> box
            <> ")",
        )
      let b = store_local(ctx, dest, "i64", r, b)
      #(b, Nil)
    }
    "buffer.new" -> {
      let elem = case buffer_elem(ret_ty) {
        Ok(e) -> e
        Error(_) -> ast.TNil
      }
      let #(_, n, b) = read_val(ctx, first_arg(args), b)
      let sz = ty_size_expr(elem, ctx.recursive)
      let #(h, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> h
            <> " = call i8* @Gleamc_buffer_new(i64 "
            <> n
            <> ", i64 "
            <> sz
            <> ", "
            <> buffer_glue_fp(elem, "drop")
            <> ")",
        )
      let b = store_local(ctx, dest, "i8*", h, b)
      #(b, Nil)
    }
    "buffer.len" -> {
      let #(_, buf, b) = read_val(ctx, first_arg(args), b)
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> r <> " = call i64 @Gleamc_buffer_len(i8* " <> buf <> ")",
        )
      let b = store_local(ctx, dest, "i64", r, b)
      #(b, Nil)
    }
    "buffer.get" -> {
      let buf_arg = first_arg(args)
      let #(_, buf, b) = read_val(ctx, buf_arg, b)
      let elem = case buffer_elem(operand_type(ctx.by_name, buf_arg)) {
        Ok(e) -> e
        Error(_) -> ast.TNil
      }
      let elem_s = llvm_ty(elem, ctx.recursive)
      let idx = case args {
        [_, i, ..] -> i
        _ -> ir.Lit(ir.LUnit)
      }
      let #(_, i, b) = read_val(ctx, idx, b)
      let #(slot, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> slot
            <> " = call i8* @Gleamc_buffer_slot(i8* "
            <> buf
            <> ", i64 "
            <> i
            <> ")",
        )
      let #(p, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> p <> " = bitcast i8* " <> slot <> " to " <> elem_s <> "*",
        )
      let #(v, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> v <> " = load " <> elem_s <> ", " <> elem_s <> "* " <> p,
        )
      let b =
        rc_expr(
          ctx.lits,
          ctx.recursive,
          dict.new(),
          "retain",
          elem,
          elem_s,
          v,
          "buffer",
          b,
        )
      let b = store_local(ctx, dest, elem_s, v, b)
      #(b, Nil)
    }
    "buffer.set" -> {
      let buf_arg = first_arg(args)
      let #(_, buf, b) = read_val(ctx, buf_arg, b)
      let elem = case buffer_elem(operand_type(ctx.by_name, buf_arg)) {
        Ok(e) -> e
        Error(_) -> ast.TNil
      }
      let elem_s = llvm_ty(elem, ctx.recursive)
      let idx = case args {
        [_, i, ..] -> i
        _ -> ir.Lit(ir.LUnit)
      }
      let value = case args {
        [_, _, v, ..] -> v
        _ -> ir.Lit(ir.LUnit)
      }
      let #(_, i, b) = read_val(ctx, idx, b)
      let #(_, v, b) = read_val(ctx, value, b)
      let sz = ty_size_expr(elem, ctx.recursive)
      let #(nb, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> nb
            <> " = call i8* @Gleamc_buffer_cow(i8* "
            <> buf
            <> ", i64 "
            <> sz
            <> ", "
            <> buffer_glue_fp(elem, "retain")
            <> ", "
            <> buffer_glue_fp(elem, "drop")
            <> ")",
        )
      let #(slot, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> slot
            <> " = call i8* @Gleamc_buffer_slot(i8* "
            <> nb
            <> ", i64 "
            <> i
            <> ")",
        )
      let #(p, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> p <> " = bitcast i8* " <> slot <> " to " <> elem_s <> "*",
        )
      let #(old, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> old <> " = load " <> elem_s <> ", " <> elem_s <> "* " <> p,
        )
      let b =
        rc_expr(
          ctx.lits,
          ctx.recursive,
          dict.new(),
          "drop",
          elem,
          elem_s,
          old,
          "buffer",
          b,
        )
      let b =
        rc_expr(
          ctx.lits,
          ctx.recursive,
          dict.new(),
          "retain",
          elem,
          elem_s,
          v,
          "buffer",
          b,
        )
      let b =
        emit_line(
          b,
          "  store " <> elem_s <> " " <> v <> ", " <> elem_s <> "* " <> p,
        )
      let b = store_local(ctx, dest, "i8*", nb, b)
      #(b, Nil)
    }
    "buffer.take" -> {
      let buf_arg = first_arg(args)
      let #(_, buf, b) = read_val(ctx, buf_arg, b)
      let elem = case buffer_elem(operand_type(ctx.by_name, buf_arg)) {
        Ok(e) -> e
        Error(_) -> ast.TNil
      }
      let elem_s = llvm_ty(elem, ctx.recursive)
      let idx = case args {
        [_, i, ..] -> i
        _ -> ir.Lit(ir.LUnit)
      }
      let #(_, i, b) = read_val(ctx, idx, b)
      let #(outp, b) = local_addr(ctx, dest, b)
      let #(outp_i8, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> outp_i8
            <> " = bitcast "
            <> elem_s
            <> "* "
            <> outp
            <> " to i8*",
        )
      let b =
        emit_line(
          b,
          "  call void @Gleamc_buffer_take(i8* "
            <> buf
            <> ", i64 "
            <> i
            <> ", "
            <> buffer_glue_fp(elem, "retain")
            <> ", i8* "
            <> outp_i8
            <> ")",
        )
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
          "  " <> r <> " = call i32 @Gleamc_io_debug(%GleamcString " <> s <> ")",
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
            emit_line(b, "  " <> r <> " = sext i32 " <> c32 <> " to " <> ret_s)
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
    // `dynamic.from(a)`: box the value and tag it with its class.
    "dynamic_ffi.from" -> {
      let first = first_arg(args)
      let oty = operand_type(ctx.by_name, first)
      let #(ty, value, b) = read_val(ctx, first, b)
      let tag = dynamic_tag_of(oty)
      let #(box, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> box
            <> " = call i8* @gleamc_box_alloc(i64 "
            <> ty_size_expr(oty, ctx.recursive)
            <> ")",
        )
      let #(slot, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> slot <> " = bitcast i8* " <> box <> " to " <> ty <> "*",
        )
      let b =
        emit_line(
          b,
          "  store " <> ty <> " " <> value <> ", " <> ty <> "* " <> slot,
        )
      let drop = case ownership.needs_drop(oty, ctx.ctors) {
        True -> "void (i8*)* @Gleamc_BoxDrop_" <> mangle_glue(oty) <> "_drop"
        False -> "void (i8*)* null"
      }
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  "
            <> r
            <> " = call i8* @Gleamc_dynamic_new(i32 "
            <> int.to_string(tag)
            <> ", i8* "
            <> box
            <> ", "
            <> drop
            <> ")",
        )
      let b = store_local(ctx, dest, "i8*", r, b)
      #(b, Nil)
    }
    // `dynamic.unsafe_coerce` / `dynamic.int` / ...: load the (already
    // class-checked) payload back out of the box.
    "dynamic_ffi.unsafe_coerce"
    | "dynamic_ffi.as_int"
    | "dynamic_ffi.as_float"
    | "dynamic_ffi.as_string"
    | "dynamic_ffi.as_bool" -> {
      let first = first_arg(args)
      let #(_, d, b) = read_val(ctx, first, b)
      let ret_s = llvm_ty(ret_ty, ctx.recursive)
      let #(box, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> box <> " = call i8* @Gleamc_dynamic_bits(i8* " <> d <> ")",
        )
      let #(slot, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> slot <> " = bitcast i8* " <> box <> " to " <> ret_s <> "*",
        )
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> r <> " = load " <> ret_s <> ", " <> ret_s <> "* " <> slot,
        )
      let b = store_local(ctx, dest, ret_s, r, b)
      #(b, Nil)
    }
    _ -> emit_builtin_call(ctx, dest, builtin, args, ret_ty, b)
  }
}

fn emit_op_copy(
  ctx: Ctx,
  dest: String,
  src: ir.Operand,
  ty: Type,
  b: Builder,
) -> #(Builder, Nil) {
  let ty_s = llvm_ty(ty, ctx.recursive)
  let #(_, v, b) = read_val(ctx, src, b)
  let b = store_local(ctx, dest, ty_s, v, b)
  #(b, Nil)
}

fn emit_op_phi(
  ctx: Ctx,
  dest: String,
  incoming: List(#(ir.Operand, String)),
  b: Builder,
) -> #(Builder, Nil) {
  let ty_s = llvm_ty(local_type(ctx.by_name, dest), ctx.recursive)
  // Read each incoming value in the join block (its definition dominates)
  // and form the LLVM `phi` with one `[value, %pred]` per predecessor.
  let #(rev, b) =
    list.fold(incoming, #([], b), fn(acc, pair) {
      let #(rev, b) = acc
      let #(operand, label) = pair
      let #(_, value, b) = read_val(ctx, operand, b)
      #(["[" <> value <> ", %" <> block_name(ctx, label) <> "]", ..rev], b)
    })
  let #(reg, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  "
        <> reg
        <> " = phi "
        <> ty_s
        <> " "
        <> string.join(list.reverse(rev), ", "),
    )
  #(Builder(..b, values: dict.insert(b.values, dest, reg)), Nil)
}

fn emit_op_retain(
  ctx: Ctx,
  src: String,
  ty: Type,
  b: Builder,
) -> #(Builder, Nil) {
  case src == frame.frame_local {
    // The frame handle lives in the machine frame; retaining it for a
    // capturing closure bumps the frame cell itself.
    True ->
      case ctx.frame {
        Some(FrameInfo(fr_ty, fr_reg, _, _, _, _, _)) -> {
          let #(base, b) = frame_base(fr_reg, fr_ty, b)
          let #(p, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  " <> p <> " = bitcast " <> fr_ty <> "* " <> base <> " to i8*",
            )
          #(
            emit_line(
              b,
              "  call void @Gleamc_rc_retain(i8* " <> p <> ", i8* null)",
            ),
            Nil,
          )
        }
        None -> #(b, Nil)
      }
    False -> {
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
  }
}

fn emit_op_drop(
  ctx: Ctx,
  src: String,
  ty: Type,
  b: Builder,
) -> #(Builder, Nil) {
  case src == frame.frame_local {
    // The frame's own reference. Emitted as an op (not at `Ret`) so a
    // `musttail` tail call can release the frame before the call, leaving
    // no instruction between the call and its `ret`.
    True ->
      case ctx.frame {
        Some(FrameInfo(fr_ty, _, _, _, _, _, _)) -> #(
          emit_line(
            b,
            "  call void @" <> frame_drop_sym(fr_ty) <> "(i8* %__frp)",
          ),
          Nil,
        )
        None -> #(b, Nil)
      }
    False -> {
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
  }
}

fn emit_op_tuple(
  ctx: Ctx,
  dest: String,
  elems: List(ir.Operand),
  ty: Type,
  b: Builder,
) -> #(Builder, Nil) {
  let ty_s = llvm_ty(ty, ctx.recursive)
  let #(b, fields) = read_typed_args(ctx, elems, b)
  let #(val, b) = build_struct(b, ty_s, fields)
  let b = store_local(ctx, dest, ty_s, val, b)
  #(b, Nil)
}

fn emit_op_tuple_get(
  ctx: Ctx,
  dest: String,
  tuple: ir.Operand,
  index: Int,
  ty: Type,
  b: Builder,
) -> #(Builder, Nil) {
  let #(ty_s, v, b) = read_val(ctx, tuple, b)
  let #(tmp, b) = extract_value(ty_s, v, [index], b)
  let b = store_local(ctx, dest, llvm_ty(ty, ctx.recursive), tmp, b)
  #(b, Nil)
}

fn emit_op_ctor(
  ctx: Ctx,
  dest: String,
  ctor: String,
  type_name: String,
  args: List(ir.Operand),
  ty: Type,
  b: Builder,
) -> #(Builder, Nil) {
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
          "  " <> tp <> " = bitcast i8* " <> p <> " to %" <> type_name <> "*",
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

fn emit_op_tag_is(
  ctx: Ctx,
  dest: String,
  subject: ir.Operand,
  ctor: String,
  type_name: String,
  b: Builder,
) -> #(Builder, Nil) {
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

fn emit_op_field(
  ctx: Ctx,
  dest: String,
  subject: ir.Operand,
  ctor: String,
  index: Int,
  ty: Type,
  b: Builder,
) -> #(Builder, Nil) {
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

fn emit_op_closure(
  ctx: Ctx,
  dest: String,
  code: String,
  env_ty: String,
  fn_ty: Type,
  b: Builder,
) -> #(Builder, Nil) {
  let fn_s = llvm_ty(fn_ty, ctx.recursive)
  let cty = code_ty(fn_ty, ctx.recursive)
  // A closure that captures the defining frame references it directly (the
  // frame is the environment); no environment cell is allocated, and the
  // frame's release is a plain rc release, so there is no `env_drop`.
  let frame_bound = string.starts_with(env_ty, "__frame_")
  let #(env_reg, env_drop, b) = case frame_bound {
    True ->
      case ctx.frame {
        Some(FrameInfo(fr_ty, fr_reg, _, _, _, _, _)) -> {
          let #(base, b) = frame_base(fr_reg, fr_ty, b)
          let #(frp, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  " <> frp <> " = bitcast " <> fr_ty <> "* " <> base <> " to i8*",
            )
          // Dropping the closure runs the frame's teardown.
          #(frp, "@" <> env_ty <> "_drop", b)
        }
        None -> #("null", "null", b)
      }
    // No captures: a bare function value with no environment.
    False -> #("null", "null", b)
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
        <> env_drop
        <> ", 2",
    )
  // Field 3 is the machine-start entry for an async function (the "coroutine
  // function" descriptor); null for a synchronous function. Populated once the
  // start thunks exist.
  let #(c3, b) = fresh(b)
  let b =
    emit_line(
      b,
      "  " <> c3 <> " = insertvalue " <> fn_s <> " " <> c2 <> ", i8* null, 3",
    )
  let b = store_local(ctx, dest, fn_s, c3, b)
  #(b, Nil)
}

fn emit_op_env_get(
  ctx: Ctx,
  dest: String,
  env_ty: String,
  index: Int,
  ty: Type,
  b: Builder,
) -> #(Builder, Nil) {
  let ty_s = llvm_ty(ty, ctx.recursive)
  let #(envp, b) = local_addr(ctx, "__env", b)
  let #(envraw, b) = fresh(b)
  let b = emit_line(b, "  " <> envraw <> " = load i8*, i8** " <> envp)
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
    emit_line(b, "  " <> v <> " = load " <> ty_s <> ", " <> ty_s <> "* " <> fp)
  let b = store_local(ctx, dest, ty_s, v, b)
  #(b, Nil)
}

fn emit_op_call_indirect(
  ctx: Ctx,
  dest: String,
  fval: ir.Operand,
  args: List(ir.Operand),
  ret_ty: Type,
  b: Builder,
) -> #(Builder, Nil) {
  let fn_ty = operand_type(ctx.by_name, fval)
  let fn_s = llvm_ty(fn_ty, ctx.recursive)
  let #(_, fv, b) = read_val(ctx, fval, b)
  let #(code, b) = extract_value(fn_s, fv, [0], b)
  let #(env, b) = extract_value(fn_s, fv, [1], b)
  let #(b, arg_list) = read_args(ctx, args, b)
  let ret_s = llvm_ty(ret_ty, ctx.recursive)
  case abi.ret_needs_sret(ret_ty, ctx.recursive) {
    True -> {
      let #(destp, b) = local_addr(ctx, dest, b)
      let b =
        emit_line(
          b,
          "  call void "
            <> code
            <> "(ptr sret("
            <> ret_s
            <> ") "
            <> destp
            <> ", i8* "
            <> env
            <> case arg_list {
            "" -> ""
            _ -> ", " <> arg_list
          }
            <> ")",
        )
      #(b, Nil)
    }
    False -> {
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
  }
}

/// Reads the environment pointer (field 1) of a closure value. Used when a
/// known closure code is called directly and needs its env.
fn emit_op_closure_env(
  ctx: Ctx,
  dest: String,
  closure: ir.Operand,
  _ty: Type,
  b: Builder,
) -> #(Builder, Nil) {
  let clo_ty = operand_type(ctx.by_name, closure)
  let clo_s = llvm_ty(clo_ty, ctx.recursive)
  let #(_, fv, b) = read_val(ctx, closure, b)
  let #(env, b) = extract_value(clo_s, fv, [1], b)
  #(store_local(ctx, dest, "i8*", env, b), Nil)
}

fn emit_op_bit_array(
  ctx: Ctx,
  dest: String,
  elems: List(ir.Operand),
  b: Builder,
) -> #(Builder, Nil) {
  let n = list.length(elems)
  let b = case elems {
    [] -> {
      let #(r, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> r <> " = call %GleamcBitArray @Gleamc_bit_array_new(i64 0)",
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

fn emit_op_frame_new(_ctx: Ctx, b: Builder) -> #(Builder, Nil) {
  #(b, Nil)
}

fn emit_op_frame_get(
  ctx: Ctx,
  dest: String,
  index: Int,
  ty: Type,
  b: Builder,
) -> #(Builder, Nil) {
  case ctx.frame {
    Some(FrameInfo(fr_ty, fr_reg, _, _, _, _, _)) -> {
      let ty_s = llvm_ty(ty, ctx.recursive)
      let #(ptr, b) = frame_gep(fr_reg, fr_ty, index, b)
      let #(v, b) = fresh(b)
      let b =
        emit_line(
          b,
          "  " <> v <> " = load " <> ty_s <> ", " <> ty_s <> "* " <> ptr,
        )
      let b = store_local(ctx, dest, ty_s, v, b)
      #(b, Nil)
    }
    None -> #(b, Nil)
  }
}

fn emit_op_frame_set(
  ctx: Ctx,
  index: Int,
  value: ir.Operand,
  b: Builder,
) -> #(Builder, Nil) {
  case ctx.frame {
    Some(FrameInfo(fr_ty, fr_reg, _, _, _, _, _)) -> {
      let #(ty_s, v, b) = read_val(ctx, value, b)
      let #(ptr, b) = frame_gep(fr_reg, fr_ty, index, b)
      #(
        emit_line(
          b,
          "  store " <> ty_s <> " " <> v <> ", " <> ty_s <> "* " <> ptr,
        ),
        Nil,
      )
    }
    None -> #(b, Nil)
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
    // Exit terminators are emitted by `emit_exit_term`, which reads their
    // operands before the trailing drops. Delegating here keeps a safe default
    // (no drops) if `emit_term` is ever called directly.
    ir.Ret(_) | ir.Tailcall(_, _) | ir.TailcallIndirect(_, _) ->
      emit_exit_term(ctx, term, [], b)
    // Suspensions and machine tail calls only appear in machine functions,
    // emitted by `emit_machine_blocks`.
    ir.Suspend(_, _, _, _) -> emit_line(b, "  unreachable")
    ir.TailMachine(_, _) -> emit_line(b, "  unreachable")
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
    ir.Var(name) ->
      case dict.get(b.values, name) {
        // A promoted local (or parameter): it is an SSA register, no load.
        Ok(reg) -> {
          let ty_s = llvm_ty(local_type(ctx.by_name, name), ctx.recursive)
          #(ty_s, reg, b)
        }
        Error(_) -> {
          let ty = local_type(ctx.by_name, name)
          let ty_s = llvm_ty(ty, ctx.recursive)
          let #(ptr, b) = local_addr(ctx, name, b)
          let #(tmp, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  " <> tmp <> " = load " <> ty_s <> ", " <> ty_s <> "* " <> ptr,
            )
          #(ty_s, tmp, b)
        }
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
  case dict.has_key(ctx.reg_locals, dest) {
    // A promoted local: bind the SSA register instead of storing a slot.
    True -> Builder(..b, values: dict.insert(b.values, dest, val))
    False -> {
      let #(ptr, b) = local_addr(ctx, dest, b)
      emit_line(
        b,
        "  store " <> ty_s <> " " <> val <> ", " <> ty_s <> "* " <> ptr,
      )
    }
  }
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
    let ir.Local(name, ty, _) = local
    dict.insert(acc, name, ty)
  })
}

fn reg_locals_map(locals: List(ir.Local)) -> Dict(String, Bool) {
  list.fold(locals, dict.new(), fn(acc, local) {
    let ir.Local(name, _, storage) = local
    case storage {
      ir.Reg -> dict.insert(acc, name, True)
      ir.Slot -> acc
    }
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
    | "Gleamc_hash_string"
    | "Gleamc_hash_i64"
    | "Gleamc_hash_f64"
    | "Gleamc_process_ffi_new_subject"
    | "Gleamc_process_ffi_send"
    | "Gleamc_process_ffi_receive"
    | "Gleamc_process_ffi_send_after"
    | "Gleamc_process_ffi_unreceive"
    | "Gleamc_process_ffi_has_message"
    | "Gleamc_process_ffi_mailbox_len"
    | "Gleamc_process_ffi_subject_handle"
    | "Gleamc_process_ffi_subject_owner"
    | "Gleamc_process_ffi_subject_name"
    | "Gleamc_process_ffi_name_of_int"
    | "Gleamc_process_ffi_monitor_to_int"
    | "Gleamc_process_ffi_flush_messages"
    | "Gleamc_process_ffi_selector_merge"
    | "Gleamc_process_ffi_selector_watch_owned"
    | "Gleamc_process_ffi_selector_other_raw"
    | "Gleamc_process_ffi_traps"
    | "Gleamc_process_ffi_send_exit"
    | "Gleamc_process_ffi_send_exit_message"
    | "Gleamc_dynamic_new"
    | "Gleamc_dynamic_ffi_classify"
    | "Gleamc_dynamic_bits"
    | "Gleamc_process_ffi_monitor_eq"
    | "Gleamc_process_ffi_cancel_timer"
    | "Gleamc_buffer_new"
    | "Gleamc_buffer_len"
    | "Gleamc_buffer_slot"
    | "Gleamc_buffer_cow"
    | "Gleamc_buffer_retain"
    | "Gleamc_buffer_release"
    | "Gleamc_buffer_is_null"
    | "Gleamc_buffer_take"
    | "Gleamc_bit_array_eq"
    | "Gleamc_bit_array_new"
    | "Gleamc_bit_array_from_bytes"
    | "Gleamc_rc_retain"
    | "Gleamc_rc_release"
    | "gleamc_alloc_site" -> True
    _ -> False
  }
}

/// Runtime functions that return or take `GleamcFileResult` (a 32-byte
/// aggregate) use the C ABI: `sret` for the result and `byval` pointers for
/// arguments. Emitting them by value would mismatch clang's lowering.
fn builtin_arg_ty(by_name, recursive, arg) -> String {
  let ty = operand_type(by_name, arg)
  case abi.is_file_result(ty) {
    True -> "ptr byval(%GleamcFileResult)"
    False -> llvm_ty(ty, recursive)
  }
}

/// The element type of `Buffer(elem)`, if `ty` is one. After monomorphisation
/// the type is `TNamed("Buffer_<elem>")`; before it is `TApp("Buffer", [..])`.
fn buffer_elem(ty: Type) -> Result(Type, Nil) {
  case ty {
    ast.TApp("Buffer", [elem]) -> Ok(elem)
    ast.TNamed(name) ->
      case ast.buffer_elem_name(name) {
        Ok(mangled) -> Ok(ast.type_of_mangled(mangled))
        Error(_) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// Monomorphisation's type mangling (`Int`, `List_Int`, ...), used to rebuild
/// the `TNamed("Buffer_<elem>")` buffer type name from an element type.
fn surface_mangle(ty: Type) -> String {
  case ty {
    ast.TInt -> "Int"
    ast.TFloat -> "Float"
    ast.TBool -> "Bool"
    TString -> "String"
    ast.TNil -> "Nil"
    ast.TVar(name) -> name
    TNamed(name) -> name
    ast.TApp(name, args) ->
      name <> "_" <> string.join(list.map(args, surface_mangle), "_")
    ast.TTuple(types) ->
      "t" <> string.join(list.map(types, surface_mangle), "_")
    ast.TFun(params, ret) ->
      "fn_"
      <> string.join(list.map(params, surface_mangle), "_")
      <> "_"
      <> surface_mangle(ret)
  }
}

fn subject_rc(which: String, reg: String, b: Builder) -> Builder {
  let call = case which {
    "retain" -> "Gleamc_subject_retain"
    _ -> "Gleamc_subject_release"
  }
  emit_line(b, "  call void @" <> call <> "(i64 " <> reg <> ")")
}

fn buffer_rc(which: String, reg: String, b: Builder) -> Builder {
  let call = case which {
    "retain" -> "Gleamc_buffer_retain"
    _ -> "Gleamc_buffer_release"
  }
  emit_line(b, "  call void @" <> call <> "(i8* " <> reg <> ")")
}

fn dynamic_rc(which: String, reg: String, b: Builder) -> Builder {
  let call = case which {
    "retain" -> "Gleamc_dynamic_retain"
    _ -> "Gleamc_dynamic_release"
  }
  emit_line(b, "  call void @" <> call <> "(i8* " <> reg <> ")")
}

fn selector_rc(which: String, reg: String, b: Builder) -> Builder {
  let call = case which {
    "retain" -> "Gleamc_selector_retain"
    _ -> "Gleamc_selector_release"
  }
  emit_line(b, "  call void @" <> call <> "(i64 " <> reg <> ")")
}

fn task_rc(which: String, reg: String, b: Builder) -> Builder {
  let call = case which {
    "retain" -> "Gleamc_task_ffi_retain"
    _ -> "Gleamc_task_ffi_release"
  }
  emit_line(b, "  call void @" <> call <> "(i8* " <> reg <> ")")
}

/// `sizeof(ty)` as an i64 constant expression (inlined into a call argument:
/// a standalone `ptrtoint` of a constant expression is rejected by newer LLVM).
fn ty_size_expr(ty: Type, recursive) -> String {
  let ty_s = llvm_ty(ty, recursive)
  "ptrtoint ("
  <> ty_s
  <> "* getelementptr ("
  <> ty_s
  <> ", "
  <> ty_s
  <> "* null, i32 1) to i64)"
}

fn buffer_glue_fp(elem: Type, which: String) -> String {
  "void (i8*)* @Gleamc_Buffer_" <> mangle_glue(elem) <> "_" <> which
}

/// Every `Buffer(T)` element type appearing in the program (custom types,
/// tuples, locals and return types), deduplicated.
fn collect_buffer_elems(custom_types, functions) -> List(Type) {
  let from_custom =
    list.flat_map(custom_types, fn(custom) {
      let ast.CustomType(_, _, _, variants, _) = custom
      list.flat_map(variants, fn(variant) {
        let ast.Variant(_, fields) = variant
        list.flat_map(fields, fn(field) {
          let #(_, ty) = field
          buffer_elems_in(ty)
        })
      })
    })
  let from_fns =
    list.flat_map(functions, fn(function) {
      let ir.Function(_, _, ret, _, locals) = function
      list.append(
        buffer_elems_in(ret),
        list.flat_map(locals, fn(local) {
          let ir.Local(_, ty, _) = local
          buffer_elems_in(ty)
        }),
      )
    })
  let all = list.append(from_custom, from_fns)
  list.fold(all, dict.new(), fn(acc, ty) {
    dict.insert(acc, mangle_glue(ty), ty)
  })
  |> dict.to_list
  |> list.map(fn(pair) {
    let #(_, ty) = pair
    ty
  })
}

fn buffer_elems_in(ty: Type) -> List(Type) {
  case ty {
    ast.TApp("Buffer", [elem]) -> list.append([elem], buffer_elems_in(elem))
    ast.TNamed(name) ->
      case ast.buffer_elem_name(name) {
        Ok(mangled) -> {
          let elem = ast.type_of_mangled(mangled)
          list.append([elem], buffer_elems_in(elem))
        }
        Error(_) -> []
      }
    ast.TApp(_, args) -> list.flat_map(args, buffer_elems_in)
    ast.TTuple(types) -> list.flat_map(types, buffer_elems_in)
    ast.TFun(params, ret) ->
      list.flat_map(list.append(params, [ret]), buffer_elems_in)
    _ -> []
  }
}

/// `void(i8*)` wrappers that load one element from a slot and retain/drop it,
/// so `Gleamc_buffer_cow`/`new` can be handed generic element glue.
fn emit_buffer_glue(
  lits,
  recursive,
  custom_types,
  fields_of,
  elem: Type,
) -> String {
  list.append(
    [
      emit_buffer_slot_glue(
        lits,
        recursive,
        custom_types,
        fields_of,
        "retain",
        elem,
      ),
    ],
    [
      emit_buffer_slot_glue(
        lits,
        recursive,
        custom_types,
        fields_of,
        "drop",
        elem,
      ),
    ],
  )
  |> string.join("\n\n")
}

fn emit_buffer_slot_glue(
  lits,
  recursive,
  _custom_types,
  fields_of,
  which: String,
  elem: Type,
) -> String {
  let ty_s = llvm_ty(elem, recursive)
  let name = "Gleamc_Buffer_" <> mangle_glue(elem) <> "_" <> which
  let b = new_builder()
  let b = emit_line(b, "define void @" <> name <> "(i8* %slot) {")
  let #(p, b) = fresh(b)
  let b = emit_line(b, "  " <> p <> " = bitcast i8* %slot to " <> ty_s <> "*")
  let #(v, b) = fresh(b)
  let b =
    emit_line(b, "  " <> v <> " = load " <> ty_s <> ", " <> ty_s <> "* " <> p)
  let b = rc_expr(lits, recursive, fields_of, which, elem, ty_s, v, "buffer", b)
  let b = emit_line(b, "  ret void")
  let b = emit_line(b, "}")
  string.join(list.reverse(b.lines), "\n") <> "\n"
}

/// The value types passed to `dynamic.from`, so a `void(i8*)` drop glue can be
/// emitted for each (handed to `Gleamc_dynamic_new`).
fn collect_box_drop_types(custom_types, functions) -> List(Type) {
  let by_name =
    dict.from_list(
      list.map(custom_types, fn(custom) {
        let ast.CustomType(_, name, _, _, _) = custom
        #(name, custom)
      }),
    )
  let make_types =
    [#("Down", "ProcessDown"), #("ExitMessage", "ExitMessage")]
    |> list.filter_map(fn(pair) {
      let #(suffix, _) = pair
      case find_type(by_name, suffix) {
        Ok(ast.CustomType(_, name, _, _, _)) -> Ok(TNamed(name))
        Error(_) -> Error(Nil)
      }
    })
  let fn_by_name =
    list.fold(functions, dict.new(), fn(acc, f) {
      let ir.Function(name, _, _, _, _) = f
      dict.insert(acc, name, f)
    })
  let all =
    list.flat_map(functions, fn(function) {
      let ir.Function(_, _, _, blocks, locals) = function
      let by_name =
        list.fold(locals, dict.new(), fn(acc, local) {
          let ir.Local(name, ty, _) = local
          dict.insert(acc, name, ty)
        })
      list.flat_map(blocks, fn(block) {
        let ir.Block(_, ops, _) = block
        list.flat_map(ops, fn(op) {
          case op {
            ir.OpBuiltin(_, "process_ffi.send", [_, msg, ..], _)
            | ir.OpBuiltin(_, "process_ffi.unreceive", [_, msg, ..], _)
            | ir.OpBuiltin(_, "process_ffi.send_after", [_, _, msg, ..], _)
            | ir.OpBuiltin(_, "process_ffi.send_exit_message", [_, msg, ..], _) ->
              operand_type_or_empty(by_name, msg)
            ir.OpBuiltin(_, "dynamic_ffi.from", [arg, ..], _) ->
              operand_type_or_empty(by_name, arg)
            ir.OpTaskStart(_, fun, _, _)
            | ir.OpTaskStartClosure(_, fun, _, _) ->
              case dict.get(fn_by_name, fun) {
                Ok(ir.Function(_, _, ret, _, _)) -> [ret]
                Error(_) -> []
              }
            _ -> []
          }
        })
      })
    })
  let all = list.append(make_types, all)
  list.fold(all, dict.new(), fn(acc, ty) {
    dict.insert(acc, mangle_glue(ty), ty)
  })
  |> dict.to_list
  |> list.map(fn(pair) {
    let #(_, ty) = pair
    ty
  })
}

fn operand_type_or_empty(by_name, op) -> List(Type) {
  case op {
    ir.Var(name) ->
      case dict.get(by_name, name) {
        Ok(ty) -> [ty]
        Error(_) -> []
      }
    _ -> []
  }
}

/// `void(i8*)` glue that loads a `Dynamic` payload from its box and drops it.
fn emit_box_glue(lits, recursive, fields_of, elem: Type) -> String {
  let ty_s = llvm_ty(elem, recursive)
  let name = "Gleamc_BoxDrop_" <> mangle_glue(elem) <> "_drop"
  let b = new_builder()
  let b = emit_line(b, "define void @" <> name <> "(i8* %slot) {")
  let #(p, b) = fresh(b)
  let b = emit_line(b, "  " <> p <> " = bitcast i8* %slot to " <> ty_s <> "*")
  let #(v, b) = fresh(b)
  let b =
    emit_line(b, "  " <> v <> " = load " <> ty_s <> ", " <> ty_s <> "* " <> p)
  let b = rc_expr(lits, recursive, fields_of, "drop", elem, ty_s, v, "box", b)
  let b = emit_line(b, "  ret void")
  let b = emit_line(b, "}")
  string.join(list.reverse(b.lines), "\n") <> "\n"
}

/// The C symbol for a builtin name. A dotted name (`io.println`) is a compiler
/// builtin mapped to `Gleamc_io_println`; a name with no dot is an `@external`
/// symbol, used verbatim.
fn builtin_symbol(builtin: String) -> String {
  case string.contains(builtin, ".") {
    True -> "Gleamc_" <> string.replace(builtin, ".", "_")
    False -> builtin
  }
}

fn builtin_decl(builtin, ret_ty, args, by_name, recursive) -> String {
  let name = builtin_symbol(builtin)
  let arg_str =
    string.join(
      list.map(args, fn(arg) { builtin_arg_ty(by_name, recursive, arg) }),
      ", ",
    )
  case abi.is_file_result(ret_ty) {
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
  let name = builtin_symbol(builtin)
  let ret_s = llvm_ty(ret_ty, ctx.recursive)
  let sret = abi.is_file_result(ret_ty)
  let #(b, rev_parts) =
    list.fold(args, #(b, []), fn(acc, arg) {
      let #(b, parts) = acc
      let oty = operand_type(ctx.by_name, arg)
      case abi.is_file_result(oty) {
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
      let #(destp, b) = local_addr(ctx, dest, b)
      let b =
        emit_line(
          b,
          "  call void @"
            <> name
            <> "(ptr sret(%GleamcFileResult) "
            <> destp
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
    "gleamc.show"
    | "gleamc.hash"
    | "process_ffi.send"
    | "process_ffi.send_after"
    | "process_ffi.send_exit_message"
    | "process_ffi.unreceive"
    | "dynamic_ffi.from"
    | "dynamic_ffi.unsafe_coerce"
    | "dynamic_ffi.as_int"
    | "dynamic_ffi.as_float"
    | "dynamic_ffi.as_string"
    | "dynamic_ffi.as_bool"
    | "buffer.new"
    | "buffer.len"
    | "buffer.get"
    | "buffer.set"
    | "buffer.take"
    | "io.debug"
    | "gleamc.key_compare"
    | "panic" -> True
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
      let gleam_args = list.map(params, fn(param) { llvm_ty(param, recursive) })
      case abi.ret_needs_sret(ret, recursive) {
        // The explicit out pointer comes first, then the closure environment.
        True ->
          "void (ptr, i8*"
          <> case gleam_args {
            [] -> ""
            _ -> ", " <> string.join(gleam_args, ", ")
          }
          <> ")*"
        False -> {
          let args = case gleam_args {
            [] -> "i8*"
            _ -> "i8*, " <> string.join(gleam_args, ", ")
          }
          llvm_ty(ret, recursive) <> " (" <> args <> ")*"
        }
      }
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
      <> ", i8*, void (i8*)*, i8* }"
    _ -> ""
  }
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
          let ir.Local(_, ty, _) = local
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
  // First-class aggregates must repeat their type at the call site, so use the
  // typed parameter declarations for the call arguments too.
  let args = string.join(decls, ", ")
  let ret_s = llvm_ty(ret, recursive)
  let sret = abi.ret_needs_sret(ret, recursive)
  let params_decl = case sret {
    True ->
      "ptr sret("
      <> ret_s
      <> ") %out, i8* %env"
      <> case decls {
        [] -> ""
        _ -> ", " <> string.join(decls, ", ")
      }
    False ->
      "i8* %env"
      <> case decls {
        [] -> ""
        _ -> ", " <> string.join(decls, ", ")
      }
  }
  let call_args = case sret {
    True ->
      "ptr sret("
      <> ret_s
      <> ") %out"
      <> case args {
        "" -> ""
        _ -> ", " <> args
      }
    False -> args
  }
  let lines = case sret {
    True ->
      "  call void @Gleamc_" <> name <> "(" <> call_args <> ")\n  ret void"
    False ->
      case ret_s {
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
  }
  "define "
  <> case sret {
    True -> "void"
    False -> ret_s
  }
  <> " @"
  <> code
  <> "("
  <> params_decl
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
  let b = new_builder()
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
      case ast.buffer_elem_name(type_name) {
        // A mutable COW cell: equality is reference identity.
        Ok(_) -> {
          let #(r, b) = fresh(b)
          let b = emit_line(b, "  " <> r <> " = icmp eq i8* %a, %b")
          #(emit_line(b, "  ret i1 " <> r), Nil)
        }
        Error(_) -> eq_named(recursive, custom_types, ty, type_name, ty_s, b)
      }
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

fn is_handle_like(ty: Type) -> Bool {
  case ty {
    ast.TApp("Subject", _) | ast.TApp("Task", _) | ast.TApp("Pid", _) -> True
    ast.TApp("Timer", _) -> True
    ast.TApp("Selector", _) -> True
    ast.TApp("Name", _) -> True
    TNamed("Pid") -> True
    TNamed("Monitor") -> True
    TNamed("Timer") -> True
    TNamed("Selector") -> True
    TNamed("Name") -> True
    TNamed("Dynamic") -> True
    TNamed("SelectorHandle") -> True
    TNamed(name) ->
      case ast.subject_elem_name(name) {
        Ok(_) -> True
        Error(_) ->
          case ast.task_elem_name(name) {
            Ok(_) -> True
            Error(_) ->
              case ast.name_elem_name(name) {
                Ok(_) -> True
                Error(_) ->
                  case ast.selector_elem_name(name) {
                    Ok(_) -> True
                    Error(_) -> False
                  }
              }
          }
      }
    _ -> False
  }
}

/// The `gleam/dynamic` class tag for a static type (`Int` 0, `Float` 1,
/// `String` 2, `Bool` 3, `Nil` 4, `List` 5, tuple 6, `BitArray` 7, closure 8,
/// anything else 9).
fn dynamic_tag_of(ty: Type) -> Int {
  case ty {
    ast.TInt -> 0
    ast.TFloat -> 1
    TString -> 2
    ast.TBool -> 3
    ast.TNil -> 4
    TNamed("Nil") -> 4
    TNamed("BitArray") -> 7
    ast.TFun(_, _) -> 8
    ast.TTuple(_) -> 6
    ast.TApp("List", _) -> 5
    TNamed(name) ->
      case string.starts_with(name, "List_") {
        True -> 5
        False -> 9
      }
    _ -> 9
  }
}

/// Box a message of `ty`, attaching the type's drop glue when it has any (so
/// an abandoned queued message drops its payload).
fn emit_box_alloc(ctx: Ctx, box: String, ty: Type, b: Builder) -> Builder {
  let size = ty_size_expr(ty, ctx.recursive)
  case ownership.needs_drop(ty, ctx.ctors) {
    True ->
      emit_line(
        b,
        "  "
          <> box
          <> " = call i8* @gleamc_box_alloc_meta(i64 "
          <> size
          <> ", void (i8*)* @Gleamc_BoxDrop_"
          <> mangle_glue(ty)
          <> "_drop)",
      )
    False ->
      emit_line(
        b,
        "  " <> box <> " = call i8* @gleamc_box_alloc(i64 " <> size <> ")",
      )
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
    _ ->
      case is_handle_like(ty) {
        // `Subject(a)` / `Task(a)` are opaque handles: compare the raw word.
        True -> {
          let ty_s = llvm_ty(ty, recursive)
          let #(r, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  " <> r <> " = icmp eq " <> ty_s <> " " <> left <> ", " <> right,
            )
          #(r, b)
        }
        False -> {
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
}

fn glue_literals(custom_types: List(ast.CustomType)) -> List(String) {
  list.append(
    ["#(", "(", ")", ", ", "[", "]", "Nil", "<function>", "<handle>", "?"],
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
    _ ->
      case is_handle_like(ty) {
        True -> literal_struct(lits, "<handle>", b)
        False -> {
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
}

fn emit_show_glue(recursive, custom_types, lits, ty) -> String {
  let ty_s = llvm_ty(ty, recursive)
  let name = "Gleamc_Inspect_" <> mangle_glue(ty)
  let b = new_builder()
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
      case ast.buffer_elem_name(type_name) {
        Ok(_) -> {
          let #(r, b) = literal_struct(lits, "?", b)
          #(emit_line(b, "  ret %GleamcString " <> r), Nil)
        }
        Error(_) ->
          case list_info(custom_types, type_name) {
            Ok(info) -> show_list(recursive, lits, type_name, info, b)
            Error(_) ->
              show_adt(recursive, custom_types, lits, type_name, ty_s, b)
          }
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
  let b = new_builder()
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
    TNamed(type_name) ->
      case ast.buffer_elem_name(type_name) {
        // A mutable COW cell: order by reference identity.
        Ok(_) -> {
          let #(lt, b) = fresh(b)
          let b = emit_line(b, "  " <> lt <> " = icmp ult i8* %a, %b")
          let #(gt, b) = fresh(b)
          let b = emit_line(b, "  " <> gt <> " = icmp ugt i8* %a, %b")
          let #(neg, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  " <> neg <> " = select i1 " <> lt <> ", i32 -1, i32 0",
            )
          let #(r, b) = fresh(b)
          let b =
            emit_line(
              b,
              "  " <> r <> " = select i1 " <> gt <> ", i32 1, i32 " <> neg,
            )
          #(emit_line(b, "  ret i32 " <> r), Nil)
        }
        Error(_) -> cmp_named(recursive, custom_types, type_name, ty_s, b)
      }
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
    _ ->
      case is_handle_like(ty) {
        // Opaque handles compare by their raw word.
        True -> int_cmp_i(b, llvm_ty(ty, recursive), "sgt", "slt", left, right)
        False -> {
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
    // `Buffer(a)` is an opaque cell: retain/release the block (its own drop
    // runs the per-element glue stored in the header).
    ast.TApp("Buffer", _) -> buffer_rc(which, reg, b)
    // `Subject(a)` is a refcounted mailbox handle (i64 pointer).
    ast.TApp("Subject", _) -> subject_rc(which, reg, b)
    // `Task(a)` is a refcounted completion-future handle (i8*).
    ast.TApp("Task", _) -> task_rc(which, reg, b)
    // `Dynamic` is a refcounted boxed value (`GleamcDynamic*`).
    TNamed("Dynamic") -> dynamic_rc(which, reg, b)
    // A refcounted selector handle (`i64`).
    TNamed("SelectorHandle") -> selector_rc(which, reg, b)
    TNamed(name) ->
      case ast.subject_elem_name(name) {
        Ok(_) -> subject_rc(which, reg, b)
        Error(_) ->
          case ast.task_elem_name(name) {
            Ok(_) -> task_rc(which, reg, b)
            Error(_) ->
              case ast.buffer_elem_name(name) {
                Ok(_) -> buffer_rc(which, reg, b)
                Error(_) ->
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
          }
      }
    ast.TTuple(_) -> {
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

fn self_type(ty, type_name) -> Bool {
  case ty {
    TNamed(name) -> name == type_name
    _ -> False
  }
}

/// The cons of a singly-linked list: a variant with exactly two fields whose
/// second is the type itself and whose first is not. Returns its variant and
/// self-field indices.
fn list_tail_field(variants, type_name) -> Option(#(Int, Int)) {
  list.fold(
    list.index_map(variants, fn(variant, index) { #(variant, index) }),
    None,
    fn(acc, entry) {
      case acc {
        Some(_) -> acc
        None -> {
          let #(variant, index) = entry
          let #(_, fields) = variant
          case fields {
            [head_ty, tail_ty] ->
              case
                self_type(tail_ty, type_name),
                self_type(head_ty, type_name)
              {
                True, False -> Some(#(index, 1))
                _, _ -> None
              }
            _ -> None
          }
        }
      }
    },
  )
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
  let b = new_builder()
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
          case which == "drop" {
            True ->
              // A singly-linked list (a variant with a self tail) drops
              // iteratively, so a long list costs constant stack.
              case
                list_tail_field(
                  variant_fields_of(custom_types, type_name),
                  type_name,
                )
              {
                Some(#(cons, tail)) ->
                  rc_glue_list(
                    lits,
                    recursive,
                    custom_types,
                    fields_of,
                    type_name,
                    ty_s,
                    name,
                    b,
                    cons,
                    tail,
                  )
                None ->
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
              }
            False ->
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
          }
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

/// Iterative drop for a singly-linked list (`Cons(head, tail=self)`): walk the
/// spine in a loop, dropping the head and freeing each node, so the native
/// stack does not grow with the list length.
fn rc_glue_list(
  lits: Dict(String, Int),
  recursive,
  custom_types,
  fields_of,
  type_name,
  ty_s,
  name,
  b,
  cons: Int,
  tail: Int,
) -> Builder {
  let variants = variant_fields_of(custom_types, type_name)
  let struct_ty = "%" <> type_name
  let b = emit_line(b, "define void @" <> name <> "(" <> ty_s <> " %v) {")
  let b = emit_line(b, "  %sp = alloca " <> ty_s)
  let b = emit_line(b, "  store " <> ty_s <> " %v, " <> ty_s <> "* %sp")
  let b = emit_line(b, "  br label %loop")
  let b = emit_line(b, "\nloop:")
  let b = emit_line(b, "  %cur = load " <> ty_s <> ", " <> ty_s <> "* %sp")
  let b = emit_line(b, "  %isnull = icmp eq " <> ty_s <> " %cur, null")
  let b = emit_line(b, "  br i1 %isnull, label %ldone, label %lnotnull")
  let b = emit_line(b, "\nlnotnull:")
  let b = emit_line(b, "  %vp = bitcast " <> ty_s <> " %cur to i8*")
  let b = emit_line(b, "  %hp = getelementptr i8, i8* %vp, i64 -8")
  let b = emit_line(b, "  %h = bitcast i8* %hp to i64*")
  let b = emit_line(b, "  %rc = load i64, i64* %h")
  let b = emit_line(b, "  %last = icmp eq i64 %rc, 1")
  let b = emit_line(b, "  br i1 %last, label %lfrees, label %lrel")
  let b = emit_line(b, "\nlfrees:")
  let b = emit_line(b, "  %av = load " <> struct_ty <> ", " <> ty_s <> " %cur")
  let b = emit_line(b, "  %ftag = extractvalue " <> struct_ty <> " %av, 0")
  let arms =
    list.index_map(variants, fn(_, index) {
      " i8 " <> int.to_string(index) <> ", label %vf" <> int.to_string(index)
    })
  let b =
    emit_line(
      b,
      "  switch i8 %ftag, label %lrel [" <> string.join(arms, "") <> " ]",
    )
  let b =
    list.fold(
      list.index_map(variants, fn(variant, index) { #(variant, index) }),
      b,
      fn(b, entry) {
        let #(variant, index) = entry
        let #(_, fields) = variant
        let b = emit_line(b, "\nvf" <> int.to_string(index) <> ":")
        let b =
          list.fold(
            list.index_map(fields, fn(inner, i) { #(inner, i) }),
            b,
            fn(b, fp) {
              let #(inner, i) = fp
              case index == cons && i == tail {
                // The tail is followed by the loop, not dropped recursively.
                True -> b
                False ->
                  case ownership.needs_drop_in(inner, fields_of, recursive) {
                    True -> {
                      let #(fv, b) =
                        extract_value(struct_ty, "%av", [index + 1, i], b)
                      rc_expr(
                        lits,
                        recursive,
                        fields_of,
                        "drop",
                        inner,
                        llvm_ty(inner, recursive),
                        fv,
                        name,
                        b,
                      )
                    }
                    False -> b
                  }
              }
            },
          )
        let b =
          emit_line(
            b,
            "  call void @Gleamc_rc_release(i8* %vp, "
              <> cstring_arg(lits, name)
              <> ")",
          )
        case index == cons {
          True -> {
            let #(cur, b) =
              extract_value(struct_ty, "%av", [index + 1, tail], b)
            let b =
              emit_line(
                b,
                "  store " <> ty_s <> " " <> cur <> ", " <> ty_s <> "* %sp",
              )
            emit_line(b, "  br label %loop")
          }
          False -> emit_line(b, "  br label %ldone")
        }
      },
    )
  let b = emit_line(b, "\nlrel:")
  let b =
    emit_line(
      b,
      "  call void @Gleamc_rc_release(i8* %vp, "
        <> cstring_arg(lits, name)
        <> ")",
    )
  let b = emit_line(b, "  br label %ldone")
  let b = emit_line(b, "\nldone:")
  emit_line(b, "  ret void")
}

// ---------------------------------------------------------------------------
// builder
// ---------------------------------------------------------------------------

type Builder {
  Builder(next: Int, lines: List(String), values: Dict(String, String))
}

fn new_builder() -> Builder {
  Builder(next: 0, lines: [], values: dict.new())
}

fn fresh(b: Builder) -> #(String, Builder) {
  let Builder(next, lines, values) = b
  #(
    "%t" <> int.to_string(next),
    Builder(next: next + 1, lines: lines, values: values),
  )
}

fn emit_line(b: Builder, text: String) -> Builder {
  let Builder(next, lines, values) = b
  Builder(next: next, lines: [text, ..lines], values: values)
}
