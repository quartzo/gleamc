# 3. Patterns and `case`

## Pattern forms

| Pattern | Example |
|---|---|
| literal | `0`, `1.5`, `"text"`, `True`, `False`, `Nil` |
| wildcard | `_` |
| variable | `x` |
| constructor | `Ok(value)`, `Red`, `Box(a, b)` |
| qualified constructor | `option.Some(x)` |
| tuple | `#(a, b, c)` |
| list | `[]`, `[a, b]`, `[first, ..rest]` |
| bit array | `<<1, x, rest>>` (8-bit segments only) |
| as-binding | `pattern as name` |

Patterns appear in `let`, `let assert`, `use`, function parameters (as names),
and `case` arms.

```gleam
let #(a, b) = pair
let [first, ..rest] = items
case message {
  Ping(reply) -> reply
  Pong | Stop -> Nil
  Colour(r, g, b) as c if r > g -> c
  _ -> Nil
}
```

## `case`

```gleam
case subject {
  pattern -> expression
  pattern | pattern -> expression
  pattern if guard -> expression
}
```

- **Multiple subjects**: `case a, b { ... }` is desugared to a tuple subject,
  so each arm's patterns are separated by commas: `#(a_pat, b_pat)`.
- **Alternatives**: separate patterns with `|`; the same body runs for each.
- **Guards**: `case x { n if n > 0 -> ... }` (also spelled `when`). The guard
  is a `Bool` expression evaluated after the pattern matches.
- Arms bind variables introduced by their pattern; every arm must produce a
  value of the same type.

## Exhaustiveness

The checker warns about (and can reject) some non-exhaustive cases. Note the
documented limitation: exhaustiveness for **tuple subjects** (and multi-subject
`case`) checks each column independently, so it may accept a case that is not
actually exhaustive. See [../known-limitations.md](../known-limitations.md).

## Destructuring in argument position

Function parameters are plain names, so destructuring is done in the body:

```gleam
fn area(rect: #(Float, Float)) -> Float {
  let #(w, h) = rect
  w *. h
}
```
