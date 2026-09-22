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

None currently open. Two monomorphization bugs were found and fixed while
adding list support, and are now covered by `diffs/lists.gleam`:

- Nested generic specialization (`List(List(Int))`) left inner type arguments
  as unspecialized `TApp` instead of concrete named types.
- `lift_lambda` reset the shared substitution while monomorphizing a lambda
  body, discarding outer bindings. This corrupted later specializations (for
  example specializing `list.take` to `list_take_Nil`) once enough closures and
  generic functions were present.

## Language syntax not implemented

- Type aliases (`pub type X = ...`) are rejected with
  `type aliases not supported yet`.
- String interpolation (`"${expr}"`); only escapes are handled.
- Bit arrays (`<<...>>`).
- Record update syntax (`Type(..record, field: value)`).
- Guards: only a single boolean guard via `if` (alias `when`). Pattern guards
  and `let` inside guards are not supported.
- Exhaustiveness for tuple subjects (including multiple `case` subjects, which
  desugar to a tuple) is assumed rather than analysed, so a non-exhaustive
  tuple `case` is not reported.
- `opaque` is a reserved keyword but opaque types are not enforced.

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
  `drop_while`, `window`, `unique`, plus the non-official extras `sum` and `at`.
  Missing: `permutations`, `chunk`, and others.
- `gleam/string`: `length`, `append`, `uppercase`, `lowercase`, `reverse`,
  `contains`, `starts_with`, `ends_with`, `trim`, `replace`, `concat`, `join`,
  `split`, `slice`, `repeat`, `pad_start`, `pad_end`, `trim_start`, `trim_end`,
  `drop_start`, `drop_end`, `first`, `last`, `is_empty`, `to_graphemes`
  (code-point based, not full grapheme clusters), `split_once`, `crop`,
  `remove_prefix`, `remove_suffix`, `capitalise`, `pop_grapheme`, `to_option`,
  `byte_size`. Missing: `compare`, `pad_zero`, `utf_codepoints`, etc.
- `gleam/int`: `to_string`, `parse`, `min`, `max`, `absolute_value`
  (arithmetic is built in). Missing: `to_base_string`, `to_float`, etc.
- `gleam/float`: `to_string`, `min`, `max`, `absolute_value`, `floor`,
  `ceiling`, `round`, `truncate`. Missing: `parse`, `power`, `square_root`,
  etc.
- `gleam/bool`: `to_string` only.
- `gleam/io`: `println`, `print` only. Missing: `debug`.
- `gleam/order`: `Order` type plus `to_int`, `negate`. Other helpers
  (`compare`, `reverse`, `break_tie`) are not implemented.
- `gleam/option`: `unwrap`, `map`, `is_some`, `is_none`, `then`, `or`,
  `to_result`, `from_result`, `flatten`, `lazy_unwrap`, plus the non-official
  `unwrap_or` (import required; the prelude does not expose `Some`/`None`).
  Missing: `all`, `values`, `lazy_or`, etc.
- `gleam/result`: `unwrap`, `unwrap_or`, `lazy_unwrap`, `unwrap_error`, `map`,
  `map_error`, `try`, `then`, `is_ok`, `is_error`, `flatten`, `all`, `or`,
  `replace`, `replace_error`, `values`, `partition`. Missing: `lazy_or`,
  `try_recover`, etc.

## Toolchain

- `tcc` was dropped; development builds use
  `clang -O0 -fuse-ld=mold`, release builds use `-O3 -march=native`.
- Diagnostics are text messages without source spans or carets.
- No language server, no formatter, no package manager integration.
- Only a single entry module plus its imports is compiled; there is no build
  cache or incremental compilation.
