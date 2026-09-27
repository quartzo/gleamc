# 1. Syntax, modules, declarations and types

## Source files, comments and newlines

- One file is one module. The module name is not declared in the file; it is
  derived from the path (`std/gleam/erlang/process.gleam` is
  `gleam/erlang/process`).
- Comments start with `//` and run to the end of the line. `///` (doc) and
  `////` (module doc) are also line comments.
- Newlines are significant at module level and inside `{ }` (they separate
  declarations and statements). Inside `( )` and `[ ]` they are ignored, and a
  binary operator may start the next line (continuation style).

## Imports

```gleam
import gleam/io                       // module `io`
import gleam/list                     // module `list`
import gleam/erlang/process           // module `process`
import gleam/list.{map, filter}       // bring `map`, `filter` into scope
import gleam/list.{type List}         // bring the type `List` into scope
import gleam/dynamic.{type Dynamic}
```

- The last path segment is the module's local name (`process`, `list`, ...).
- Qualify references with the module name: `io.println("hi")`,
  `list.map(xs, f)`, `process.new_subject()`.
- Imported items can be used unqualified. Importing the same name from two
  modules, or shadowing a local, is an error.
- The **prelude** always provides `gleam/result` and `gleam/list`. The
  constructors `Ok` and `Error` are therefore available without an import (and
  are globally unique). `Some`/`None` are *not* in the prelude — import
  `gleam/option` to use them.
- Builtin pseudo-modules (`process_ffi`, `task_ffi`, `dynamic_ffi`) and the
  global modules `time`, `io`, `host` are resolved by the compiler; the
  standard library (`std/gleam/...`) is written on top of them.

## Declarations

```gleam
pub fn name(a: Int, b: String) -> Bool { ... }   // public function
fn helper(x: Int) { ... }                         // private; return inferred
pub const answer = 42                             // module constant
pub type Colour { Red  Green  Blue }              // custom type
pub type Box(a) { Box(value: a) }                 // generic custom type
pub opaque type Counter { Counter(Int) }          // opaque (hidden fields)
pub type Id = Int                                 // type alias
@external(erlang, "my_mod", "my_fun")             // external declaration
fn external_thing(a: Int) -> Int
```

- Function return types are optional: `fn f(x) { ... }` infers the return and
  parameter types where possible.
- Function parameters are ordinary names (`a: Int`); labelled parameters
  (`label name: T`) are **not** parsed. A **labelled argument** at the call
  site (`f(label: value)`) only works when the parameter is named `label`.
- Custom-type fields must be **named** in the declaration
  (`Box(value: a)`); positional fields in a declaration are also accepted and
  get synthetic names (`_0`, `_1`, ...). Construction and matching may be
  positional either way.
- `const` values are module-level and may be `pub`.
- `@external(target, "module", "function")` (or `@external(target, "symbol")`)
  declares a bodyless function implemented outside Gleam; `target` is
  recorded but the symbol is called verbatim.

## Types

| Syntax | Meaning |
|---|---|
| `Int`, `Float`, `Bool`, `String`, `Nil` | primitives |
| `BitArray` | byte array |
| `List(a)`, `Result(a, b)`, `Option(a)`, `Order` | prelude types |
| `#(a, b, ...)` | tuple |
| `fn(a, b) -> c` | function |
| `Name` (uppercase) | a (possibly generic) type |
| `mod.Type` | a type from another module |
| `name` (lowercase) | a type variable |

- The prelude/global types that a module may not shadow are `BitArray`,
  `FileResult`, `Bool`, `Int`, `Float`, `String`, `Nil`, `List`, `Result`,
  `Option`, `Order`.
- User-defined type names are module-scoped (write `mod.Type`); qualify
  constructors the same way (`mod.Ctor`). A constructor may be reused across
  modules but must be unique within one.
- The compiler also knows a set of **handle types** used by the standard
  library and builtins — `Pid`, `Monitor`, `Timer`, `Name(a)`, `Subject(a)`,
  `Task(a)`, `SelectorHandle`, `Dynamic`. They are opaque scalars/pointers at
  runtime; see [05-concurrency.md](05-concurrency.md).

## Operators

| Precedence (low → high) | Operators |
|---|---|
| 0 | `\|\|` |
| 1 | `&&` |
| 2 | `==` `!=` `<` `<=` `>` `>=`, ` <.` `<=.` `>.` `>=.` |
| 3 | `<>` (string concat) |
| 4 | `+` `-`, `+.` `-.` |
| 5 | `*` `/` `%`, `*.` `/.` |
| unary | `!`, `-`, `-.` |

- `==`/`!=` are **structural** for all data (custom types, tuples, lists,
  strings, primitives) through generated per-type equality glue.
- `<` `<=` `>` `>=` are `Int` only. The `*.`/`<.` family is `Float` only.
- There are no `Eq`/`Ord` typeclasses; ordering glue is generated per type for
  the types that need it.
