# 2. Expressions

## Literals

```gleam
42          // Int
3.14        // Float
"hello"     // String
True  False // Bool
Nil         // Nil
```

## Tuples and lists

```gleam
#(1, "two", 3.0)     // tuple
[]                    // empty list
[1, 2, 3]             // list
[1, 2, ..rest]        // list with a tail (spread)
```

Lists are the prelude `List(a)` (`ListCons` / `ListEmpty` internally). Access
with patterns (see [03-patterns.md](03-patterns.md)).

## Custom types

```gleam
Ok(1)                       // constructor (prelude)
Error("nope")
Red                         // nullary constructor
Box(value: 1)               // labelled construction
Box(1)                      // positional construction (same value)
Colour(..base, red: 255)    // record update (copy with fields replaced)
```

Field access uses `.`:

```gleam
let Box(value) = box
box.value                   // labelled field access
pair.0                      // tuple index is not supported: pattern-match instead
```

> Tuples are matched/destructured, not indexed: use
> `let #(a, b) = pair`. `.0`/`.1` on tuples is not part of the parser.

## Calls, labelled arguments and pipelines

```gleam
io.println("hi")
list.map(xs, f)
process.call(inbox, waiting: 1000, sending: fn(reply) { Ping(reply) })
```

- `f(label: value)` is a **labelled argument**. It resolves when the
  corresponding parameter is named `label` (parameters cannot carry a separate
  label of their own).
- Pipelines insert the left value as the **first** argument of the right call:

  ```gleam
  value
  |> f(a)        // f(value, a)
  |> g           // g(value)
  ```

## Blocks, `let`, `let assert`, `use`

A block `{ ... }` is an expression. Its value is the last expression; if the
block ends in a statement it evaluates to `Nil`.

```gleam
let x = 1
let #(a, b) = pair
let assert Ok(value) = result    // aborts (panics) on mismatch

use name <- result.try(maybe)    // passes the rest of the block as a callback
name
```

- `let` / `let assert` bind patterns.
- `let x: T = ...` (a type annotation) is **not** supported.
- `use p1, p2 <- call(args)` desugars to
  `call(args, fn(p1, p2) { <rest of block> })`; complex patterns bind through
  a temporary.

## `case`

```gleam
case value {
  Red -> "red"
  Green | Blue -> "cool"
  Colour(..) if is_light -> "light"
  _ -> "other"
}
```

- Multiple subjects: `case a, b { ... }` (desugared to a tuple).
- Alternatives: `A | B -> ...`.
- Guards: `if <bool expr>` or `when <bool expr>` after the pattern.
- See [03-patterns.md](03-patterns.md) for patterns.

## Functions and closures

```gleam
fn add(a: Int, b: Int) -> Int { a + b }      // top-level
fn add(a, b) { a + b }                        // types inferred

let double = fn(x: Int) { x * 2 }             // closure
let add = fn(a, b) { a + b }                  // parameter types optional
```

Closures may capture variables from the enclosing scope; captures are stored
in an environment that the runtime retains/releases.

## `panic` and `todo`

```gleam
panic                         // aborts with the default message
panic as "unreachable"        // aborts with a literal message
todo
```

The message after `panic as` / `todo as` must be a **string literal** (an
expression is not accepted).

## Bit arrays

```gleam
<<>>                          // empty
<<1, 2, 3>>                   // bytes
```

Only 8-bit integer segments are supported: elements are plain expressions, and
there is no `:size`/`:unit`/`:utf8` suffix. `gleam/bit_array` adds
`from_string`/`to_string`/`byte_size`/`bit_size`/`append`/`concat`.
