//// Lexer for the M1 Gleam subset.
////
//// Newline rule: inside `(` and `[` newlines are ignored; inside `{` and at
//// module level they are significant (the parser uses `Newline` as a
//// declaration/statement separator).
////
//// Scanning is byte-offset based: the source is never re-sliced as a cursor,
//// so tokenizing is O(n) instead of copying the remaining source at every
//// character (`pop_grapheme` + `string.slice` were O(n) per character on the
//// C runtime, making the whole lexer O(n^2)).

import gleam/float
import gleam/int
import gleam/list
import gleam/string
import gleamc/token.{
  type Token, EofKind, FloatKind, IntKind, Keyword, NameKind, NewlineKind,
  StringKind, Symbol, Token, UpNameKind, is_keyword,
}
import host

pub type LexError {
  LexError(message: String, line: Int, col: Int)
}

pub fn describe_error(err: LexError) -> String {
  let LexError(message: message, line: line, col: col) = err
  "lex error at "
  <> int.to_string(line)
  <> ":"
  <> int.to_string(col)
  <> ": "
  <> message
}

pub fn tokenize(source: String) -> Result(List(Token), LexError) {
  case scan(source, 0, 1, 1, 0, []) {
    Ok(tokens) -> Ok(list.append(list.reverse(tokens), [Token(EofKind, 0, 0)]))
    Error(err) -> Error(err)
  }
}

// ---------------------------------------------------------------------------
// scanning
// ---------------------------------------------------------------------------

fn scan(
  src: String,
  off: Int,
  line: Int,
  col: Int,
  depth: Int,
  acc: List(Token),
) -> Result(List(Token), LexError) {
  case is_eof(src, off) {
    True -> Ok(acc)
    False -> {
      let c = char_at(src, off)
      case c {
        "\n" -> newline(src, advance(src, off), line, col, depth, acc)
        " " | "\t" | "\r" ->
          scan(src, advance(src, off), line, col + 1, depth, acc)
        "/" ->
          case starts_with(src, off, "//") {
            True -> skip_comment(src, off, line, col, depth, acc)
            False -> symbol(src, off, line, col, depth, acc)
          }
        "\"" ->
          string_lit(src, advance(src, off), line, col + 1, depth, acc, [])
        _ ->
          case is_digit(c) {
            True -> number(src, off, line, col, depth, acc)
            False ->
              case is_ident_start(c) {
                True -> ident(src, off, line, col, depth, acc)
                False -> symbol(src, off, line, col, depth, acc)
              }
          }
      }
    }
  }
}

fn newline(src, off, line, col, depth, acc) -> Result(List(Token), LexError) {
  case depth > 0 {
    True -> scan(src, off, line + 1, 1, depth, acc)
    False ->
      case acc {
        [Token(NewlineKind, _, _), ..] ->
          scan(src, off, line + 1, 1, depth, acc)
        _ ->
          scan(src, off, line + 1, 1, depth, [
            Token(NewlineKind, line, col),
            ..acc
          ])
      }
  }
}

fn skip_comment(
  src,
  off,
  line,
  col,
  depth,
  acc,
) -> Result(List(Token), LexError) {
  case is_eof(src, off) {
    True -> Ok(acc)
    False -> {
      let c = char_at(src, off)
      case c {
        "\n" -> newline(src, advance(src, off), line, col, depth, acc)
        _ -> skip_comment(src, advance(src, off), line, col + 1, depth, acc)
      }
    }
  }
}

fn string_lit(
  src,
  off,
  line,
  col,
  depth,
  acc,
  buf: List(String),
) -> Result(List(Token), LexError) {
  case is_eof(src, off) {
    True -> Error(LexError("unterminated string", line, col))
    False -> {
      let c = char_at(src, off)
      let next = advance(src, off)
      case c {
        "\"" ->
          scan(src, next, line, col + 1, depth, [
            Token(StringKind(string.concat(list.reverse(buf))), line, col),
            ..acc
          ])
        "\\" -> escape(src, next, line, col + 1, depth, acc, buf)
        "\n" -> string_lit(src, next, line + 1, 1, depth, acc, ["\n", ..buf])
        _ -> string_lit(src, next, line, col + 1, depth, acc, [c, ..buf])
      }
    }
  }
}

fn escape(
  src,
  off,
  line,
  col,
  depth,
  acc,
  buf,
) -> Result(List(Token), LexError) {
  case is_eof(src, off) {
    True -> Error(LexError("incomplete escape", line, col))
    False -> {
      let c = char_at(src, off)
      let decoded = case c {
        "n" -> "\n"
        "t" -> "\t"
        "r" -> "\r"
        "\"" -> "\""
        "\\" -> "\\"
        _ -> c
      }
      string_lit(src, advance(src, off), line, col + 1, depth, acc, [
        decoded,
        ..buf
      ])
    }
  }
}

fn take_exponent(src, off) -> #(String, Int) {
  case char_at(src, off) {
    "e" | "E" -> {
      let off1 = advance(src, off)
      let #(sign, off2) = case char_at(src, off1) {
        "+" | "-" -> #(char_at(src, off1), advance(src, off1))
        _ -> #("", off1)
      }
      let #(digits, off3) = take_while(src, off2, is_digit_or_underscore)
      case digits == "" {
        True -> #("", off)
        False -> #("e" <> sign <> digits, off3)
      }
    }
    _ -> #("", off)
  }
}

