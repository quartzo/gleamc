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
- Constructor fields in a `type` declaration must be named
  (`Continue(value: a)`); positional fields (`Continue(a)`) are not parsed.
  Construction and matching can still be positional.
- `let` bindings take no type annotation (`let x: T = ...`).

## Type system

- No `Eq`/`Ord` typeclasses. `==` and `!=` are structural for all data
  (ADTs, tuples, lists, `String`) via generated per-type equality glue; `<`,
  `<=`, `>`, `>=` are `Int` only and the `*.`/`<.` family is `Float` only.
- User-defined type names are module-scoped (`module.Type` in annotations and
  references); primitives, builtins and the prelude types (`List`, `Result`,
  `Option`, `Order`, `BitArray`) stay global.
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
- A no-argument polymorphic value bound by `let` and only constrained later
  defaults to `Nil` before the constraint is seen (`let s = set.new()` then
  using `s` where `Set(Int)` is expected). Passing it directly as a labelled
  call or constructor argument works, because the expected type is propagated
  (`Holder(items: set.new())`).
- A bare top-level function used as a value is eta-expanded into a lambda,
  which needs the expected function type to be resolved. It therefore fails
  when the surrounding call's types are themselves unresolved (for example
  passing `insert` next to a no-argument polymorphic `set.new()`); wrap it in
  an explicit lambda there.

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
- libuv support is ported from Vesper: `GleamcFuture`, the cooperative task
  driver (`gleamc_task_start` / `gleamc_task_tail` / `gleamc_run_until`), and the
  `gleamc_uv_*` timer/file wrappers. libuv is required — the toolchain always
  links `-luv` and the runtime has no synchronous fallback. The compiler itself
  does not expose `async`/`await` yet.
