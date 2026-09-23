# Known limitations

This document tracks what `gleamc` does not do yet, and which compiler or
runtime bugs are known. It is intentionally explicit so the gaps are visible
instead of implied.

The project is a work in progress. Everything listed under "Verified" passes
today; everything under "Not implemented" is either rejected by the compiler or
silently unavailable.

## Verified today

- `gleam test`: all unit/e2e tests pass, including refcount leak checks.
- `./scripts/diff.sh`: runs every `diffs/*.gleam` through both `gleamc` and the
  official Gleam toolchain and compares stdout. Add a file there to cover a new
  feature differentially.
- Leak check: run with `GLEAMC_MEM_REPORT=1`; a correct program prints
  `gleamc: live blocks = 0`.

## Known bugs

None open right now. Bugs found and fixed in this area:

- A `let`-bound lambda with no expected function type was given the
  unzonked inferred type, leaving its parameter/return types as unresolved
  variables (`let f = fn(b: Int) { b + 1 }` then `f(1)` was rejected).
  `mono.type_of` now zonks the inferred type before using it as the expected
  type; `diffs/nestedclosure.gleam` covers it.
- The nested-capture bug found while adding `simplifile.get_files` — an inner
  lambda reading the outer `EEnvGet` through its own `__env` — was fixed by
  monomorphising the body before applying capture substitutions and giving the
  `EEnvGet` a specialised type up front; `diffs/nestedclosure.gleam` covers it.

Two monomorphization bugs were found and fixed while
adding list support, and are now covered by `diffs/lists.gleam`:

- Nested generic specialization (`List(List(Int))`) left inner type arguments
  as unspecialized `TApp` instead of concrete named types.
- `lift_lambda` reset the shared substitution while monomorphizing a lambda
  body, discarding outer bindings. This corrupted later specializations (for
  example specializing `list.take` to `list_take_Nil`) once enough closures and
  generic functions were present.

## Language syntax not implemented

- Exhaustiveness for tuple subjects (and multiple `case` subjects, which
  desugar to a tuple) checks each column independently. This never rejects a
  genuinely exhaustive case but may accept some that are not.
- Labelled function parameters (`fn f(label name: T)`) are not parsed. The
  argument matcher keys on the parameter name, so a labelled call only works
  when the parameter is named after the label (`fn f(label: T)`) — impossible
  for keyword-like labels such as `get_files(in directory)`.
- `@external(...)` declarations and bit-array string segments
  (`<<"...":utf8>>`) are not parsed.
- `let` bindings take no type annotation (`let x: T = ...`).

## Type system

- No `Eq`/`Ord` typeclasses. `==` and `!=` are structural for all data
  (ADTs, tuples, lists, `String`) via generated per-type equality glue; `<`,
  `<=`, `>`, `>=` are `Int` only and the `*.`/`<.` family is `Float` only.
- No module-qualified types beyond a plain named type or `TApp`
  (`Type` / `Type(a)`); there is no `module.Type` in annotations.
- No `const` values.
- Constructors are module-scoped, like the official compiler: a name may be
  reused across modules (canonicalised internally to `module.Ctor`) but must be
  unique within a module. Qualified references (`mod.Ctor`) and unqualified ones
  (own module, or a globally unique name such as the prelude `Ok`/`Error`) both
  resolve. Import items (`import mod.{Ctor}`, `import mod.{fn}`) bring names
  into scope unqualified; importing the same name from two modules, or
  shadowing a local, is reported as an error.
- The primitive `Nil` type shares its constructor name with a user constructor
  named `Nil`.

## Backend and runtime

- Deterministic refcounting, complete for acyclic data. Reference cycles leak
  by design (no cycle collector, no GC).
- Closures with captured variables are supported (environment structs). Values
  captured by a closure must be representable by the environment glue.
