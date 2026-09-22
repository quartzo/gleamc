//// Lexical tokens for the M1 subset.

pub type Kind {
  IntKind(Int)
  FloatKind(Float)
  StringKind(String)
  /// lowercase identifier (variables, functions, fields)
  NameKind(String)
  /// uppercase identifier (constructors, types)
  UpNameKind(String)
  /// reserved word (`pub`, `fn`, `let`, `case`, `type`, `import`, `as`)
  Keyword(String)
  /// operator/punctuation (`+`, `->`, `(`, `,`, `=`, …)
  Symbol(String)
  NewlineKind
  EofKind
}

pub type Token {
  Token(kind: Kind, line: Int, col: Int)
}

pub const keywords = [
  "as", "case", "fn", "if", "import", "let", "opaque", "pub", "type", "use",
  "when",
]

pub fn is_keyword(word: String) -> Bool {
  case word {
    "as"
    | "case"
    | "fn"
    | "if"
    | "import"
    | "let"
    | "opaque"
    | "pub"
    | "type"
    | "use"
    | "when" -> True
    _ -> False
  }
}

/// Textual representation of the kind (for error messages).
pub fn describe(kind: Kind) -> String {
  case kind {
    IntKind(_) -> "integer"
    FloatKind(_) -> "float"
    StringKind(_) -> "string"
    NameKind(name) -> "name `" <> name <> "`"
    UpNameKind(name) -> "constructor `" <> name <> "`"
    Keyword(word) -> "`" <> word <> "`"
    Symbol(sym) -> "`" <> sym <> "`"
    NewlineKind -> "newline"
    EofKind -> "end of file"
  }
}
