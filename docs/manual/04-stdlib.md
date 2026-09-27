# 4. Standard library

The standard library is written in Gleam under `std/` and compiled by `gleamc`
itself, on top of a small C runtime. Only primitives that cannot be expressed
in Gleam live in C (the refcount kernel, string/bit-array byte operations,
numeric conversions/math, `panic`, printing).

This page lists the modules and their notable coverage. The **exhaustive** list
of supported functions, and the gaps, lives in
[../known-limitations.md](../known-limitations.md).

## Core modules

| Module | Notes |
|---|---|
| `gleam/int` | `to_string`, `parse`, bases (2/8/16/36), arithmetic, `min`/`max`/`clamp`, `compare`, bitwise ops. No `random`. |
| `gleam/float` | `to_string`, `parse`, arithmetic, `round`/`floor`/`ceiling`/`truncate`, `to_precision`, `compare`, `loosely_*`. No `random`. |
| `gleam/bool` | `to_string`, boolean combinators (`and`, `or`, `nand`, `nor`, `guard`, ...). |
| `gleam/string` | Unicode-aware (UTF-8, UAX #29 graphemes via `utf8proc`, ICU case mapping): `length`, `reverse`, `slice`, `split`, `replace`, `trim*`, `pad_*`, `*_prefix`/`*_suffix`, `to_graphemes`, `to_utf_codepoints` (with the `UtfCodepoint` type), `inspect`, ... |
| `gleam/list` | The usual combinators plus `sum` and `at` (non-official extras). No `sample`/`shuffle`. |
| `gleam/dict` | Sorted-key map (`new`, `get`, `insert`, `fold`, `merge`, `group`, ...). `to_list` order matches the official Erlang backend. |
| `gleam/set` | Sorted-list set (`new`, `contains`, `union`, `intersect`, ...). Not a balanced tree. |
| `gleam/order` | `Order` type and helpers. |
| `gleam/option` | `unwrap`, `map`, `then`, `or`, `to_result`, `from_result`, ... plus the non-official `unwrap_or`. `Some`/`None` are **not** in the prelude. |
| `gleam/result` | `unwrap`, `try`, `then`, `map*`, `all`, `or`, `partition`, ... |
| `gleam/function` | `identity` only. |
| `gleam/io` | `println`, `print`, `debug`. |
| `gleam/bit_array` | `from_string`, `to_string`, `byte_size`, `bit_size`, `append`, `concat`. 8-bit segments only. |

## File system: `simplifile`

`std/simplifile.gleam` mirrors the `simplifile` package: `read`/`write`/`append`
(binary and text), `delete*`, `create_directory*`, `rename*`, `copy*`,
`resolve`, `exists`, `is_file`/`is_directory`, `read_directory`, `get_files`,
`current_directory`, `file_info`, permissions, and the
`FileError`/`FileInfo`/`FileType`/`Permission` types. Backed by synchronous
libuv wrappers.

## Dynamic and interop

- `gleam/dynamic` is a **subset**: `from`, `unsafe_coerce`, `classify` (returns
  an `Int` class) and the `Int`/`Float`/`String`/`Bool` accessors. There is no
  list/tuple reification and no `gleam/dynamic/decode`.
- `gleam/erlang/process` and `gleam/otp/task` are covered in
  [05-concurrency.md](05-concurrency.md).

## Non-official extras

- `gleam/big_dict` (`std/big_dict.gleam`): a larger persistent map.
- `list.sum`, `list.at`, `option.unwrap_or` as noted above.
