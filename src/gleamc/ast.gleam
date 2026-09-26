//// AST for the M1 Gleam subset.

import gleam/option.{type Option}
import gleam/string

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

/// After monomorphisation an applied type is a mangled `TNamed`, e.g.
/// `Buffer(Int)` becomes `TNamed("Buffer_Int")`. Returns the mangled element
/// name (`"Int"`) when `type_name` names a `Buffer`.
pub fn buffer_elem_name(type_name: String) -> Result(String, Nil) {
  case string.starts_with(type_name, "Buffer_") {
    True -> Ok(string.drop_start(type_name, 7))
    False -> Error(Nil)
  }
}

/// Like `buffer_elem_name`, for the phantom `Subject(a)` handle type.
pub fn subject_elem_name(type_name: String) -> Result(String, Nil) {
  case string.starts_with(type_name, "Subject_") {
    True -> Ok(string.drop_start(type_name, 8))
    False -> Error(Nil)
  }
}

/// Like `buffer_elem_name`, for the phantom `Task(a)` handle type.
pub fn task_elem_name(type_name: String) -> Result(String, Nil) {
  case string.starts_with(type_name, "Task_") {
    True -> Ok(string.drop_start(type_name, 5))
    False -> Error(Nil)
  }
}

/// Rebuilds a type from its monomorphised mangled name: scalars map back to
/// their primitive; anything else is a (specialised) named type.
pub fn type_of_mangled(name: String) -> Type {
  case name {
    "Int" -> TInt
    "Float" -> TFloat
    "Bool" -> TBool
    "String" -> TString
    "Nil" -> TNil
    other -> TNamed(other)
  }
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
  /// `pat as name` — binds `name` to the value matched by `pat`.
  PAs(pattern: Pattern, name: String)
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
    line: Int,
  )
}

/// An `@external(target, "symbol")` declaration: a function whose body is
/// provided by the runtime for `target`. `gleamc` implements `native`; other
/// targets are accepted syntactically and rejected if selected.
pub type External {
  External(
    is_pub: Bool,
    name: String,
    params: List(#(String, Type)),
    ret: Type,
    target: String,
    symbol: String,
    line: Int,
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
    is_opaque: Bool,
  )
}

pub type Import {
  Import(path: List(String), items: List(String))
}

pub type Definition {
  DFunction(Function)
  DExternal(External)
  DConst(name: String, value: Expr)
  DCustomType(CustomType)
  DTypeAlias(is_pub: Bool, name: String, generics: List(String), ty: Type)
  DImport(Import)
}

pub type Module {
  Module(definitions: List(Definition))
}
