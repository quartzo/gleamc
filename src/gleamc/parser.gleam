//// Parser for the M1 Gleam subset: recursive descent over the token list.
//// Deferred sugar (type aliases, closures, generics, `use`) comes in later
//// milestones.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleamc/ast.{
  type Module, Arm, CustomType, DCustomType, DFunction, DImport, EBinop, EBlock,
  EBool, ECall, ECase, ECtor, EField, EFloat, EInt, ELabelled, ELambda, ENil,
  EString, ETuple, EUnop, EVar, Function, Import, Let, Module, PBool, PCtor,
  PFloat, PInt, PLabelled, PNil, PString, PTuple, PVar, PWildcard, Stmt, TApp,
  TBool, TFloat, TFun, TInt, TNamed, TNil, TString, TTuple, TVar, Variant,
}
import gleamc/lexer
import gleamc/token.{
  EofKind, FloatKind, IntKind, Keyword, NameKind, NewlineKind, StringKind,
  Symbol, Token, UpNameKind,
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
        Keyword("type") -> definition_type(rest, True, acc)
        _ -> fail(rest, "expected `fn` or `type` after `pub`")
      }
    }
    Keyword("fn") -> definition_fn(tokens, False, acc)
    Keyword("type") -> definition_type(tokens, False, acc)
    _ ->
      fail(tokens, "expected a declaration (`import`, `pub fn`, `fn`, `type`)")
  }
}

fn definition_fn(tokens, is_pub, acc) {
  use rest <- and_then(expect_keyword(tokens, "fn"))
  use #(fn_def, rest1) <- and_then(function_rest(skip_newlines(rest), is_pub))
  definitions(skip_newlines(rest1), [DFunction(fn_def), ..acc])
}