- `String` is Unicode-aware: `length`, `reverse`, `slice` and friends operate
  on grapheme clusters (UAX #29 via `utf8proc`), and `uppercase`/`lowercase`
  use full Unicode case mapping (ICU), matching the official toolchain.
- `float.to_string` matches Gleam's shortest round-trip formatting for the
  cases exercised by `diffs/floats.gleam`; `nan`/`inf` print as `nan`/`inf` and
  are not verified against Gleam.
- Dead-code elimination keeps only functions reachable from `main` (or, for a
  library with no `main`, from the public API). Unused custom types are still
  emitted.
- `fold_right` is not tail recursive (same as the official implementation).
- libuv support is ported from Vesper: `GleamcFuture`, the state-machine
  scheduler (`gleamc_sched_run`/`gleamc_task_spawn`/`gleamc_tasks_drain`), and
  the `gleamc_uv_*` timer/file wrappers. libuv is required — the toolchain
  always links `-luv` and the runtime has no synchronous fallback. The compiler
  itself does not expose `async`/`await` yet; the file API uses the synchronous
  `uv_fs_*` calls.

## Standard library coverage

The standard library is written in **Gleam** (`std/*.gleam`, compiled by this
compiler itself) on top of a small **C** runtime (`runtime/gleam_runtime.[ch]`)
exposed as builtins, plus per-type C glue generated by the code generator
(`Gleamc_Eq_<type>` for `==`, `Gleamc_Cmp_<type>` for ordering,
`Gleamc_Inspect_<type>` for `string.inspect`/`io.debug`, and
`Gleamc_Rc_retain/drop_<type>` for refcounting). Glue names use a capitalised
segment so they cannot clash with generated (snake_case) function names. Only primitives that cannot be
expressed in Gleam live in C: the refcount kernel, `String`/`BitArray` byte
operations, numeric conversions and `float` math, `panic`, and printing.

Imports of official modules that cannot be resolved are skipped, so unsupported
calls fail later during checking. Prelude modules may import other modules;
their imports are resolved when the prelude is attached.

- `gleam/list`: `length`, `reverse`, `map`, `map2`, `filter`, `fold`,
  `fold_right`, `any`, `all`, `each`, `append`, `flatten`, `flat_map`, `take`,
  `drop`, `contains`, `repeat`, `first`, `last`, `find`, `zip`, `unzip`,
  `index_map`, `index_fold`, `filter_map`, `sort`, `intersperse`, `take_while`,
  `drop_while`, `window`, `window_by_2`, `chunk`, `sized_chunk`, `split`,
  `map_fold`, `reduce`, `permutations`, `scan`, `transpose`, `unique`, plus the
  non-official extras `sum` and `at`. Divergence: `sort` takes an explicit
  comparator (`List(a)`, `fn(a, a) -> Order`), whereas the official `sort` is
  single-argument.
- `gleam/string`: `length`, `append`, `uppercase`, `lowercase`, `reverse`,
  `contains`, `starts_with`, `ends_with`, `trim`, `replace`, `concat`, `join`,
  `split`, `slice`, `repeat`, `pad_start`, `pad_end`, `trim_start`, `trim_end`,
  `drop_start`, `drop_end`, `first`, `last`, `is_empty`, `to_graphemes`
  (code-point based, not full grapheme clusters), `split_once`, `crop`,
  `remove_prefix`, `remove_suffix`, `capitalise`, `pop_grapheme`, `to_option`,
  `byte_size`, `compare`, `inspect`, `to_utf_codepoints`, `from_utf_codepoints`,
  `utf_codepoint`, `utf_codepoint_to_int` (`UtfCodepoint` opaque type).
- `gleam/int`: `to_string`, `parse`, `base_parse`, `to_base_string`,
  `to_float`, `compare`, `min`, `max`, `absolute_value` (arithmetic is built
  in).
- `gleam/float`: `to_string`, `parse`, `min`, `max`, `absolute_value`, `floor`,
  `ceiling`, `round`, `truncate`, `compare`, `power`, `square_root` (`parse`,
  `power` and `square_root` return `Result`).
- `gleam/bool`: `to_string` (runtime) plus `and`, `or`, `negate`, `nor`,
  `nand`, `exclusive_or`, `exclusive_nor`, `guard`, `lazy_guard`.
- `gleam/io`: `println`, `print`, `debug`.
- `gleam/bit_array`: `from_string`, `to_string` (always `Ok`), `byte_size`,
  `bit_size`, `append`, `concat`. Only 8-bit integer segments are supported in
  `<<...>>` literals and patterns (no `:size`/`:unit`, no bit-level ops, no
  `slice`/`base64_encode`).
- `gleam/function`: `identity` only.
- `gleam/dict`: `new`, `is_empty`, `size`, `from_list`, `to_list`, `keys`,
  `values`, `get`, `has_key`, `insert`, `delete`, `upsert`, `map_values`,
  `fold`, `filter`, `each`, `merge`, `combine`, `take`, `drop`, `group`. Entries
  are kept sorted by key (matching the official Erlang backend's `to_list`
  order) using generated per-type comparison glue.
- `gleam/order`: `Order` type plus `to_int`, `negate`, `compare`, `reverse`,
  `break_tie`, `lazy_break_tie`.
- `gleam/option`: `unwrap`, `map`, `is_some`, `is_none`, `then`, `or`,
  `to_result`, `from_result`, `flatten`, `lazy_unwrap`, `lazy_or`, `values`,
  `all`, plus the non-official `unwrap_or` (import required; the prelude does
  not expose `Some`/`None`).
- `gleam/result`: `unwrap`, `unwrap_or`, `lazy_unwrap`, `unwrap_error`, `map`,
  `map_error`, `try`, `then`, `is_ok`, `is_error`, `flatten`, `all`, `or`,
  `replace`, `replace_error`, `values`, `partition`, `lazy_or`, `try_recover`.
- `simplifile` (file system, the package's public name): `read`, `read_bits`,
  `write`, `write_bits`, `append`, `append_bits`, `delete`, `delete_file`,
  `create_directory`, `create_file`, `exists`, `is_file`, `is_directory`,
  `read_directory`, `get_files`, `current_directory`, `file_info`/`link_info`,
  `file_info_type`, `file_info_permissions_octal`, `describe_error`, plus the
  `FileError`, `FileInfo` and `FileType` types. The labels (`to`, `from`, `contents`, `bits`,
  `filepath`, ...) match the package, and the functions are backed by
  synchronous libuv wrappers (`fs.*` builtins) returning a fixed
  `GleamcFileResult` that the Gleam wrapper turns into a concrete
  `Result`/`FileError`. Directory listings are joined with `/` (which cannot
  appear in a POSIX filename) and split in Gleam; `get_files` recurses in
  Gleam using `read_directory`/`is_directory`. Not implemented yet:
  `file_info_permissions` (needs `gleam/set`), `file_permissions_to_octal`,
  `set_permissions`, symlinks, `copy`/`rename`, `touch`, recursive
  `delete`/`clear_directory`, and `create_directory_all`; `exists` ignores
  `follow_links` (it always follows). Directory deletion is non-recursive.

## Self-host

The goal is for `gleamc` to compile its own source (`src/gleamc/*.gleam`), so
that source must stay inside the supported subset and use the same standard
library under both the official toolchain and gleamc.

- `src/gleamc/ffi.gleam` reads and writes files through `simplifile` (the
  published package under the official toolchain, `std/simplifile.gleam` under
  gleamc), so the same source compiles under both. `run`, `which`, `get_env`
  and `argv` still use `@external(erlang, "gleamc_ffi", ...)`, which gleamc
  cannot parse, and need a portable replacement.
- `std/simplifile.gleam` must keep growing until it covers every call the
  compiler makes.

## Toolchain

- `tcc` was dropped; development builds use
  `clang -O0 -fuse-ld=mold`, release builds use `-O3 -march=native`.
- Diagnostics name the file and, for type errors, the enclosing function and
  its declaration line (e.g. `app.gleam: at line 12, in function `f`: ...`).
  There are no column-accurate spans or carets yet, and backend/monomorphisation
  errors carry less context than front-end ones.
- No language server, no formatter, no package manager integration.
- Only a single entry module plus its imports is compiled; there is no build
  cache or incremental compilation.
