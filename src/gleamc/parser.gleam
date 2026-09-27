//// Parser for the M1 Gleam subset: recursive descent over the token list.
//// Deferred sugar (type aliases, closures, generics, `use`) comes in later
//// milestones.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleamc/ast.{
  type Expr, type Module, Arm, CustomType, DConst, DCustomType, DExternal,
  DFunction, DImport, DTypeAlias, EBinop, EBitArray, EBlock, EBool, ECall, ECase,
  ECtor, EField, EFloat, EInt, ELabelled, ELambda, ENil, EPanic, EString, ETuple,
  EUnop, EUpdate, EVar, External, Function, Import, Let, Module, PAs, PBitArray,
  PBool, PCtor, PFloat, PInt, PLabelled, PNil, PString, PTuple, PVar, PWildcard,
  Stmt, TApp, TBool, TFloat, TFun, TInt, TNamed, TNil, TString, TTuple, TVar,
  Variant,
}
import gleamc/lexer
import gleamc/token.{
  type Token, EofKind, FloatKind, IntKind, Keyword, NameKind, NewlineKind,
  StringKind, Symbol, Token, UpNameKind,
}

pub type ParseError {
  ParseError(message: String, line: Int, col: Int)
}

pub fn describe_error(err: ParseError) -> String {
  let ParseError(message: message, line: line, col: col) = err
  "syntax error at "
  <> int.to_string(line)
  <> ":"
  <> int.to_string(col)
  <> ": "
  <> message
}

pub fn parse(source: String) -> Result(Module, ParseError) {
  case lexer.tokenize(source) {
    Error(lex_err) -> Error(ParseError(lexer.describe_error(lex_err), 0, 0))
    Ok(tokens) -> {
      case definitions(skip_newlines(tokens), []) {
        Error(err) -> Error(err)
        Ok(#(defs, _)) -> Ok(Module(defs))
      }
    }
  }
}

// ---------------------------------------------------------------------------
// combinators
// ---------------------------------------------------------------------------

fn and_then(result, next) {
  case result {
    Error(err) -> Error(err)
    Ok(value) -> next(value)
  }
}

fn fail(tokens, message) -> Result(a, ParseError) {
  case tokens {
    [Token(_, line, col), ..] -> Error(ParseError(message, line, col))
    [] -> Error(ParseError(message, 0, 0))
  }
}

fn peek(tokens) {
  case tokens {
    [Token(kind, _, _), ..] -> kind
    [] -> EofKind
  }
}

fn drop_token(tokens) {
  case tokens {
    [_, ..rest] -> rest
    [] -> []
  }
}

fn skip_newlines(tokens) {
  case tokens {
    [Token(NewlineKind, _, _), ..rest] -> skip_newlines(rest)
    _ -> tokens
  }
}

fn at_symbol(tokens, sym) {
  case tokens {
    [Token(Symbol(s), _, _), ..] -> s == sym
    _ -> False
  }
}

fn expect_symbol(tokens, sym) {
  case tokens {
    [Token(Symbol(s), _, _), ..rest] ->
      case s == sym {
        True -> Ok(rest)
        False -> fail(tokens, "expected `" <> sym <> "`, found `" <> s <> "`")
      }
    _ -> fail(tokens, "expected `" <> sym <> "`")
  }
}

fn expect_keyword(tokens, word) {
  case tokens {
    [Token(Keyword(w), _, _), ..rest] ->
      case w == word {
        True -> Ok(rest)
        False -> fail(tokens, "expected `" <> word <> "`, found `" <> w <> "`")
      }
    _ -> fail(tokens, "expected `" <> word <> "`")
  }
}

fn expect_name(tokens) {
  case tokens {
    [Token(NameKind(name), _, _), ..rest] -> Ok(#(name, rest))
    _ -> fail(tokens, "expected a name")
  }
}

fn expect_upname(tokens) {
  case tokens {
    [Token(UpNameKind(name), _, _), ..rest] -> Ok(#(name, rest))
    _ -> fail(tokens, "expected a type/constructor name")
  }
}

// ---------------------------------------------------------------------------
// declarations
// ---------------------------------------------------------------------------

fn definitions(tokens, acc) {
  case peek(tokens) {
    EofKind -> Ok(#(list.reverse(acc), tokens))
    NewlineKind -> definitions(skip_newlines(tokens), acc)
    Keyword("import") -> {
      use #(imp, rest) <- and_then(import_decl(tokens))
      definitions(skip_newlines(rest), [DImport(imp), ..acc])
    }
    Keyword("pub") -> {
      let rest = skip_newlines(drop_token(tokens))
      case peek(rest) {
        Keyword("fn") -> definition_fn(rest, True, acc)
        Keyword("type") -> definition_type(rest, True, False, acc)
        Keyword("opaque") ->
          definition_type(skip_newlines(drop_token(rest)), True, True, acc)
        Keyword("const") -> definition_const(drop_token(rest), acc)
        _ -> fail(rest, "expected `fn`, `type` or `const` after `pub`")
      }
    }
    Keyword("fn") -> definition_fn(tokens, False, acc)
    Keyword("const") -> definition_const(drop_token(tokens), acc)
    Keyword("type") -> definition_type(tokens, False, False, acc)
    Keyword("opaque") ->
      definition_type(skip_newlines(drop_token(tokens)), False, True, acc)
    Symbol("@") -> {
      use #(target, symbol, rest) <- and_then(attribute(tokens))
      let rest = skip_newlines(rest)
      case peek(rest) {
        Keyword("pub") -> {
          let r = skip_newlines(drop_token(rest))
          case peek(r) {
            Keyword("fn") -> {
              use #(ext, rest2) <- and_then(external_rest(
                skip_newlines(drop_token(r)),
                True,
                target,
                symbol,
              ))
              definitions(skip_newlines(rest2), [DExternal(ext), ..acc])
            }
            _ -> fail(r, "expected `fn` after `pub`")
          }
        }
        Keyword("fn") -> {
          use #(ext, rest2) <- and_then(external_rest(
            skip_newlines(drop_token(rest)),
            False,
            target,
            symbol,
          ))
          definitions(skip_newlines(rest2), [DExternal(ext), ..acc])
        }
        _ -> fail(rest, "expected a function declaration after an attribute")
      }
    }
    _ ->
      fail(tokens, "expected a declaration (`import`, `pub fn`, `fn`, `type`)")
  }
}

