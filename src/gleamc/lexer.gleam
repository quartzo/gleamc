//// Lexer for the M1 Gleam subset.
////
//// Newline rule: inside `(` and `[` newlines are ignored; inside `{` and at
//// module level they are significant (the parser uses `Newline` as a
//// declaration/statement separator).

import gleam/float
import gleam/int
import gleam/list
import gleam/string
import gleamc/token.{
  type Token, EofKind, FloatKind, IntKind, Keyword, NameKind, NewlineKind,
  StringKind, Symbol, Token, UpNameKind, is_keyword,
}

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
  case scan(source, 1, 1, 0, []) {
    Ok(tokens) -> Ok(list.append(list.reverse(tokens), [Token(EofKind, 0, 0)]))
    Error(err) -> Error(err)
  }
}

// ---------------------------------------------------------------------------
// scanning
// ---------------------------------------------------------------------------

fn scan(
  src: String,
  line: Int,
  col: Int,
  depth: Int,
  acc: List(Token),
) -> Result(List(Token), LexError) {
  case src {
    "" -> Ok(acc)
    _ -> {
      let c = first(src)
      case c {
        "\n" -> newline(rest(src), line, col, depth, acc)
        " " | "\t" | "\r" -> scan(rest(src), line, col + 1, depth, acc)
        "/" ->
          case string.starts_with(src, "//") {
            True -> skip_comment(src, line, col, depth, acc)
            False -> symbol(src, line, col, depth, acc)
          }
        "\"" -> string_lit(rest(src), line, col + 1, depth, acc, [])
        _ ->
          case is_digit(c) {
            True -> number(src, line, col, depth, acc)
            False ->
              case is_ident_start(c) {
                True -> ident(src, line, col, depth, acc)
                False -> symbol(src, line, col, depth, acc)
              }
          }
      }
    }
  }
}

fn newline(src, line, col, depth, acc) -> Result(List(Token), LexError) {
  case depth > 0 {
    True -> scan(src, line + 1, 1, depth, acc)
    False ->
      case acc {
        [Token(NewlineKind, _, _), ..] -> scan(src, line + 1, 1, depth, acc)
        _ ->
          scan(src, line + 1, 1, depth, [Token(NewlineKind, line, col), ..acc])
      }
  }
}

fn skip_comment(src, line, col, depth, acc) -> Result(List(Token), LexError) {
  case src {
    "" -> Ok(acc)
    _ -> {
      let c = first(src)
      case c {
        "\n" -> newline(rest(src), line, col, depth, acc)
        _ -> skip_comment(rest(src), line, col + 1, depth, acc)
      }
    }
  }
}

fn string_lit(
  src,
  line,
  col,
  depth,
  acc,
  buf: List(String),
) -> Result(List(Token), LexError) {
  case src {
    "" -> Error(LexError("unterminated string", line, col))
    _ -> {
      let c = first(src)
      let r = rest(src)
      case c {
        "\"" ->
          scan(r, line, col + 1, depth, [
            Token(StringKind(string.concat(list.reverse(buf))), line, col),
            ..acc
          ])
        "\\" -> escape(r, line, col + 1, depth, acc, buf)
        "\n" -> string_lit(r, line + 1, 1, depth, acc, ["\n", ..buf])
        _ -> string_lit(r, line, col + 1, depth, acc, [c, ..buf])
      }
    }
  }
}

fn escape(src, line, col, depth, acc, buf) -> Result(List(Token), LexError) {
  case src {
    "" -> Error(LexError("incomplete escape", line, col))
    _ -> {
      let c = first(src)
      let decoded = case c {
        "n" -> "\n"
        "t" -> "\t"
        "r" -> "\r"
        "\"" -> "\""
        "\\" -> "\\"
        _ -> c
      }
      string_lit(rest(src), line, col + 1, depth, acc, [decoded, ..buf])
    }
  }
}