- Cooperative processes and tasks mirror the original Gleam API:
  `gleam/erlang/process` (`new_subject`, `send`, `receive(from:, within:)`,
  `receive_forever(from:)`, `spawn`, `sleep`, `sleep_forever`) and
  `gleam/otp/task` (`async`, `await`, `try_await`, `await_forever`,
  `AwaitError`) are Gleam modules in `std/gleam/...` on top of the
  `process_ffi` / `task_ffi` builtins; `process.spawn` and `task.async` stay
  builtins so the compiler can start the closure at the call site. Payloads are
  **generic and boxed**: `Subject(a)` / `Task(a)` / `Pid` are phantom handle
  types and the concrete value is moved into a refcounted box at the boundary,
  so `Int`, `String`, records, lists, etc. all round-trip. `spawn` / `async`
  take a zero-argument `fn() -> ...` (matching Gleam) and closures **may
  capture** (the environment is retained by the task and released when it
  finishes). Timeouts are honoured: `receive(from:, within:)` and
  `task.try_await(t, timeout)` race the message/task against a libuv timer
  (`Gleamc_process_ffi_wait_any` / `Gleamc_task_ffi_await_timeout`), and
  `task.await(t, timeout)` crashes on timeout like the original. `Pid`
  operations `self`, `is_alive`, `spawn_unlinked` and `task.pid` are provided
  (`Pid` is a stable task id), as are selectors (`new_selector`, `select`,
  `select_map`, `map_selector`, `merge_selector`, `select_other`, `deselect`,
  `selector_receive`, `selector_receive_forever`) and
  `send_after`/`cancel_timer`. A `Selector` is a Gleam record holding an opaque
  handle plus an in-process handler list; `selector_receive*` polls the handlers
  (so the `mapping` closures run directly, no forwarder task), sets aside
  messages no handler accepts and re-examines them on the next wake. Monitor/link
  is supported: each task has
  a per-task inbox (created on demand) and the runtime builds the typed `Down`/
  `ExitMessage` values with backend-emitted constructor helpers
  (`Gleamc_make_process_Down_ProcessDown`) — `monitor`, `demonitor`,
  `demonitor_process`, `select_monitors`, `select_specific_monitor`,
  `link`, `unlink`, `trap_exits` and
  `select_trapped_exits`, plus `kill`, `send_exit` and `send_abnormal_exit`. A non-trapping link
  **propagates the exit** (the linked task is terminated); a trapping link gets
  an `ExitMessage`. Names are supported (`new_name`, `register`, `unregister`,
  `named`, `named_subject`); a `Name(a)` is a subject handle, so
  `named_subject` returns it and `subject_name`/`subject_owner` look it up.
  `ExitReason` has `Normal`, `Killed` and `Abnormal(Dynamic)`;
  `send_abnormal_exit` now carries the reason. `gleam/dynamic` is a subset:
  `from`, `unsafe_coerce`, `classify` and the `Int`/`Float`/`String`/`Bool`
  accessors (no `list`/tuple reification or decoders).
  `select_other` is a catch-all over the subjects the process owns — a process
  receives only subjects it owns, so this is faithful — but a subject created
  *after* `select_other` is not watched (register it first). `select_record`
  is not implemented: it matches foreign tuple-tagged messages, which a
  pure-Gleam runtime has no notion of. `AwaitError` has `Timeout` and
  `Exit(Dynamic)` (a task killed before producing a value; the reason is the
  `Killed` exit reason, wrapped as a `Dynamic`). A
  `Subject(a)` handles are refcounted and their mailbox is freed when the last
  reference dies (queued boxes are freed too, but their payload references are
  abandoned — there is no per-message drop); subjects held by a live
  `Selector` and task inboxes stay alive.   `Selector` handles, `Dynamic` values and
  `Task(a)` handles are refcounted (a `Dynamic` frees its box and runs a
  per-type drop glue at refcount 0; a `Task(a)`'s completion future is held by
  both the task and the caller, so a killed/timed-out handle no longer leaks
  and no longer dangles). When `main` returns, `gleamc_shutdown` terminates
  every still-pending task and frees its frame, completion future, queued
  messages and monitor/link/inbox bookkeeping, so a short-lived program does
  not leak what it left running (ASan-clean on the concurrency examples).
  Still missing: a per-message payload drop (a freed box drops its cell but
  not the payload's inner references) and closing libuv timers still pending
  at exit. Draining a mailbox does not join the spawned senders.

## Standard library coverage

The standard library is written in **Gleam** (`std/*.gleam`, compiled by this
compiler itself) on top of a small **C** runtime (`runtime/gleam_runtime.[ch]`)
exposed as builtins, plus per-type glue generated by the backend
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
  `fold_right`, `any`, `all`, `each`, `append`, `prepend`, `flatten`,
  `flat_map`, `take`, `drop`, `contains`, `repeat`, `first`, `last`, `rest`,
  `new`, `is_empty`, `wrap`, `count`, `find`, `find_map`, `zip`, `strict_zip`,
  `unzip`, `index_map`, `index_fold`, `filter_map`, `sort`, `intersperse`,
  `take_while`, `drop_while`, `split_while`, `window`, `window_by_2`, `chunk`,
  `sized_chunk`, `split`, `map_fold`, `reduce`, `fold_until` (`ContinueOrStop`),
  `try_fold`, `try_map`, `try_each`, `permutations`, `combinations`,
  `combination_pairs`, `interleave`, `scan`, `transpose`, `unique`, `max`,
  `partition`, `group`, `key_find`, `key_filter`, `key_pop`, `key_set`, plus
  the non-official extras `sum` and `at`. Not implemented: `sample` and
  `shuffle` (need randomness).
- `gleam/string`: `length`, `append`, `uppercase`, `lowercase`, `reverse`,
  `contains`, `starts_with`, `ends_with`, `trim`, `replace`, `concat`, `join`,
  `split`, `slice`, `repeat`, `pad_start`, `pad_end`, `trim_start`, `trim_end`,
  `drop_start`, `drop_end`, `first`, `last`, `is_empty`, `to_graphemes`
  (code-point based, not full grapheme clusters), `split_once`, `crop`,
  `remove_prefix`, `remove_suffix`, `capitalise`, `pop_grapheme`, `to_option`,
  `byte_size`, `compare`, `inspect`, `to_utf_codepoints`, `from_utf_codepoints`,
  `utf_codepoint`, `utf_codepoint_to_int` (`UtfCodepoint` opaque type).
- `gleam/int`: `to_string`, `to_float`, `parse`, `base_parse`,
  `to_base_string`, `to_base2`/`to_base8`/`to_base16`/`to_base36`, `compare`,
  `min`, `max`, `absolute_value`, `add`, `subtract`, `multiply`, `negate`,
  `is_even`, `is_odd`, `sum`, `product`, `clamp`, `divide`, `remainder`,
  `modulo`, `floor_divide`, `power`, `square_root`, `range`, and `bitwise_and`,
  `bitwise_or`, `bitwise_exclusive_or`, `bitwise_not`, `bitwise_shift_left`,
  `bitwise_shift_right` (arithmetic operators are built in). Not implemented:
  `random`.
- `gleam/float`: `to_string`, `parse`, `min`, `max`, `absolute_value`, `floor`,
  `ceiling`, `round`, `truncate`, `compare`, `power`, `square_root`, `add`,
  `subtract`, `multiply`, `negate`, `sum`, `product`, `divide`, `modulo`,
  `clamp`, `exponential`, `logarithm`, `loosely_compare`, `loosely_equals`,
  `to_precision` (`parse`, `power`, `square_root`, `divide`, `modulo` and
  `logarithm` return `Result`). Not implemented: `random`.
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
- `gleam/set`: `new`, `is_empty`, `size`, `to_list`, `from_list`, `contains`,
  `insert`, `delete`, `union`, `intersect`, `difference`, `filter`, `map`,
  `fold`, `each` (sorted-list representation, not a balanced tree).
- `simplifile` (file system, the package's public name): the full package API
  — `read`/`read_bits`, `write`/`write_bits`, `append`/`append_bits`, `delete`,
  `delete_file`, `delete_all`, `clear_directory`, `create_directory`,
  `create_directory_all`, `create_file`, `rename`/`rename_file`/
  `rename_directory`, `copy`/`copy_file`/`copy_directory`, `create_symlink`/
  `create_link`, `touch`, `resolve`, `exists`, `is_file`, `is_directory`,
  `is_symlink`, `read_directory`, `get_files`, `current_directory`,
  `file_info`/`link_info`, `file_info_type`, `file_info_permissions`,
  `file_info_permissions_octal`, `file_permissions_to_octal`,
  `set_permissions`, `set_permissions_octal`, `describe_error`, plus the
  `FileError`, `FileInfo`, `FileType`, `Permission` and `FilePermissions`
  types. The labels (`to`, `from`, `contents`, `bits`, `filepath`, `src`,
  `dest`, ...) match the package. Backing: synchronous libuv wrappers (`fs.*`
  builtins) returning a fixed `GleamcFileResult`, which the Gleam wrapper turns
  into a concrete `Result`/`FileError`; directory listings are joined with `/`
  (which cannot appear in a POSIX filename) and split in Gleam; `get_files`,
  `create_directory_all`, `delete`, `clear_directory`, `delete_all` and
  `copy`/`copy_directory` recurse in Gleam.

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
  `clang -O1 -fuse-ld=mold`, release builds use `-O3 -march=native`.
- Diagnostics name the file and, for type errors, the enclosing function and
  its declaration line (e.g. `app.gleam: at line 12, in function `f`: ...`).
  There are no column-accurate spans or carets yet, and backend/monomorphisation
  errors carry less context than front-end ones.
- No language server, no formatter, no package manager integration.
- Only a single entry module plus its imports is compiled; there is no build
  cache or incremental compilation.
