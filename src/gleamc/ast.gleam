//// AST for the M1 Gleam subset.

import gleam/option.{type Option}

pub type Type {
  TInt
  TFloat
  TBool
  TString
  TNil
  /// type variable: `a`, `b`, ...
  TVar(String)
  /// nullary named type
  TNamed(String)
  /// generic application: `Option(Int)`, `Result(Int, e)`
  TApp(name: String, args: List(Type))
  TTuple(List(Type))
  /// function type: `fn(Int) -> String`
  TFun(params: List(Type), ret: Type)
}

pub type Pattern {
  PInt(Int)
  PFloat(Float)
  PString(String)
  PBool(Bool)
  PNil
  PVar(String)
  PWildcard
  PCtor(name: String, args: List(Pattern))
  PTuple(List(Pattern))
  /// `field: pat` — a labelled constructor pattern argument.
  PLabelled(name: String, pattern: Pattern)
  /// `<<a, b>>` — matches 8-bit segments of a bit array.
  PBitArray(List(Pattern))
}

pub type Expr {
  EInt(Int)
  EFloat(Float)
  EString(String)
  EBool(Bool)
  ENil
  EVar(String)
  EField(obj: Expr, name: String)
  ECtor(name: String, args: List(Expr))
  ECall(fun: Expr, args: List(Expr))
  EBinop(op: String, left: Expr, right: Expr)
  EUnop(op: String, operand: Expr)
  EBlock(List(Statement))
  ECase(subject: Expr, arms: List(Arm))
  ETuple(List(Expr))
  /// `name: value` — a labelled call/constructor argument.
  ELabelled(name: String, value: Expr)
  /// anonymous function: `fn(a, b) { ... }`
  ELambda(params: List(String), body: Expr)
  /// closure construction (produced by monomorphisation)
  EClosure(code: String, captures: List(Expr), env_ty: String, fn_ty: Type)
  /// reads a captured value from the environment (produced by monomorphisation)
  EEnvGet(env_ty: String, index: Int, ty: Type)
  /// `panic` / `todo` — aborts at runtime. `ty` is filled during
  /// monomorphisation so the backend can type the surrounding expression.
  EPanic(message: String, ty: Type)
  /// `Ctor(..base, field: value)` — record update (desugared during
  /// monomorphisation into a full constructor call).
  EUpdate(name: String, base: Expr, fields: List(#(String, Expr)))
  /// `<<1, 2, 3>>` — bit array of 8-bit segments.
  EBitArray(List(Expr))
}

pub type Statement {
  Let(pattern: Pattern, value: Expr)
  Stmt(Expr)
}

pub type Arm {
  Arm(pattern: Pattern, guard: Option(Expr), body: Expr)
}

pub type Function {
  Function(
    is_pub: Bool,
    name: String,
    params: List(#(String, Type)),
    ret: Type,
    body: Expr,
  )
}

pub type Variant {
  Variant(name: String, fields: List(#(String, Type)))
}

pub type CustomType {
  CustomType(
    is_pub: Bool,
    name: String,
    generics: List(String),
    variants: List(Variant),
  )
}

pub type Import {
  Import(path: List(String), items: List(String))
}

pub type Definition {
  DFunction(Function)
  DCustomType(CustomType)
  DTypeAlias(is_pub: Bool, name: String, generics: List(String), ty: Type)
  DImport(Import)
}

pub type Module {
  Module(definitions: List(Definition))
}
