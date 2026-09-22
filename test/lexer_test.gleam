import gleamc/lexer
import gleamc/token.{
  EofKind, FloatKind, IntKind, Keyword, NameKind, NewlineKind, StringKind,
  Symbol, Token, UpNameKind,
}

pub fn lex_arith_test() {
  let assert Ok([
    Token(IntKind(1), _, _),
    Token(Symbol("+"), _, _),
    Token(IntKind(2), _, _),
    Token(EofKind, _, _),
  ]) = lexer.tokenize("1 + 2")
}

pub fn lex_float_test() {
  let assert Ok([Token(FloatKind(3.14), _, _), Token(EofKind, _, _)]) =
    lexer.tokenize("3.14")
}

pub fn lex_float_exponent_test() {
  let assert Ok([Token(FloatKind(1.5e3), _, _), Token(EofKind, _, _)]) =
    lexer.tokenize("1.5e3")
  let assert Ok([Token(FloatKind(2.0e-4), _, _), Token(EofKind, _, _)]) =
    lexer.tokenize("2.0E-4")
}

pub fn lex_string_escape_test() {
  let assert Ok([Token(StringKind("hi\n"), _, _), Token(EofKind, _, _)]) =
    lexer.tokenize("\"hi\\n\"")
}

pub fn lex_let_newline_test() {
  let assert Ok([
    Token(Keyword("let"), _, _),
    Token(NameKind("x"), _, _),
    Token(Symbol("="), _, _),
    Token(IntKind(1), _, _),
    Token(NewlineKind, _, _),
    Token(NameKind("x"), _, _),
    Token(EofKind, _, _),
  ]) = lexer.tokenize("let x = 1\nx")
}

pub fn lex_newline_ignored_in_parens_test() {
  let assert Ok([
    Token(NameKind("f"), _, _),
    Token(Symbol("("), _, _),
    Token(IntKind(1), _, _),
    Token(Symbol(","), _, _),
    Token(IntKind(2), _, _),
    Token(Symbol(")"), _, _),
    Token(EofKind, _, _),
  ]) = lexer.tokenize("f(\n1,\n2)")
}

pub fn lex_upname_test() {
  let assert Ok([
    Token(UpNameKind("Some"), _, _),
    Token(Symbol("("), _, _),
    Token(IntKind(1), _, _),
    Token(Symbol(")"), _, _),
    Token(EofKind, _, _),
  ]) = lexer.tokenize("Some(1)")
}

pub fn lex_comment_test() {
  let assert Ok([
    Token(IntKind(1), _, _),
    Token(NewlineKind, _, _),
    Token(IntKind(2), _, _),
    Token(EofKind, _, _),
  ]) = lexer.tokenize("1 // comment\n2")
}