/// `@external(target, "symbol")` (or `@external(target, "module", "function")`).
/// Returns `#(target, symbol, rest)`.
fn attribute(tokens) {
  use rest <- and_then(expect_symbol(tokens, "@"))
  use #(name, rest1) <- and_then(expect_name(rest))
  case name {
    "external" -> {
      use rest2 <- and_then(expect_symbol(skip_newlines(rest1), "("))
      use #(args, rest3) <- and_then(attribute_args(skip_newlines(rest2), []))
      use rest4 <- and_then(expect_symbol(skip_newlines(rest3), ")"))
      case args {
        [target, ..parts] -> Ok(#(target, string.join(parts, "."), rest4))
        [] -> fail(rest1, "@external expects a target and a symbol")
      }
    }
    _ -> fail(rest1, "unknown attribute `@" <> name <> "`")
  }
}

fn attribute_args(tokens, acc) {
  let tokens = skip_newlines(tokens)
  case peek(tokens) {
    NameKind(_) -> {
      use #(name, rest) <- and_then(expect_name(tokens))
      attribute_args_more(rest, [name, ..acc])
    }
    StringKind(_) -> {
      let #(value, rest) = case tokens {
        [Token(StringKind(v), _, _), ..rest] -> #(v, rest)
        _ -> #("", tokens)
      }
      attribute_args_more(rest, [value, ..acc])
    }
    _ -> Ok(#(list.reverse(acc), tokens))
  }
}

fn attribute_args_more(tokens, acc) {
  let tokens = skip_newlines(tokens)
  case peek(tokens) {
    Symbol(",") -> attribute_args(skip_newlines(drop_token(tokens)), acc)
    _ -> Ok(#(list.reverse(acc), tokens))
  }
}

/// A bodyless `@external` function declaration.
fn external_rest(tokens, is_pub, target, symbol) {
  let line = case tokens {
    [Token(_, at_line, _), ..] -> at_line
    [] -> 0
  }
  use #(name, rest) <- and_then(expect_name(tokens))
  use rest1 <- and_then(expect_symbol(rest, "("))
  use #(ps, rest2) <- and_then(params(rest1, []))
  let #(ret, rest3) = parse_optional_return(skip_newlines(rest2))
  let rest4 = skip_newlines(rest3)
  case peek(rest4) {
    Symbol("{") -> fail(rest4, "@external functions must not have a body")
    _ -> Ok(#(External(is_pub, name, ps, ret, target, symbol, line), rest4))
  }
}

fn definition_const(tokens, acc) {
  use #(name, rest) <- and_then(expect_name(skip_newlines(tokens)))
  use rest1 <- and_then(expect_symbol(skip_newlines(rest), "="))
  use #(value, rest2) <- and_then(parse_expr(skip_newlines(rest1)))
  definitions(skip_newlines(rest2), [DConst(name, value), ..acc])
}

fn definition_fn(tokens, is_pub, acc) {
  use rest <- and_then(expect_keyword(tokens, "fn"))
  use #(fn_def, rest1) <- and_then(function_rest(skip_newlines(rest), is_pub))
  definitions(skip_newlines(rest1), [DFunction(fn_def), ..acc])
}

fn function_rest(tokens, is_pub) {
  let line = case tokens {
    [Token(_, at_line, _), ..] -> at_line
    [] -> 0
  }
  use #(name, rest) <- and_then(expect_name(tokens))
  use rest1 <- and_then(expect_symbol(rest, "("))
  use #(ps, rest2) <- and_then(params(rest1, []))
  let #(ret, rest3) = parse_optional_return(skip_newlines(rest2))
  use #(body, rest5) <- and_then(parse_block(skip_newlines(rest3)))
  Ok(#(Function(is_pub, name, ps, ret, body, line), rest5))
}

fn parse_optional_return(tokens) {
  case peek(tokens) {
    Symbol("->") -> {
      let assert Ok(#(ty, rest)) = parse_type(skip_newlines(drop_token(tokens)))
      #(ty, rest)
    }
    _ -> #(TVar("__infer_return"), tokens)
  }
}

fn params(tokens, acc) {
  case peek(tokens) {
    Symbol(")") -> Ok(#(list.reverse(acc), drop_token(tokens)))
    _ -> {
      use #(name, rest) <- and_then(expect_name(tokens))
      let #(ty, rest1) = case peek(rest) {
        Symbol(":") -> {
          let assert Ok(#(parsed, after)) =
            parse_type(skip_newlines(drop_token(rest)))
          #(parsed, after)
        }
        _ -> #(TVar("__infer_" <> name), rest)
      }
      let acc2 = [#(name, ty), ..acc]
      case peek(rest1) {
        Symbol(",") -> params(drop_token(rest1), acc2)
        Symbol(")") -> Ok(#(list.reverse(acc2), drop_token(rest1)))
        _ -> fail(rest1, "expected `,` or `)` in parameter list")
      }
    }
  }
}

fn definition_type(tokens, is_pub, is_opaque, acc) {
  use rest <- and_then(expect_keyword(tokens, "type"))
  use #(name, rest1) <- and_then(expect_upname(skip_newlines(rest)))
  let #(generics, rest1) = parse_generics(skip_newlines(rest1))
  let rest2 = skip_newlines(rest1)
  case peek(rest2) {
    Symbol("=") -> {
      use #(ty, rest3) <- and_then(parse_type(skip_newlines(drop_token(rest2))))
      definitions(skip_newlines(rest3), [
        DTypeAlias(is_pub, name, generics, ty),
        ..acc
      ])
    }
    _ -> {
      use rest3 <- and_then(expect_symbol(rest2, "{"))
      use #(variants, rest4) <- and_then(variants(skip_newlines(rest3), []))
      definitions(skip_newlines(rest4), [
        DCustomType(CustomType(is_pub, name, generics, variants, is_opaque)),
        ..acc
      ])
    }
  }
}

/// Parses the optional `(a, b, ...)` type parameter list of a declaration.
fn parse_generics(tokens) {
  case peek(tokens) {
    Symbol("(") -> {
      let assert Ok(#(names, rest)) = generic_names(drop_token(tokens), [])
      #(names, rest)
    }
    _ -> #([], tokens)
  }
}

fn generic_names(tokens, acc) {
  case peek(tokens) {
    Symbol(")") -> Ok(#(list.reverse(acc), drop_token(tokens)))
    _ -> {
      use #(name, rest) <- and_then(expect_name(tokens))
      let acc2 = [name, ..acc]
      case peek(rest) {
        Symbol(",") -> generic_names(drop_token(rest), acc2)
        Symbol(")") -> Ok(#(list.reverse(acc2), drop_token(rest)))
        _ -> fail(rest, "expected `,` or `)` in type parameters")
      }
    }
  }
}

fn variants(tokens, acc) {
  case peek(tokens) {
    Symbol("}") -> Ok(#(list.reverse(acc), drop_token(tokens)))
    EofKind -> fail(tokens, "`type` not closed")
    _ -> {
      use #(v, rest) <- and_then(variant(tokens))
      let nxt = skip_newlines(rest)
      case peek(nxt) {
        Symbol("}") -> Ok(#(list.reverse([v, ..acc]), drop_token(nxt)))
        EofKind -> fail(nxt, "`type` not closed")
        _ -> variants(nxt, [v, ..acc])
      }
    }
  }
}

fn variant(tokens) {
  use #(name, rest) <- and_then(expect_upname(tokens))
  case peek(rest) {
    Symbol("(") -> {
      use #(fields, rest2) <- and_then(variant_fields(drop_token(rest), [], 0))
      Ok(#(Variant(name, fields), rest2))
    }
    _ -> Ok(#(Variant(name, []), rest))
  }
}

fn variant_fields(tokens, acc, index) {
  case peek(tokens) {
    Symbol(")") -> Ok(#(list.reverse(acc), drop_token(tokens)))
    _ -> {
      case peek(tokens), peek(drop_token(tokens)) {
        NameKind(field_name), Symbol(":") -> {
          use rest1 <- and_then(expect_symbol(drop_token(tokens), ":"))
          use #(ty, rest2) <- and_then(parse_type(rest1))
          variant_fields_tail(rest2, [#(field_name, ty), ..acc], index + 1)
        }
        _, _ -> {
          use #(ty, rest2) <- and_then(parse_type(tokens))
          variant_fields_tail(
            rest2,
            [#(positional_field_name(index), ty), ..acc],
            index + 1,
          )
        }
      }
    }
  }
}

fn variant_fields_tail(rest2, acc, index) {
  case peek(rest2) {
    Symbol(",") -> variant_fields(skip_newlines(drop_token(rest2)), acc, index)
    Symbol(")") -> Ok(#(list.reverse(acc), drop_token(rest2)))
    _ -> fail(rest2, "expected `,` or `)` in variant fields")
  }
}

fn positional_field_name(index: Int) -> String {
  "_" <> int.to_string(index)
}

fn import_decl(tokens) {
  use rest <- and_then(expect_keyword(tokens, "import"))
  import_path(skip_newlines(rest), [])
}

fn import_path(tokens, acc) {
  use #(seg, rest) <- and_then(expect_name(tokens))
  let acc2 = [seg, ..acc]
  case peek(rest) {
    Symbol("/") -> import_path(drop_token(rest), acc2)
    Symbol(".") -> {
      case peek(drop_token(rest)) {
        Symbol("{") -> {
          use #(items, rest2) <- and_then(
            import_items(drop_token(drop_token(rest)), []),
          )
          Ok(#(Import(list.reverse(acc2), items), rest2))
        }
        _ -> fail(rest, "expected `{` after `.` in import")
      }
    }
    _ -> Ok(#(Import(list.reverse(acc2), []), rest))
  }
}

fn import_items(tokens, acc) {
  let tokens = skip_newlines(tokens)
  case peek(tokens) {
    Symbol("}") -> Ok(#(list.reverse(acc), drop_token(tokens)))
    _ -> {
      let tokens2 = case peek(tokens) {
        Keyword("type") -> drop_token(tokens)
        _ -> tokens
      }
      use #(name, rest) <- and_then(expect_item_name(tokens2))
      case peek(rest) {
        Symbol(",") -> import_items(drop_token(rest), [name, ..acc])
        Symbol("}") -> Ok(#(list.reverse([name, ..acc]), drop_token(rest)))
        _ -> fail(rest, "expected `,` or `}` in import items")
      }
    }
  }
}

fn expect_item_name(tokens) {
  case tokens {
    [Token(NameKind(n), _, _), ..rest] -> Ok(#(n, rest))
    [Token(UpNameKind(n), _, _), ..rest] -> Ok(#(n, rest))
    _ -> fail(tokens, "expected an import item")
  }
}

// ---------------------------------------------------------------------------
// types
// ---------------------------------------------------------------------------

fn parse_type(tokens) {
  case tokens {
    [Token(Keyword("fn"), _, _), ..rest] -> parse_fun_type(rest)
    [
      Token(NameKind(module), _, _),
      Token(Symbol("."), _, _),
      Token(UpNameKind(name), _, _),
      ..rest
    ] -> {
      // Qualified types (`mod.Type`); the module is kept in the name so the
      // merge pass can scope it.
      let qualified = module <> "_" <> name
      case peek(rest) {
        Symbol("(") -> {
          use #(args, rest2) <- and_then(parse_type_args(drop_token(rest), []))
          Ok(#(TApp(qualified, args), rest2))
        }
        _ -> Ok(#(TNamed(qualified), rest))
      }
    }
    [Token(UpNameKind("Int"), _, _), ..rest] -> Ok(#(TInt, rest))
    [Token(UpNameKind("Float"), _, _), ..rest] -> Ok(#(TFloat, rest))
    [Token(UpNameKind("Bool"), _, _), ..rest] -> Ok(#(TBool, rest))
    [Token(UpNameKind("String"), _, _), ..rest] -> Ok(#(TString, rest))
    [Token(UpNameKind("Nil"), _, _), ..rest] -> Ok(#(TNil, rest))
    [Token(UpNameKind(name), _, _), ..rest] ->
      case peek(rest) {
        Symbol("(") -> {
          use #(args, rest2) <- and_then(parse_type_args(drop_token(rest), []))
          Ok(#(TApp(name, args), rest2))
        }
        _ -> Ok(#(TNamed(name), rest))
      }
    [Token(NameKind(name), _, _), ..rest] -> Ok(#(TVar(name), rest))
    _ ->
      case at_symbol(tokens, "#") {
        True -> parse_tuple_type(drop_token(tokens))
        False -> fail(tokens, "expected a type")
      }
  }
}

/// Parses `(T1, T2, ...)` for a generic type application.
fn parse_type_args(tokens, acc) {
  case peek(tokens) {
    Symbol(")") -> Ok(#(list.reverse(acc), drop_token(tokens)))
    _ -> {
      use #(ty, rest) <- and_then(parse_type(tokens))
      let acc2 = [ty, ..acc]
      case peek(rest) {
        Symbol(",") -> parse_type_args(drop_token(rest), acc2)
        Symbol(")") -> Ok(#(list.reverse(acc2), drop_token(rest)))
        _ -> fail(rest, "expected `,` or `)` in type arguments")
      }
    }
  }
}

fn parse_fun_type(tokens) {
  use rest <- and_then(expect_symbol(tokens, "("))
  use #(params, rest1) <- and_then(parse_fun_type_params(rest, []))
  use rest2 <- and_then(expect_symbol(rest1, "->"))
  use #(ret, rest3) <- and_then(parse_type(rest2))
  Ok(#(TFun(params, ret), rest3))
}

fn parse_fun_type_params(tokens, acc) {
  case peek(tokens) {
    Symbol(")") -> Ok(#(list.reverse(acc), drop_token(tokens)))
    _ -> {
      use #(ty, rest) <- and_then(parse_type(tokens))
      let acc2 = [ty, ..acc]
      case peek(rest) {
        Symbol(",") -> parse_fun_type_params(drop_token(rest), acc2)
        Symbol(")") -> Ok(#(list.reverse(acc2), drop_token(rest)))
        _ -> fail(rest, "expected `,` or `)` in function type")
      }
    }
  }
}

fn parse_tuple_type(tokens) {
  use rest <- and_then(expect_symbol(tokens, "("))
  parse_type_list(rest, [])
}

fn parse_type_list(tokens, acc) {
  case peek(tokens) {
    Symbol(")") -> Ok(#(TTuple(list.reverse(acc)), drop_token(tokens)))
    _ -> {
      use #(ty, rest) <- and_then(parse_type(tokens))
      let acc2 = [ty, ..acc]
      case peek(rest) {
        Symbol(",") -> parse_type_list(drop_token(rest), acc2)
        Symbol(")") -> Ok(#(TTuple(list.reverse(acc2)), drop_token(rest)))
        _ -> fail(rest, "expected `,` or `)` in tuple type")
      }
    }
  }
}

// ---------------------------------------------------------------------------
// blocks and statements
// ---------------------------------------------------------------------------

fn parse_block(tokens) {
  use rest <- and_then(expect_symbol(tokens, "{"))
  statements(skip_newlines(rest), [])
}

fn statements(tokens, acc) {
  case peek(tokens) {
    Symbol("}") -> {
      let stmts = case acc {
        [Stmt(_), ..] -> list.reverse(acc)
        _ -> list.append(list.reverse(acc), [Stmt(ENil)])
      }
      Ok(#(EBlock(stmts), drop_token(tokens)))
    }
    EofKind -> fail(tokens, "block `{` not closed")
    Keyword("use") -> use_stmt(tokens, acc)
    Keyword("let") ->
      case peek(drop_token(tokens)) {
        NameKind("assert") -> let_assert_stmt(tokens, acc)
        _ -> statement_step(tokens, acc)
      }
    _ -> statement_step(tokens, acc)
  }
}

/// Parses one statement and continues the block.
fn statement_step(tokens, acc) {
  case tokens {
    _ -> {
      use #(stmt, rest) <- and_then(statement(tokens))
      let nxt = skip_newlines(rest)
      case peek(nxt) {
        Symbol("}") -> {
          let all = [stmt, ..acc]
          let stmts = case all {
            [Stmt(_), ..] -> list.reverse(all)
            _ -> list.append(list.reverse(all), [Stmt(ENil)])
          }
          Ok(#(EBlock(stmts), drop_token(nxt)))
        }
        EofKind -> fail(nxt, "block `{` not closed")
        _ -> statements(nxt, [stmt, ..acc])
      }
    }
  }
}

/// `let assert <pattern> = value` desugars to a `case` that aborts on a
/// mismatch, so the remainder of the block becomes the matching arm.
fn let_assert_stmt(tokens, acc) {
  let rest = skip_newlines(drop_token(drop_token(tokens)))
  use #(pattern, rest1) <- and_then(parse_pattern(rest))
  use rest2 <- and_then(expect_symbol(skip_newlines(rest1), "="))
  use #(value, rest3) <- and_then(parse_expr(skip_newlines(rest2)))
  use #(body, rest4) <- and_then(statements(skip_newlines(rest3), []))
  let case_expr =
    ECase(value, [
      Arm(pattern, None, body),
      Arm(PWildcard, None, EPanic("let assert", TNil)),
    ])
  Ok(#(EBlock(list.append(list.reverse(acc), [Stmt(case_expr)])), rest4))
}

/// `use <pattern>, ... <- f(args)` desugars to
/// `f(args, fn(tmp0, ...) { let <pattern> = tmp0; ... <rest> })`.
fn use_stmt(tokens, acc) {
  let #(patterns, rest1) = use_bindings(skip_newlines(drop_token(tokens)), [])
  use rest2 <- and_then(expect_symbol(rest1, "<-"))
  use #(call, rest3) <- and_then(parse_expr(skip_newlines(rest2)))
  use #(body, rest4) <- and_then(statements(skip_newlines(rest3), []))
  let #(names, prelude) =
    list.fold(
      list.index_map(patterns, fn(pat, index) { #(pat, index) }),
      #([], []),
      fn(acc2, pair) {
        let #(names, prelude) = acc2
        let #(pattern, index) = pair
        case pattern {
          PVar(name) -> #(list.append(names, [name]), prelude)
          _ -> {
            let temp = "__use_binding_" <> int.to_string(index)
            #(
              list.append(names, [temp]),
              list.append(prelude, [Let(pattern, EVar(temp))]),
            )
          }
        }
      },
    )
  let lambda = ELambda(names, with_prelude(body, prelude))
  let call2 = append_lambda(call, lambda)
  Ok(#(EBlock(list.append(list.reverse(acc), [Stmt(call2)])), rest4))
}

fn with_prelude(body, prelude) {
  case prelude {
    [] -> body
    _ -> {
      let statements = case body {
        EBlock(stmts) -> stmts
        _ -> [Stmt(body)]
      }
      EBlock(list.append(prelude, statements))
    }
  }
}

fn use_bindings(tokens, acc) {
  case peek(tokens) {
    Symbol("<-") -> #(list.reverse(acc), tokens)
    _ ->
      case parse_pattern(tokens) {
        Error(_) -> #(list.reverse(acc), tokens)
        Ok(#(pattern, rest)) ->
          case peek(rest) {
            Symbol(",") ->
              use_bindings(skip_newlines(drop_token(rest)), [pattern, ..acc])
            _ -> #(list.reverse([pattern, ..acc]), rest)
          }
      }
  }
}

fn append_lambda(call, lambda) {
  case call {
    ECall(fun, args) -> ECall(fun, list.append(args, [lambda]))
    _ -> ECall(call, [lambda])
  }
}

fn statement(tokens) {
  case peek(tokens) {
    Keyword("let") -> let_stmt(drop_token(tokens))
    _ -> {
      use #(e, rest) <- and_then(parse_expr(tokens))
      Ok(#(Stmt(e), rest))
    }
  }
}

fn let_stmt(tokens) {
  use #(pat, rest) <- and_then(parse_pattern(skip_newlines(tokens)))
  use rest1 <- and_then(expect_symbol(rest, "="))
  use #(value, rest2) <- and_then(parse_expr(skip_newlines(rest1)))
  Ok(#(Let(pat, value), rest2))
}

// ---------------------------------------------------------------------------
// expressions
// ---------------------------------------------------------------------------

fn parse_expr(tokens) {
  parse_pipe(tokens)
}

fn parse_pipe(tokens) {
  use #(left, rest) <- and_then(parse_binop(tokens, 0))
  pipe_loop(left, rest)
}

fn pipe_loop(left, tokens) {
  case leading_operator(tokens) {
    Ok(#("|>", op_tokens)) -> {
      let rest = drop_token(op_tokens)
      use #(right, rest2) <- and_then(parse_binop(rest, 0))
      case apply_pipe(left, right) {
        Ok(combined) -> pipe_loop(combined, rest2)
        Error(_) -> fail(tokens, "right-hand side of `|>` must be a call")
      }
    }
    _ -> Ok(#(left, tokens))
  }
}

fn apply_pipe(left, right) {
  case right {
    ECall(fun, args) -> Ok(ECall(fun, [left, ..args]))
    EVar(_) -> Ok(ECall(right, [left]))
    EField(_, _) -> Ok(ECall(right, [left]))
    _ -> Error(Nil)
  }
}

fn parse_binop(tokens, min_prec) {
  use #(left, rest) <- and_then(parse_unary(tokens))
  binop_loop(left, rest, min_prec)
}

fn binop_loop(left, tokens, min_prec) {
  case leading_operator(tokens) {
    Ok(#(op, op_tokens)) -> {
      let prec = precedence(op)
      case prec >= min_prec && prec >= 0 {
        True -> {
          let rest = drop_token(op_tokens)
          use #(right, rest2) <- and_then(parse_binop(rest, prec + 1))
          binop_loop(EBinop(op, left, right), rest2, min_prec)
        }
        False -> Ok(#(left, tokens))
      }
    }
    Error(_) -> Ok(#(left, tokens))
  }
}

/// An operator is allowed to start on the next line (continuation style), as
/// produced by `gleam format`.
fn leading_operator(tokens) {
  case peek(tokens) {
    Symbol(op) -> Ok(#(op, tokens))
    NewlineKind -> {
      let rest = skip_newlines(tokens)
      case peek(rest) {
        Symbol(op) -> Ok(#(op, rest))
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn precedence(op) {
  case op {
    "||" -> 0
    "&&" -> 1
    "==" | "!=" | "<" | "<=" | ">" | ">=" -> 2
    "<." | "<=." | ">." | ">=." -> 2
    "<>" -> 3
    "+" | "-" -> 4
    "+." | "-." -> 4
    "*" | "/" | "%" -> 5
    "*." | "/." -> 5
    _ -> -1
  }
}

fn parse_unary(tokens) {
  case peek(tokens) {
    Symbol("!") -> unary("!", drop_token(tokens))
    Symbol("-") -> unary("-", drop_token(tokens))
    Symbol("-.") -> unary("-.", drop_token(tokens))
    _ -> parse_postfix(tokens)
  }
}

fn unary(op, tokens) {
  use #(operand, rest) <- and_then(parse_unary(tokens))
  Ok(#(EUnop(op, operand), rest))
}

fn parse_postfix(tokens) {
  use #(atom, rest) <- and_then(parse_atom(tokens))
  postfix_loop(atom, rest)
}

fn postfix_loop(expr, tokens) {
  case peek(tokens) {
    Symbol("(") -> {
      use #(args, rest) <- and_then(call_args(drop_token(tokens), []))
      postfix_loop(ECall(expr, args), rest)
    }
    Symbol(".") -> {
      case peek(drop_token(tokens)) {
        NameKind(name) ->
          postfix_loop(EField(expr, name), drop_token(drop_token(tokens)))
        UpNameKind(name) ->
          postfix_loop(EField(expr, name), drop_token(drop_token(tokens)))
        _ -> fail(tokens, "expected a field name after `.`")
      }
    }
    _ -> Ok(#(expr, tokens))
  }
}

fn call_args(tokens, acc) {
  case peek(tokens) {
    Symbol(")") -> Ok(#(list.reverse(acc), drop_token(tokens)))
    _ -> {
      use #(e, rest) <- and_then(parse_call_arg(tokens))
      case peek(rest) {
        Symbol(",") -> call_args(drop_token(rest), [e, ..acc])
        Symbol(")") -> Ok(#(list.reverse([e, ..acc]), drop_token(rest)))
        _ -> fail(rest, "expected `,` or `)` in arguments")
      }
    }
  }
}

fn parse_call_arg(tokens) {
  case peek(tokens), peek(drop_token(tokens)) {
    NameKind(name), Symbol(":") -> {
      use #(value, rest) <- and_then(parse_expr(drop_token(drop_token(tokens))))
      Ok(#(ELabelled(name, value), rest))
    }
    _, _ -> parse_expr(tokens)
  }
}

fn parse_atom(tokens) {
  case tokens {
    [Token(IntKind(v), _, _), ..rest] -> Ok(#(EInt(v), rest))
    [Token(FloatKind(v), _, _), ..rest] -> Ok(#(EFloat(v), rest))
    [Token(StringKind(v), _, _), ..rest] -> Ok(#(EString(v), rest))
    [Token(UpNameKind("True"), _, _), ..rest] -> Ok(#(EBool(True), rest))
    [Token(UpNameKind("False"), _, _), ..rest] -> Ok(#(EBool(False), rest))
    [Token(UpNameKind("Nil"), _, _), ..rest] -> Ok(#(ENil, rest))
    [Token(UpNameKind(name), _, _), ..rest] ->
      case peek(rest) {
        Symbol("(") -> {
          let after = drop_token(rest)
          case peek(after) {
            Symbol("..") ->
              parse_record_update(name, skip_newlines(drop_token(after)))
            _ -> {
              use #(args, rest2) <- and_then(call_args(after, []))
              Ok(#(ECtor(name, args), rest2))
            }
          }
        }
        _ -> Ok(#(ECtor(name, []), rest))
      }
    [Token(NameKind("panic"), _, _), ..rest] -> parse_panic(rest, "panic")
    [Token(NameKind("todo"), _, _), ..rest] -> parse_panic(rest, "todo")
    [Token(NameKind(name), _, _), ..rest] -> Ok(#(EVar(name), rest))
    [Token(Keyword("case"), _, _), ..rest] -> parse_case(skip_newlines(rest))
    [Token(Keyword("fn"), _, _), ..rest] -> parse_lambda(rest)
    _ ->
      case at_symbol(tokens, "<<") {
        True -> parse_bit_array(drop_token(tokens))
        False ->
          case at_symbol(tokens, "#") {
            True -> parse_tuple(drop_token(tokens))
            False ->
              case at_symbol(tokens, "(") {
                True -> parse_grouped(drop_token(tokens))
                False ->
                  case at_symbol(tokens, "{") {
                    True -> parse_block(tokens)
                    False ->
                      case at_symbol(tokens, "[") {
                        True -> parse_list_literal(drop_token(tokens))
                        False -> fail(tokens, "expected an expression")
                      }
                  }
              }
          }
      }
  }
}

fn parse_record_update(name, tokens) {
  use #(base, rest) <- and_then(parse_expr(tokens))
  let rest1 = skip_newlines(rest)
  case peek(rest1) {
    Symbol(",") -> {
      use #(fields, rest2) <- and_then(
        update_fields(skip_newlines(drop_token(rest1)), []),
      )
      Ok(#(EUpdate(name, base, fields), rest2))
    }
    Symbol(")") -> Ok(#(EUpdate(name, base, []), drop_token(rest1)))
    _ -> fail(rest1, "expected `,` or `)` in record update")
  }
}

fn update_fields(tokens, acc) {
  case peek(tokens) {
    Symbol(")") -> Ok(#(list.reverse(acc), drop_token(tokens)))
    _ -> {
      use #(label, rest) <- and_then(expect_name(tokens))
      use rest1 <- and_then(expect_symbol(rest, ":"))
      use #(value, rest2) <- and_then(parse_expr(skip_newlines(rest1)))
      let acc2 = [#(label, value), ..acc]
      let nxt = skip_newlines(rest2)
      case peek(nxt) {
        Symbol(",") -> update_fields(skip_newlines(drop_token(nxt)), acc2)
        Symbol(")") -> Ok(#(list.reverse(acc2), drop_token(nxt)))
        _ -> fail(nxt, "expected `,` or `)` in record update")
      }
    }
  }
}

fn parse_bit_array(tokens) {
  bit_array_elems(tokens, [])
}

fn bit_array_elems(tokens, acc) {
  case peek(tokens) {
    Symbol(">>") -> Ok(#(EBitArray(list.reverse(acc)), drop_token(tokens)))
    _ -> {
      use #(element, rest) <- and_then(parse_expr(tokens))
      case peek(rest) {
        Symbol(",") -> bit_array_elems(drop_token(rest), [element, ..acc])
        Symbol(">>") ->
          Ok(#(EBitArray(list.reverse([element, ..acc])), drop_token(rest)))
        _ -> fail(rest, "expected `,` or `>>` in bit array")
      }
    }
  }
}

fn parse_bit_array_pattern(tokens) {
  bit_array_pat_elems(tokens, [])
}

fn bit_array_pat_elems(tokens, acc) {
  case peek(tokens) {
    Symbol(">>") -> Ok(#(PBitArray(list.reverse(acc)), drop_token(tokens)))
    _ -> {
      use #(element, rest) <- and_then(parse_pattern(tokens))
      case peek(rest) {
        Symbol(",") -> bit_array_pat_elems(drop_token(rest), [element, ..acc])
        Symbol(">>") ->
          Ok(#(PBitArray(list.reverse([element, ..acc])), drop_token(rest)))
        _ -> fail(rest, "expected `,` or `>>` in pattern")
      }
    }
  }
}

fn parse_panic(tokens, default_message) {
  case peek(tokens) {
    Keyword("as") -> {
      case peek(drop_token(tokens)) {
        StringKind(message) ->
          Ok(#(EPanic(message, TNil), drop_token(drop_token(tokens))))
        _ -> fail(tokens, "expected a string after `panic as`")
      }
    }
    _ -> Ok(#(EPanic(default_message, TNil), tokens))
  }
}

fn parse_lambda(tokens) {
  use rest <- and_then(expect_symbol(tokens, "("))
  use #(params, rest1) <- and_then(lambda_params(rest, []))
  use #(body, rest2) <- and_then(parse_block(skip_newlines(rest1)))
  Ok(#(ELambda(params, body), rest2))
}

fn lambda_params(tokens, acc) {
  case peek(tokens) {
    Symbol(")") -> Ok(#(list.reverse(acc), drop_token(tokens)))
    _ -> {
      use #(name, rest) <- and_then(expect_name(tokens))
      // optional `: Type` annotation is accepted and discarded (inferred)
      let #(_, rest1) = parse_optional_param_type(rest)
      let acc2 = [name, ..acc]
      case peek(rest1) {
        Symbol(",") -> lambda_params(drop_token(rest1), acc2)
        Symbol(")") -> Ok(#(list.reverse(acc2), drop_token(rest1)))
        _ -> fail(rest1, "expected `,` or `)` in lambda parameters")
      }
    }
  }
}

fn parse_optional_param_type(tokens) {
  case peek(tokens) {
    Symbol(":") -> {
      let assert Ok(#(_ty, rest)) = parse_type(drop_token(tokens))
      #(True, rest)
    }
    _ -> #(False, tokens)
  }
}

fn parse_grouped(tokens) {
  use #(e, rest) <- and_then(parse_expr(tokens))
  use rest2 <- and_then(expect_symbol(rest, ")"))
  Ok(#(e, rest2))
}

fn parse_tuple(tokens) {
  use rest <- and_then(expect_symbol(tokens, "("))
  tuple_elems(rest, [])
}

fn tuple_elems(tokens, acc) {
  case peek(tokens) {
    Symbol(")") -> Ok(#(ETuple(list.reverse(acc)), drop_token(tokens)))
    _ -> {
      use #(e, rest) <- and_then(parse_expr(tokens))
      case peek(rest) {
        Symbol(",") -> tuple_elems(drop_token(rest), [e, ..acc])
        Symbol(")") -> Ok(#(ETuple(list.reverse([e, ..acc])), drop_token(rest)))
        _ -> fail(rest, "expected `,` or `)` in tuple")
      }
    }
  }
}

fn parse_case(tokens) {
  use #(subjects, rest) <- and_then(case_subjects(skip_newlines(tokens), []))
  use rest1 <- and_then(expect_symbol(skip_newlines(rest), "{"))
  arms(desugar_subjects(subjects), skip_newlines(rest1), [])
}

/// Collects the comma-separated subjects of a `case`. Multiple subjects are
/// desugared to a tuple, so the rest of the pipeline stays unchanged.
fn case_subjects(tokens, acc) {
  use #(subject, rest) <- and_then(parse_expr(tokens))
  case peek(rest) {
    Symbol(",") -> case_subjects(drop_token(rest), [subject, ..acc])
    _ -> Ok(#(list.reverse([subject, ..acc]), rest))
  }
}

fn desugar_subjects(subjects) {
  case subjects {
    [single] -> single
    _ -> ETuple(subjects)
  }
}

fn arms(subject, tokens, acc) {
  case peek(tokens) {
    Symbol("}") ->
      case acc {
        [] -> fail(tokens, "`case` with no arms")
        _ -> Ok(#(ECase(subject, acc), drop_token(tokens)))
      }
    EofKind -> fail(tokens, "`case` not closed")
    _ -> {
      use #(parsed, rest) <- and_then(parse_arm(tokens))
      arms(subject, skip_newlines(rest), list.append(acc, parsed))
    }
  }
}

fn parse_arm(tokens) {
  use #(alternatives, rest) <- and_then(arm_patterns(tokens, []))
  let #(guard, rest1) = parse_guard(skip_newlines(rest))
  // A multi-line guard ends on its own line, before the arm's `->`.
  use rest2 <- and_then(expect_symbol(skip_newlines(rest1), "->"))
  use #(body, rest3) <- and_then(parse_expr(skip_newlines(rest2)))
  Ok(#(
    list.map(arm_combinations(alternatives), fn(pat) { Arm(pat, guard, body) }),
    rest3,
  ))
}

/// Collects the comma-separated pattern alternatives of an arm (multiple
/// subjects, each with `|` alternatives).
fn arm_patterns(tokens, acc) {
  use #(alternatives, rest) <- and_then(arm_alternatives(tokens, []))
  case peek(rest) {
    Symbol(",") ->
      arm_patterns(skip_newlines(drop_token(rest)), [alternatives, ..acc])
    _ -> Ok(#(list.reverse([alternatives, ..acc]), rest))
  }
}

fn arm_alternatives(tokens, acc) {
  use #(pattern, rest) <- and_then(parse_pattern(tokens))
  let rest = skip_newlines(rest)
  case peek(rest) {
    Symbol("|") ->
      arm_alternatives(skip_newlines(drop_token(rest)), [pattern, ..acc])
    _ -> Ok(#(list.reverse([pattern, ..acc]), rest))
  }
}

/// Cartesian product of the per-subject alternatives, as case arm patterns.
fn arm_combinations(alternatives) {
  list.fold(alternatives, [[]], fn(combos, alts) {
    list.flat_map(combos, fn(combo) {
      list.map(alts, fn(pattern) { list.append(combo, [pattern]) })
    })
  })
  |> list.map(fn(combo) {
    case combo {
      [single] -> single
      _ -> PTuple(combo)
    }
  })
}

fn parse_guard(tokens: List(Token)) -> #(Option(Expr), List(Token)) {
  case peek(tokens) {
    Keyword("if") | Keyword("when") -> {
      let assert Ok(#(expr, rest)) =
        parse_expr(skip_newlines(drop_token(tokens)))
      #(Some(expr), rest)
    }
    _ -> #(None, tokens)
  }
}

// ---------------------------------------------------------------------------
// patterns
// ---------------------------------------------------------------------------

fn parse_pattern(tokens) {
  use #(pattern, rest) <- and_then(parse_pattern_base(tokens))
  case peek(rest) {
    Keyword("as") -> {
      use #(name, rest2) <- and_then(expect_name(drop_token(rest)))
      Ok(#(PAs(pattern, name), rest2))
    }
    _ -> Ok(#(pattern, rest))
  }
}

fn parse_pattern_base(tokens) {
  case tokens {
    [
      Token(NameKind(module), _, _),
      Token(Symbol("."), _, _),
      Token(UpNameKind(name), _, _),
      ..rest
    ] -> {
      // Keep the module qualifier; it is resolved during merging.
      let qualified = module <> "." <> name
      case peek(rest) {
        Symbol("(") -> {
          use #(args, rest2) <- and_then(pattern_args(drop_token(rest), []))
          Ok(#(PCtor(qualified, args), rest2))
        }
        _ -> Ok(#(PCtor(qualified, []), rest))
      }
    }
    [Token(IntKind(v), _, _), ..rest] -> Ok(#(PInt(v), rest))
    [Token(FloatKind(v), _, _), ..rest] -> Ok(#(PFloat(v), rest))
    [Token(StringKind(v), _, _), ..rest] -> Ok(#(PString(v), rest))
    [Token(UpNameKind("True"), _, _), ..rest] -> Ok(#(PBool(True), rest))
    [Token(UpNameKind("False"), _, _), ..rest] -> Ok(#(PBool(False), rest))
    [Token(UpNameKind("Nil"), _, _), ..rest] -> Ok(#(PNil, rest))
    [Token(NameKind("_"), _, _), ..rest] -> Ok(#(PWildcard, rest))
    [Token(NameKind(name), _, _), ..rest] -> Ok(#(PVar(name), rest))
    [Token(UpNameKind(name), _, _), ..rest] -> {
      case peek(rest) {
        Symbol("(") -> {
          use #(args, rest2) <- and_then(pattern_args(drop_token(rest), []))
          Ok(#(PCtor(name, args), rest2))
        }
        _ -> Ok(#(PCtor(name, []), rest))
      }
    }
    _ ->
      case at_symbol(tokens, "<<") {
        True -> parse_bit_array_pattern(drop_token(tokens))
        False ->
          case at_symbol(tokens, "#") {
            True -> parse_tuple_pattern(drop_token(tokens))
            False ->
              case at_symbol(tokens, "[") {
                True -> parse_list_pattern(drop_token(tokens))
                False -> fail(tokens, "expected a pattern")
              }
          }
      }
  }
}

fn build_list_expr(items, tail) {
  list.fold(list.reverse(items), tail, fn(acc, item) {
    ECtor("ListCons", [item, acc])
  })
}

fn parse_list_literal(tokens) {
  case peek(tokens) {
    Symbol("]") -> Ok(#(ECtor("ListEmpty", []), drop_token(tokens)))
    _ -> list_lit_elems(tokens, [])
  }
}

/// A trailing comma is allowed after a list spread (`[a, ..rest, ]`).
fn skip_optional_comma(tokens) {
  case peek(tokens) {
    Symbol(",") -> drop_token(tokens)
    _ -> tokens
  }
}

fn list_lit_elems(tokens, acc) {
  case peek(tokens) {
    Symbol("]") ->
      Ok(#(
        build_list_expr(list.reverse(acc), ECtor("ListEmpty", [])),
        drop_token(tokens),
      ))
    Symbol("..") -> {
      use #(tail, rest2) <- and_then(parse_expr(drop_token(tokens)))
      let rest2 = skip_optional_comma(rest2)
      use rest3 <- and_then(expect_symbol(rest2, "]"))
      Ok(#(build_list_expr(list.reverse(acc), tail), rest3))
    }
    _ -> {
      use #(e, rest) <- and_then(parse_expr(tokens))
      case peek(rest) {
        Symbol(",") -> list_lit_elems(drop_token(rest), [e, ..acc])
        Symbol("]") ->
          Ok(#(
            build_list_expr(list.reverse([e, ..acc]), ECtor("ListEmpty", [])),
            drop_token(rest),
          ))
        _ -> fail(rest, "expected `,` or `]` in list")
      }
    }
  }
}

fn build_list_pat(items, tail) {
  list.fold(list.reverse(items), tail, fn(acc, item) {
    PCtor("ListCons", [item, acc])
  })
}

fn parse_list_pattern(tokens) {
  case peek(tokens) {
    Symbol("]") -> Ok(#(PCtor("ListEmpty", []), drop_token(tokens)))
    _ -> list_pat_elems(tokens, [])
  }
}

fn list_pat_elems(tokens, acc) {
  case peek(tokens) {
    Symbol("]") ->
      Ok(#(
        build_list_pat(list.reverse(acc), PCtor("ListEmpty", [])),
        drop_token(tokens),
      ))
    Symbol("..") -> {
      let after = drop_token(tokens)
      case peek(after) {
        Symbol("]") ->
          Ok(#(build_list_pat(list.reverse(acc), PWildcard), drop_token(after)))
        _ -> {
          use #(tail, rest2) <- and_then(parse_pattern(after))
          let rest2 = skip_optional_comma(rest2)
          use rest3 <- and_then(expect_symbol(rest2, "]"))
          Ok(#(build_list_pat(list.reverse(acc), tail), rest3))
        }
      }
    }
    _ -> {
      use #(p, rest) <- and_then(parse_pattern(tokens))
      case peek(rest) {
        Symbol(",") -> list_pat_elems(drop_token(rest), [p, ..acc])
        Symbol("]") ->
          Ok(#(
            build_list_pat(list.reverse([p, ..acc]), PCtor("ListEmpty", [])),
            drop_token(rest),
          ))
        _ -> fail(rest, "expected `,` or `]` in pattern")
      }
    }
  }
}

fn pattern_args(tokens, acc) {
  case peek(tokens) {
    Symbol(")") -> Ok(#(list.reverse(acc), drop_token(tokens)))
    _ -> {
      use #(p, rest) <- and_then(parse_pattern_arg(tokens))
      case peek(rest) {
        Symbol(",") -> pattern_args(drop_token(rest), [p, ..acc])
        Symbol(")") -> Ok(#(list.reverse([p, ..acc]), drop_token(rest)))
        _ -> fail(rest, "expected `,` or `)` in pattern")
      }
    }
  }
}

fn parse_pattern_arg(tokens) {
  case peek(tokens), peek(drop_token(tokens)) {
    NameKind(name), Symbol(":") -> {
      let rest = drop_token(drop_token(tokens))
      case peek(rest), peek(drop_token(rest)) {
        Symbol(","), _ -> Ok(#(PLabelled(name, PVar(name)), rest))
        Symbol(")"), _ -> Ok(#(PLabelled(name, PVar(name)), rest))
        _, _ -> {
          use #(inner, rest2) <- and_then(parse_pattern(rest))
          Ok(#(PLabelled(name, inner), rest2))
        }
      }
    }
    _, _ -> parse_pattern(tokens)
  }
}

fn parse_tuple_pattern(tokens) {
  use rest <- and_then(expect_symbol(tokens, "("))
  tuple_pat_elems(rest, [])
}

fn tuple_pat_elems(tokens, acc) {
  case peek(tokens) {
    Symbol(")") -> Ok(#(PTuple(list.reverse(acc)), drop_token(tokens)))
    _ -> {
      use #(p, rest) <- and_then(parse_pattern(tokens))
      case peek(rest) {
        Symbol(",") -> tuple_pat_elems(drop_token(rest), [p, ..acc])
        Symbol(")") -> Ok(#(PTuple(list.reverse([p, ..acc])), drop_token(rest)))
        _ -> fail(rest, "expected `,` or `)` in tuple")
      }
    }
  }
}