fn number(src, off, line, col, depth, acc) -> Result(List(Token), LexError) {
  let #(int_part, off1) = take_while(src, off, is_digit_or_underscore)
  let #(is_float, text, off2) = case starts_with(src, off1, ".") {
    True -> {
      let after = advance(src, off1)
      case is_digit(char_at(src, after)) {
        True -> {
          let #(frac, off2) = take_while(src, after, is_digit_or_underscore)
          #(True, int_part <> "." <> frac, off2)
        }
        False -> #(False, int_part, off1)
      }
    }
    False -> #(False, int_part, off1)
  }
  let #(exp_text, off3) = case is_float {
    True -> take_exponent(src, off2)
    False -> #("", off2)
  }
  let text = text <> exp_text
  let clean = string.replace(text, "_", "")
  let col2 = col + string.length(text)
  case is_float {
    True ->
      case float.parse(clean) {
        Ok(value) ->
          scan(src, off3, line, col2, depth, [
            Token(FloatKind(value), line, col),
            ..acc
          ])
        Error(_) -> Error(LexError("invalid float: " <> text, line, col))
      }
    False ->
      case int.parse(clean) {
        Ok(value) ->
          scan(src, off3, line, col2, depth, [
            Token(IntKind(value), line, col),
            ..acc
          ])
        Error(_) -> Error(LexError("invalid integer: " <> text, line, col))
      }
  }
}

fn ident(src, off, line, col, depth, acc) -> Result(List(Token), LexError) {
  let #(text, off2) = take_while(src, off, is_ident_char)
  let col2 = col + string.length(text)
  let kind = case is_upper(char_at(text, 0)) {
    True -> UpNameKind(text)
    False ->
      case is_keyword(text) {
        True -> Keyword(text)
        False -> NameKind(text)
      }
  }
  scan(src, off2, line, col2, depth, [Token(kind, line, col), ..acc])
}

fn symbol(src, off, line, col, depth, acc) -> Result(List(Token), LexError) {
  let three = host.byte_slice(src, off, 3)
  case three {
    "<=." | ">=." -> {
      let off3 = advance(src, advance(src, advance(src, off)))
      scan(src, off3, line, col + 3, depth, [
        Token(Symbol(three), line, col),
        ..acc
      ])
    }
    _ -> symbol_two(src, off, line, col, depth, acc)
  }
}

fn symbol_two(
  src,
  off,
  line,
  col,
  depth,
  acc,
) -> Result(List(Token), LexError) {
  let two = host.byte_slice(src, off, 2)
  case two {
    "->"
    | "|>"
    | "<>"
    | "=="
    | "!="
    | "<="
    | ">="
    | "&&"
    | "||"
    | ".."
    | "<<"
    | ">>"
    | "+."
    | "-."
    | "*."
    | "/."
    | "<."
    | ">."
    | "<-" -> {
      let off2 = advance(src, advance(src, off))
      scan(src, off2, line, col + 2, depth, [
        Token(Symbol(two), line, col),
        ..acc
      ])
    }
    _ -> {
      let c = char_at(src, off)
      case is_symbol_char(c) {
        True -> {
          let depth2 = case c {
            "(" | "[" -> depth + 1
            ")" | "]" -> max_int(0, depth - 1)
            _ -> depth
          }
          scan(src, advance(src, off), line, col + 1, depth2, [
            Token(Symbol(c), line, col),
            ..acc
          ])
        }
        False ->
          Error(LexError("unexpected character: `" <> c <> "`", line, col))
      }
    }
  }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn is_eof(src: String, off: Int) -> Bool {
  host.char_code_at(src, off) < 0
}

fn char_at(src: String, off: Int) -> String {
  host.byte_slice(src, off, host.char_byte_len(src, off))
}

fn advance(src: String, off: Int) -> Int {
  off + host.char_byte_len(src, off)
}

fn starts_with(src: String, off: Int, pattern: String) -> Bool {
  host.byte_slice(src, off, string.length(pattern)) == pattern
}

fn take_while(
  src: String,
  off: Int,
  pred: fn(String) -> Bool,
) -> #(String, Int) {
  take_while_loop(src, off, pred, off)
}

fn take_while_loop(
  src: String,
  off: Int,
  pred: fn(String) -> Bool,
  start: Int,
) -> #(String, Int) {
  case is_eof(src, off) {
    True -> #(host.byte_slice(src, start, off - start), off)
    False -> {
      let c = char_at(src, off)
      case pred(c) {
        True -> take_while_loop(src, advance(src, off), pred, start)
        False -> #(host.byte_slice(src, start, off - start), off)
      }
    }
  }
}

fn is_digit(c: String) -> Bool {
  string.contains("0123456789", c)
}

fn is_digit_or_underscore(c: String) -> Bool {
  is_digit(c) || c == "_"
}

fn is_upper(c: String) -> Bool {
  string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c)
}

fn is_lower(c: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyz", c)
}

fn is_ident_start(c: String) -> Bool {
  is_lower(c) || is_upper(c) || c == "_"
}

fn is_ident_char(c: String) -> Bool {
  is_ident_start(c) || is_digit(c)
}

fn is_symbol_char(c: String) -> Bool {
  string.contains("()[]{},.:=+-*/%<>!#|@", c)
}

fn max_int(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}