fn function_rest(tokens, is_pub) {
  use #(name, rest) <- and_then(expect_name(tokens))
  use rest1 <- and_then(expect_symbol(rest, "("))
  use #(ps, rest2) <- and_then(params(rest1, []))
  let #(ret, rest3) = parse_optional_return(skip_newlines(rest2))
  use #(body, rest5) <- and_then(parse_block(skip_newlines(rest3)))
  Ok(#(Function(is_pub, name, ps, ret, body), rest5))
}

fn parse_optional_return(tokens) {
  case peek(tokens) {
    Symbol("->") -> {
      let assert Ok(#(ty, rest)) = parse_type(skip_newlines(drop_token(tokens)))
      #(ty, rest)
    }
    _ -> #(TNil, tokens)
  }
}

fn params(tokens, acc) {
  case peek(tokens) {
    Symbol(")") -> Ok(#(list.reverse(acc), drop_token(tokens)))
    _ -> {
      use #(name, rest) <- and_then(expect_name(tokens))
      use rest1 <- and_then(expect_symbol(rest, ":"))
      use #(ty, rest2) <- and_then(parse_type(rest1))
      let acc2 = [#(name, ty), ..acc]
      case peek(rest2) {
        Symbol(",") -> params(drop_token(rest2), acc2)
        Symbol(")") -> Ok(#(list.reverse(acc2), drop_token(rest2)))
        _ -> fail(rest2, "expected `,` or `)` in parameter list")
      }
    }
  }
}

fn definition_type(tokens, is_pub, acc) {
  use rest <- and_then(expect_keyword(tokens, "type"))
  use #(name, rest1) <- and_then(expect_upname(skip_newlines(rest)))
  let #(generics, rest1) = parse_generics(skip_newlines(rest1))
  let rest2 = skip_newlines(rest1)
  case peek(rest2) {
    Symbol("=") -> fail(rest2, "type aliases not supported yet")
    _ -> {
      use rest3 <- and_then(expect_symbol(rest2, "{"))
      use #(variants, rest4) <- and_then(variants(skip_newlines(rest3), []))
      definitions(skip_newlines(rest4), [
        DCustomType(CustomType(is_pub, name, generics, variants)),
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
      use #(fields, rest2) <- and_then(variant_fields(drop_token(rest), []))
      Ok(#(Variant(name, fields), rest2))
    }
    _ -> Ok(#(Variant(name, []), rest))
  }
}

fn variant_fields(tokens, acc) {
  case peek(tokens) {
    Symbol(")") -> Ok(#(list.reverse(acc), drop_token(tokens)))
    _ -> {
      use #(field_name, rest) <- and_then(expect_name(tokens))
      use rest1 <- and_then(expect_symbol(rest, ":"))
      use #(ty, rest2) <- and_then(parse_type(rest1))
      let acc2 = [#(field_name, ty), ..acc]
      case peek(rest2) {
        Symbol(",") -> variant_fields(drop_token(rest2), acc2)
        Symbol(")") -> Ok(#(list.reverse(acc2), drop_token(rest2)))
        _ -> fail(rest2, "expected `,` or `)` in variant fields")
      }
    }
  }
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
  use #(pat, rest) <- and_then(parse_pattern(tokens))
  use rest1 <- and_then(expect_symbol(rest, "="))
  use #(value, rest2) <- and_then(parse_expr(rest1))
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
  case peek(tokens) {
    Symbol("|>") -> {
      let rest = drop_token(tokens)
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
  case peek(tokens) {
    Symbol(op) -> {
      let prec = precedence(op)
      case prec >= min_prec && prec >= 0 {
        True -> {
          let rest = drop_token(tokens)
          use #(right, rest2) <- and_then(parse_binop(rest, prec + 1))
          binop_loop(EBinop(op, left, right), rest2, min_prec)
        }
        False -> Ok(#(left, tokens))
      }
    }
    _ -> Ok(#(left, tokens))
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
    [Token(UpNameKind(name), _, _), ..rest] -> {
      case peek(rest) {
        Symbol("(") -> {
          use #(args, rest2) <- and_then(call_args(drop_token(rest), []))
          Ok(#(ECtor(name, args), rest2))
        }
        _ -> Ok(#(ECtor(name, []), rest))
      }
    }
    [Token(NameKind(name), _, _), ..rest] -> Ok(#(EVar(name), rest))
    [Token(Keyword("case"), _, _), ..rest] -> parse_case(skip_newlines(rest))
    [Token(Keyword("fn"), _, _), ..rest] -> parse_lambda(rest)
    _ ->
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
  use #(e, rest) <- and_then(parse_expr(tokens))
  case peek(rest) {
    Symbol(",") -> tuple_elems(drop_token(rest), [e, ..acc])
    Symbol(")") -> Ok(#(ETuple(list.reverse([e, ..acc])), drop_token(rest)))
    _ -> fail(rest, "expected `,` or `)` in tuple")
  }
}

fn parse_case(tokens) {
  use #(subject, rest) <- and_then(parse_expr(tokens))
  use rest1 <- and_then(expect_symbol(rest, "{"))
  arms(subject, skip_newlines(rest1), [])
}

fn arms(subject, tokens, acc) {
  case peek(tokens) {
    Symbol("}") -> {
      let arm_list = list.reverse(acc)
      case arm_list {
        [] -> fail(tokens, "`case` with no arms")
        _ -> Ok(#(ECase(subject, arm_list), drop_token(tokens)))
      }
    }
    EofKind -> fail(tokens, "`case` not closed")
    _ -> {
      use #(parsed, rest) <- and_then(parse_arm(tokens))
      let nxt = skip_newlines(rest)
      case peek(nxt) {
        Symbol("}") ->
          Ok(#(ECase(subject, list.reverse([parsed, ..acc])), drop_token(nxt)))
        EofKind -> fail(nxt, "`case` not closed")
        _ -> arms(subject, nxt, [parsed, ..acc])
      }
    }
  }
}

fn parse_arm(tokens) {
  use #(pat, rest) <- and_then(parse_pattern(tokens))
  let #(guard, rest1) = parse_guard(skip_newlines(rest))
  use rest2 <- and_then(expect_symbol(rest1, "->"))
  use #(body, rest3) <- and_then(parse_expr(skip_newlines(rest2)))
  Ok(#(Arm(pat, guard, body), rest3))
}

fn parse_guard(tokens) {
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
  case tokens {
    [
      Token(NameKind(_), _, _),
      Token(Symbol("."), _, _),
      Token(UpNameKind(name), _, _),
      ..rest
    ] -> {
      case peek(rest) {
        Symbol("(") -> {
          use #(args, rest2) <- and_then(pattern_args(drop_token(rest), []))
          Ok(#(PCtor(name, args), rest2))
        }
        _ -> Ok(#(PCtor(name, []), rest))
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

fn list_lit_elems(tokens, acc) {
  use #(e, rest) <- and_then(parse_expr(tokens))
  case peek(rest) {
    Symbol(",") -> list_lit_elems(drop_token(rest), [e, ..acc])
    Symbol("..") -> {
      use #(tail, rest2) <- and_then(parse_expr(drop_token(rest)))
      use rest3 <- and_then(expect_symbol(rest2, "]"))
      Ok(#(build_list_expr(list.reverse([e, ..acc]), tail), rest3))
    }
    Symbol("]") ->
      Ok(#(
        build_list_expr(list.reverse([e, ..acc]), ECtor("ListEmpty", [])),
        drop_token(rest),
      ))
    _ -> fail(rest, "expected `,`, `..` or `]` in list")
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
  use #(p, rest) <- and_then(parse_pattern(tokens))
  case peek(rest) {
    Symbol(",") -> list_pat_elems(drop_token(rest), [p, ..acc])
    Symbol("..") -> {
      use #(tail, rest2) <- and_then(parse_pattern(drop_token(rest)))
      use rest3 <- and_then(expect_symbol(rest2, "]"))
      Ok(#(build_list_pat(list.reverse([p, ..acc]), tail), rest3))
    }
    Symbol("]") ->
      Ok(#(
        build_list_pat(list.reverse([p, ..acc]), PCtor("ListEmpty", [])),
        drop_token(rest),
      ))
    _ -> fail(rest, "expected `,`, `..` or `]` in pattern")
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
  use #(p, rest) <- and_then(parse_pattern(tokens))
  case peek(rest) {
    Symbol(",") -> tuple_pat_elems(drop_token(rest), [p, ..acc])
    Symbol(")") -> Ok(#(PTuple(list.reverse([p, ..acc])), drop_token(rest)))
    _ -> fail(rest, "expected `,` or `)` in tuple")
  }
}