fn take_exponent(src) -> #(String, String) {
  case first(src) {
    "e" | "E" -> {
      let after = rest(src)
      let #(sign, after2) = case first(after) {
        "+" | "-" -> #(first(after), rest(after))
        _ -> #("", after)
      }
      let #(digits, after3) = take_while(after2, is_digit_or_underscore)
      case digits == "" {
        True -> #("", src)
        False -> #("e" <> sign <> digits, after3)
      }
    }
    _ -> #("", src)
  }
}

fn number(src, line, col, depth, acc) -> Result(List(Token), LexError) {
  let #(int_part, rest1) = take_while(src, is_digit_or_underscore)
  let #(is_float, text, rest2) = case string.starts_with(rest1, ".") {
    True -> {
      let after = rest(rest1)
      case is_digit(first(after)) {
        True -> {
          let #(frac, rest2) = take_while(after, is_digit_or_underscore)
          #(True, int_part <> "." <> frac, rest2)
        }
        False -> #(False, int_part, rest1)
      }
    }
    False -> #(False, int_part, rest1)
  }
  let #(exp_text, rest3) = case is_float {
    True -> take_exponent(rest2)
    False -> #("", rest2)
  }
  let text = text <> exp_text
  let clean = string.replace(text, "_", "")
  let col2 = col + string.length(text)
  case is_float {
    True ->
      case float.parse(clean) {
        Ok(value) ->
          scan(rest3, line, col2, depth, [
            Token(FloatKind(value), line, col),
            ..acc
          ])
        Error(_) -> Error(LexError("invalid float: " <> text, line, col))
      }
    False ->
      case int.parse(clean) {
        Ok(value) ->
          scan(rest3, line, col2, depth, [
            Token(IntKind(value), line, col),
            ..acc
          ])
        Error(_) -> Error(LexError("invalid integer: " <> text, line, col))
      }
  }
}

fn ident(src, line, col, depth, acc) -> Result(List(Token), LexError) {
  let #(text, rest_src) = take_while(src, is_ident_char)
  let col2 = col + string.length(text)
  let kind = case is_upper(first(text)) {
    True -> UpNameKind(text)
    False ->
      case is_keyword(text) {
        True -> Keyword(text)
        False -> NameKind(text)
      }
  }
  scan(rest_src, line, col2, depth, [Token(kind, line, col), ..acc])
}

fn symbol(src, line, col, depth, acc) -> Result(List(Token), LexError) {
  let three = string.slice(src, 0, 3)
  case three {
    "<=." | ">=." -> {
      let rest_src = rest(rest(rest(src)))
      scan(rest_src, line, col + 3, depth, [
        Token(Symbol(three), line, col),
        ..acc
      ])
    }
    _ -> symbol_two(src, line, col, depth, acc)
  }
}

fn symbol_two(src, line, col, depth, acc) -> Result(List(Token), LexError) {
  let two = string.slice(src, 0, 2)
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
      let rest_src = rest(rest(src))
      scan(rest_src, line, col + 2, depth, [
        Token(Symbol(two), line, col),
        ..acc
      ])
    }
    _ -> {
      let c = first(src)
      case is_symbol_char(c) {
        True -> {
          let depth2 = case c {
            "(" | "[" -> depth + 1
            ")" | "]" -> max_int(0, depth - 1)
            _ -> depth
          }
          scan(rest(src), line, col + 1, depth2, [
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

fn first(s: String) -> String {
  case string.pop_grapheme(s) {
    Ok(#(g, _)) -> g
    Error(_) -> ""
  }
}

fn rest(s: String) -> String {
  case string.pop_grapheme(s) {
    Ok(#(_, r)) -> r
    Error(_) -> ""
  }
}

fn take_while(src: String, pred: fn(String) -> Bool) -> #(String, String) {
  take_while_loop(src, pred, [])
}

fn take_while_loop(
  src: String,
  pred: fn(String) -> Bool,
  acc: List(String),
) -> #(String, String) {
  case src {
    "" -> #(string.concat(list.reverse(acc)), "")
    _ -> {
      let c = first(src)
      case pred(c) {
        True -> take_while_loop(rest(src), pred, [c, ..acc])
        False -> #(string.concat(list.reverse(acc)), src)
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
