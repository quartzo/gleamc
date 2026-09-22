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

- A closure that captures a collection/ADT value (not a scalar) and uses it in
  a call to a generic function mis-specialises the captured type. For example
  `list.map(xs, fn(a) { list.length(xs) + a })` is rejected. Scalar captures
  work. Workaround: pass the captured value as an
  explicit parameter instead of capturing it.

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

## Type system

- No `Eq`/`Ord` typeclasses. `==` and `!=` are structural for all data
  (ADTs, tuples, lists, `String`) via generated per-type equality glue; `<`,
  `<=`, `>`, `>=` are `Int` only and the `*.`/`<.` family is `Float` only.
- No module-qualified types beyond a plain named type or `TApp`
  (`Type` / `Type(a)`); there is no `module.Type` in annotations.
- No `const` values.
- Constructors are global by name. Two modules defining the same constructor
  name collide. The list constructors are therefore internal names
  (`ListCons` / `ListEmpty`) so that user types can still define `Empty`/`Cons`.
- The primitive `Nil` type shares its constructor name with a user constructor
  named `Nil`.

## Backend and runtime

- Deterministic refcounting, complete for acyclic data. Reference cycles leak
  by design (no cycle collector, no GC).
- Closures with captured variables are supported (environment structs). Values
  captured by a closure must be representable by the environment glue.
- Unicode is not fully handled in `String`: `uppercase`/`lowercase` are
  ASCII-only, `reverse` reverses code points (not grapheme clusters), and
  `length` counts code points (not grapheme clusters). ASCII matches Gleam.
- `float.to_string` matches Gleam's shortest round-trip formatting for the
  cases exercised by `diffs/floats.gleam`; `nan`/`inf` print as `nan`/`inf` and
  are not verified against Gleam.
- No dead-code elimination. Monomorphic helper functions (including prelude
  functions) may be emitted even when unused.
- `fold_right` is not tail recursive (same as the official implementation).

## Standard library coverage

The `std/` directory implements a subset of the official API. Imports of
official modules that cannot be resolved are skipped, so unsupported calls fail
later during checking. Prelude modules may import other modules; their imports
are resolved when the prelude is attached.

- `gleam/list`: `length`, `reverse`, `map`, `map2`, `filter`, `fold`,
  `fold_right`, `any`, `all`, `each`, `append`, `flatten`, `flat_map`, `take`,
  `drop`, `contains`, `repeat`, `first`, `last`, `find`, `zip`, `unzip`,
  `index_map`, `index_fold`, `filter_map`, `sort`, `intersperse`, `take_while`,
  `drop_while`, `window`, `chunk`, `sized_chunk`, `permutations`, `scan`,
  `transpose`, `unique`, plus the non-official extras `sum` and `at`.
- `gleam/string`: `length`, `append`, `uppercase`, `lowercase`, `reverse`,
  `contains`, `starts_with`, `ends_with`, `trim`, `replace`, `concat`, `join`,
  `split`, `slice`, `repeat`, `pad_start`, `pad_end`, `trim_start`, `trim_end`,
  `drop_start`, `drop_end`, `first`, `last`, `is_empty`, `to_graphemes`
  (code-point based, not full grapheme clusters), `split_once`, `crop`,
  `remove_prefix`, `remove_suffix`, `capitalise`, `pop_grapheme`, `to_option`,
  `byte_size`, `compare`. Missing: `pad_zero`, `utf_codepoints`, etc.
- `gleam/int`: `to_string`, `parse`, `base_parse`, `to_base_string`,
  `to_float`, `min`, `max`, `absolute_value` (arithmetic is built in).
- `gleam/float`: `to_string`, `parse`, `min`, `max`, `absolute_value`, `floor`,
  `ceiling`, `round`, `truncate`, `power`, `square_root` (`parse`, `power` and
  `square_root` return `Result`).
- `gleam/bool`: `to_string` (runtime) plus `and`, `or`, `negate`, `nor`,
  `nand`, `exclusive_or`, `exclusive_nor`, `guard`, `lazy_guard`.
- `gleam/io`: `println`, `print` only. Missing: `debug`.
- `gleam/bit_array`: `from_string`, `to_string` (always `Ok`), `byte_size`,
  `bit_size`, `append`, `concat`. Only 8-bit integer segments are supported in
  `<<...>>` literals and patterns (no `:size`/`:unit`, no bit-level ops, no
  `slice`/`base64_encode`).
- `gleam/order`: `Order` type plus `to_int`, `negate`, `compare`, `reverse`,
  `break_tie`, `lazy_break_tie`.
- `gleam/option`: `unwrap`, `map`, `is_some`, `is_none`, `then`, `or`,
  `to_result`, `from_result`, `flatten`, `lazy_unwrap`, `lazy_or`, `values`,
  `all`, plus the non-official `unwrap_or` (import required; the prelude does
  not expose `Some`/`None`).
- `gleam/result`: `unwrap`, `unwrap_or`, `lazy_unwrap`, `unwrap_error`, `map`,
  `map_error`, `try`, `then`, `is_ok`, `is_error`, `flatten`, `all`, `or`,
  `replace`, `replace_error`, `values`, `partition`, `lazy_or`, `try_recover`.

## Toolchain

- `tcc` was dropped; development builds use
  `clang -O0 -fuse-ld=mold`, release builds use `-O3 -march=native`.
- Diagnostics are text messages without source spans or carets.
- No language server, no formatter, no package manager integration.
- Only a single entry module plus its imports is compiled; there is no build
  cache or incremental compilation.
