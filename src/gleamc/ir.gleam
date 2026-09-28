//// Core IR (M3): functions -> basic blocks -> ops + terminators.
////
//// Mirrors the shape of Vesper's `ir.py` so the ownership pass (a direct
//// port) can run over it: operands are local names or literals, every op
//// may define a destination local, and blocks end in a terminator.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/string
import gleamc/ast.{type Type}
import gleamc/ffi_modes

pub type Literal {
  LInt(Int)
  LFloat(Float)
  LBool(Bool)
  LUnit
  LString(String)
}

pub type Operand {
  Var(String)
  Lit(Literal)
}

pub type Op {
  OpConst(dest: String, value: Literal)
  OpBinop(dest: String, op: String, left: Operand, right: Operand)
  OpUnop(dest: String, op: String, operand: Operand)
  OpCall(dest: String, fun: String, args: List(Operand), ret_ty: Type)
  OpBuiltin(dest: String, name: String, args: List(Operand), ret_ty: Type)
  OpTuple(dest: String, elems: List(Operand), ty: Type)
  OpBitArray(dest: String, elems: List(Operand), ty: Type)
  OpTupleGet(dest: String, tuple: Operand, index: Int, ty: Type)
  OpCtor(
    dest: String,
    ctor: String,
    type_name: String,
    args: List(Operand),
    ty: Type,
  )
  OpTagIs(dest: String, subject: Operand, ctor: String, type_name: String)
  OpField(dest: String, subject: Operand, ctor: String, index: Int, ty: Type)
  /// dest = src with ownership semantics (used for case results).
  OpCopy(dest: String, src: Operand, ty: Type)
  /// SSA join: `dest` takes the value of the operand of the predecessor block
  /// control came from. Inserted by the `ssa` pass in place of the `OpCopy`
  /// result temporaries; the backend renders it as an LLVM `phi`.
  OpPhi(dest: String, incoming: List(#(Operand, String)))
  /// Function value (closure): code pointer + optional heap environment.
  OpClosure(
    dest: String,
    code: String,
    captures: List(Operand),
    env_ty: String,
    fn_ty: Type,
  )
  /// Reads a captured value from the current function's environment.
  OpEnvGet(dest: String, env_ty: String, index: Int, ty: Type)
  /// Call through a function value.
  OpCallIndirect(dest: String, fval: Operand, args: List(Operand), ret_ty: Type)
  /// Reads the environment pointer of a closure value (`void*`, a borrow).
  /// Used when a known closure code is called directly and needs its env.
  OpClosureEnv(dest: String, closure: Operand, ty: Type)
  /// +1 on the local before an owning use that is not the last one.
  OpRetain(src: String, ty: Type)
  /// -1 on the local at its death.
  OpDrop(src: String, ty: Type)
  /// Starts the machine of the async function `fun` with `args` as a task on the
  /// cooperative driver, binding the future that completes when it finishes to
  /// `fut`. The machine writes its result into `result_dest`. Emitted by the
  /// async pass; the following suspension waits for it.
  OpMachineStart(
    fut: String,
    fun: String,
    args: List(Operand),
    result_dest: String,
  )
  /// Starts the machine of `fun` as a task **without suspending** the caller.
  /// `into_future` stores a scalar result in the completion future itself (the
  /// `task.async` / `task_ffi.await` pair); otherwise the task is fire-and-forget
  /// (`process.spawn`). `fut` binds the task handle. Emitted by the spawn pass.
  OpTaskStart(fut: String, fun: String, args: List(Operand), into_future: Bool)
  /// Starts the machine of a **closure value** (`process.spawn` /
  /// `task.async` take `fn() -> ...`). `code` is the closure code
  /// (`Gleamc___lambda_N`); the backend resolves the machine frame and adopts
  /// the closure's environment as the callee frame's `__env`.
  OpTaskStartClosure(
    fut: String,
    fun: String,
    closure: Operand,
    into_future: Bool,
  )
  /// Defines the function's frame: a composite, reference-counted heap cell
  /// holding the variables that must survive a jump (captured by a closure or
  /// live across a suspension). Fields are read/written with `OpFrameGet` and
  /// `OpFrameSet`.
  OpFrameNew(dest: String, frame_ty: String)
  /// Reads field `index` of a frame value into `dest`.
  OpFrameGet(dest: String, frame: Operand, index: Int, ty: Type)
  /// Writes `value` into field `index` of a frame value.
  OpFrameSet(frame: Operand, index: Int, value: Operand)
}

/// How a suspended machine resumes: `Host` reads the awaited value out of a
/// host future, `Machine` releases a started machine's completion future (the
/// result was copied into `dest` outright), `Boxed` moves a boxed value out of
/// the future (`process_ffi.receive` / `task_ffi.await`).
pub type ResumeMode {
  Host
  Machine
  Boxed
  BoxedBorrow
}

pub type Terminator {
  Jmp(label: String)
  Branch(cond: Operand, then: String, otherwise: String)
  Ret(value: Operand)
  /// Tail call: control leaves the function directly into `fun` (no return).
  Tailcall(fun: String, args: List(Operand))
  /// Tail call through a function value: the callee is `fval` (an operand).
  TailcallIndirect(fval: Operand, args: List(Operand))
  /// Tail call to the async function `fun`: the running machine delegates its
  /// task (step, frame, result copy) to `fun` and returns to the driver, so a
  /// chain of async tail calls keeps a constant number of tasks.
  TailMachine(fun: String, args: List(Operand))
  /// Async suspension point: control yields the pending `fut` to the driver and
  /// resumes at block `resume` once it completes, binding the future's value to
  /// the local `dest`. `machine` distinguishes awaiting a started machine (the
  /// result is already in `dest`, so the backend only releases the future) from
  /// awaiting a host future (the value is read from it).
  Suspend(fut: Operand, dest: String, resume: String, mode: ResumeMode)
  Unreachable
}

pub type Block {
  Block(label: String, ops: List(Op), term: Terminator)
}

/// Where a local lives after the SSA pass: a memory `Slot` (an alloca / frame
/// field, address-takeable) or a `Reg` (a pure SSA value the pass promoted; the
/// backend keeps it in a register and never emits an alloca for it). See
/// `ssa.gleam`.
pub type Storage {
  Slot
  Reg
}

pub type Local {
  Local(name: String, ty: Type, storage: Storage)
}

pub type Function {
  Function(
    name: String,
    params: List(String),
    ret: Type,
    blocks: List(Block),
    locals: List(Local),
  )
}

pub type Module {
  Module(functions: List(Function))
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

/// The local defined by an op, if any.
pub fn op_dest(op: Op) -> Result(String, Nil) {
  case op {
    OpConst(dest, _) -> Ok(dest)
    OpBinop(dest, _, _, _) -> Ok(dest)
    OpUnop(dest, _, _) -> Ok(dest)
    OpCall(dest, _, _, _) -> Ok(dest)
    OpBuiltin(dest, _, _, _) -> Ok(dest)
    OpTuple(dest, _, _) -> Ok(dest)
    OpBitArray(dest, _, _) -> Ok(dest)
    OpTupleGet(dest, _, _, _) -> Ok(dest)
    OpCtor(dest, _, _, _, _) -> Ok(dest)
    OpTagIs(dest, _, _, _) -> Ok(dest)
    OpField(dest, _, _, _, _) -> Ok(dest)
    OpCopy(dest, _, _) -> Ok(dest)
    OpPhi(dest, _) -> Ok(dest)
    OpClosure(dest, _, _, _, _) -> Ok(dest)
    OpEnvGet(dest, _, _, _) -> Ok(dest)
    OpCallIndirect(dest, _, _, _) -> Ok(dest)
    OpClosureEnv(dest, _, _) -> Ok(dest)
    OpRetain(_, _) -> Error(Nil)
    OpDrop(_, _) -> Error(Nil)
    OpMachineStart(fut, _, _, _) -> Ok(fut)
    OpTaskStart(fut, _, _, _) -> Ok(fut)
    OpTaskStartClosure(fut, _, _, _) -> Ok(fut)
    OpFrameNew(dest, _) -> Ok(dest)
    OpFrameGet(dest, _, _, _) -> Ok(dest)
    OpFrameSet(_, _, _) -> Error(Nil)
  }
}

/// Operands read by an op.
pub fn op_reads(op: Op) -> List(Operand) {
  case op {
    OpConst(_, _) -> []
    OpBinop(_, _, left, right) -> [left, right]
    OpUnop(_, _, operand) -> [operand]
    OpCall(_, _, args, _) -> args
    OpBuiltin(_, _, args, _) -> args
    OpTuple(_, elems, _) -> elems
    OpBitArray(_, elems, _) -> elems
    OpTupleGet(_, tuple, _, _) -> [tuple]
    OpCtor(_, _, _, args, _) -> args
    OpTagIs(_, subject, _, _) -> [subject]
    OpField(_, subject, _, _, _) -> [subject]
    OpCopy(_, src, _) -> [src]
    OpPhi(_, incoming) ->
      list.map(incoming, fn(pair) {
        let #(operand, _) = pair
        operand
      })
    // A closure that captures the defining frame references it directly: the
    // frame owns the captured values (read back with `OpEnvGet`), so the
    // capture operands are metadata, not values the closure reads.
    OpClosure(_, _, captures, env_ty, _) ->
      case string.starts_with(env_ty, "__frame_") {
        True -> []
        False -> captures
      }
    OpEnvGet(_, _, _, _) -> []
    OpCallIndirect(_, fval, args, _) -> [fval, ..args]
    OpClosureEnv(_, closure, _) -> [closure]
    OpRetain(src, _) -> [Var(src)]
    OpDrop(src, _) -> [Var(src)]
    OpMachineStart(_, _, args, _) -> args
    OpTaskStart(_, _, args, _) -> args
    OpTaskStartClosure(_, _, closure, _) -> [closure]
    OpFrameNew(_, _) -> []
    OpFrameGet(_, frame, _, _) -> [frame]
    OpFrameSet(frame, _, value) -> [frame, value]
  }
}

/// Operands read in an owning position (the consumer takes a reference).
pub fn op_owning(op: Op) -> List(Operand) {
  case op {
    OpCall(_, _, args, _) -> args
    OpMachineStart(_, _, args, _) -> args
    OpTaskStart(_, _, args, _) -> args
    // The task takes its own reference to the closure's environment; the
    // closure value itself stays owned by the caller.
    OpTaskStartClosure(_, _, _, _) -> []
    OpCtor(_, _, _, args, _) -> args
    OpTuple(_, elems, _) -> elems
    OpBitArray(_, elems, _) -> elems
    OpCopy(_, src, _) -> [src]
    OpCallIndirect(_, _, args, _) -> args
    _ -> []
  }
}

/// Like `op_owning`, but the owning positions of a call depend on the callee's
/// parameter modes: only args declared/inferred `Owned` transfer ownership.
/// Calls whose callee is unknown (indirect, or missing from the maps) fail safe
/// to transferring every argument.
/// Owning args of a tail call (same rules as a direct `OpCall`).
pub fn tailcall_owning_modes(
  fun: String,
  args: List(Operand),
  fn_modes: Dict(String, List(ffi_modes.ParamMode)),
  _ffi: Dict(String, ffi_modes.FfiSig),
) -> List(Operand) {
  case dict.get(fn_modes, fun) {
    Ok(modes) -> owned_args(args, modes)
    Error(_) -> args
  }
}

pub fn op_owning_modes(
  op: Op,
  fn_modes: Dict(String, List(ffi_modes.ParamMode)),
  ffi: Dict(String, ffi_modes.FfiSig),
) -> List(Operand) {
  case op {
    OpCall(_, fun, args, _) ->
      case dict.get(fn_modes, fun) {
        Ok(modes) -> owned_args(args, modes)
        Error(_) -> args
      }
    OpBuiltin(_, name, args, _) ->
      case dict.get(ffi, name) {
        Ok(ffi_modes.FfiSig(modes, _)) -> owned_args(args, modes)
        // An `@external` (a bare symbol, no dot) borrows its arguments; the
        // runtime takes its own references. Unknown dotted builtins would be a
        // bug (the mode table must cover every builtin).
        Error(_) -> []
      }
    OpCallIndirect(_, _, args, _) -> args
    OpMachineStart(_, fun, args, _) ->
      case dict.get(fn_modes, fun) {
        Ok(modes) -> owned_args(args, modes)
        Error(_) -> args
      }
    OpTaskStart(_, fun, args, _) ->
      case dict.get(fn_modes, fun) {
        Ok(modes) -> owned_args(args, modes)
        Error(_) -> args
      }
    OpTaskStartClosure(_, _, _, _) -> []
    OpCtor(_, _, _, args, _) -> args
    OpTuple(_, elems, _) -> elems
    OpBitArray(_, elems, _) -> elems
    OpCopy(_, src, _) -> [src]
    // The closure owns the frame, which owns the captured values; owning the
    // capture operands as well would double-count them.
    OpClosure(_, _, captures, env_ty, _) ->
      case string.starts_with(env_ty, "__frame_") {
        True -> []
        False -> captures
      }
    // Storing into a frame field hands the value to the frame.
    OpFrameSet(_, _, value) -> [value]
    _ -> []
  }
}

fn owned_args(
  args: List(Operand),
  modes: List(ffi_modes.ParamMode),
) -> List(Operand) {
  case args, modes {
    [], _ -> []
    [arg, ..rest], [ffi_modes.Owned, ..rest_modes] -> [
      arg,
      ..owned_args(rest, rest_modes)
    ]
    [_, ..rest], [ffi_modes.Borrow, ..rest_modes] ->
      owned_args(rest, rest_modes)
    [arg, ..rest], [] -> [arg, ..owned_args(rest, [])]
  }
}

pub fn term_reads(term: Terminator) -> List(Operand) {
  case term {
    Jmp(_) -> []
    Branch(cond, _, _) -> [cond]
    Ret(value) -> [value]
    Tailcall(_, args) -> args
    TailcallIndirect(fval, args) -> [fval, ..args]
    TailMachine(_, args) -> args
    Suspend(fut, _, _, _) -> [fut]
    Unreachable -> []
  }
}

// ---------------------------------------------------------------------------
// text dump
// ---------------------------------------------------------------------------

pub fn describe_type(ty: Type) -> String {
  case ty {
    ast.TInt -> "Int"
    ast.TFloat -> "Float"
    ast.TBool -> "Bool"
    ast.TString -> "String"
    ast.TNil -> "Nil"
    ast.TVar(name) -> name
    ast.TNamed(name) -> name
    ast.TApp(name, args) ->
      name <> "(" <> string.join(list.map(args, describe_type), ", ") <> ")"
    ast.TTuple(types) ->
      "#(" <> string.join(list.map(types, describe_type), ", ") <> ")"
    ast.TFun(params, ret) ->
      "fn("
      <> string.join(list.map(params, describe_type), ", ")
      <> ") -> "
      <> describe_type(ret)
  }
}

pub fn to_text(module: Module) -> String {
  let Module(functions) = module
  let parts =
    list.map(functions, fn(function) {
      let Function(name, params, ret, blocks, locals) = function
      let header =
        "fn "
        <> name
        <> "("
        <> string.join(params, ", ")
        <> ") -> "
        <> describe_type(ret)
        <> " {\n"
      let locals_text =
        "  locals:\n"
        <> string.join(
          list.map(locals, fn(local) {
            let Local(local_name, local_ty, storage) = local
            "    "
            <> local_name
            <> ": "
            <> describe_type(local_ty)
            <> case storage {
              Slot -> ""
              Reg -> " (reg)"
            }
          }),
          "\n",
        )
        <> "\n"
      let blocks_text =
        string.join(
          list.map(blocks, fn(block) {
            let Block(label, ops, term) = block
            "  "
            <> label
            <> ":\n"
            <> string.join(list.map(ops, op_text), "\n")
            <> "\n    "
            <> term_text(term)
          }),
          "\n",
        )
      header <> locals_text <> blocks_text <> "\n}\n"
    })
  string.join(parts, "\n")
}

fn op_text(op: Op) -> String {
  case op {
    OpConst(dest, value) -> "    " <> dest <> " = const " <> literal_text(value)
    OpBinop(dest, op_name, a, b) ->
      "    "
      <> dest
      <> " = binop "
      <> op_name
      <> " "
      <> operand_text(a)
      <> ", "
      <> operand_text(b)
    OpUnop(dest, op_name, a) ->
      "    " <> dest <> " = unop " <> op_name <> " " <> operand_text(a)
    OpCall(dest, fun, args, ty) ->
      "    "
      <> dest
      <> " = call "
      <> fun
      <> "("
      <> string.join(list.map(args, operand_text), ", ")
      <> ") : "
      <> describe_type(ty)
    OpBuiltin(dest, name, args, ty) ->
      "    "
      <> dest
      <> " = builtin "
      <> name
      <> "("
      <> string.join(list.map(args, operand_text), ", ")
      <> ") : "
      <> describe_type(ty)
    OpBitArray(dest, elems, _) ->
      "    "
      <> dest
      <> " = bit_array "
      <> string.join(list.map(elems, operand_text), ", ")
    OpTuple(dest, elems, ty) ->
      "    "
      <> dest
      <> " = tuple "
      <> string.join(list.map(elems, operand_text), ", ")
      <> " : "
      <> describe_type(ty)
    OpTupleGet(dest, tuple, index, ty) ->
      "    "
      <> dest
      <> " = tupleget "
      <> operand_text(tuple)
      <> "."
      <> int.to_string(index)
      <> " : "
      <> describe_type(ty)
    OpCtor(dest, ctor, type_name, args, ty) ->
      "    "
      <> dest
      <> " = ctor "
      <> type_name
      <> "."
      <> ctor
      <> "("
      <> string.join(list.map(args, operand_text), ", ")
      <> ") : "
      <> describe_type(ty)
    OpTagIs(dest, subject, ctor, type_name) ->
      "    "
      <> dest
      <> " = tagis "
      <> operand_text(subject)
      <> " "
      <> type_name
      <> "."
      <> ctor
    OpField(dest, subject, ctor, index, ty) ->
      "    "
      <> dest
      <> " = field "
      <> operand_text(subject)
      <> "."
      <> ctor
      <> "._"
      <> int.to_string(index)
      <> " : "
      <> describe_type(ty)
    OpCopy(dest, src, ty) ->
      "    "
      <> dest
      <> " = copy "
      <> operand_text(src)
      <> " : "
      <> describe_type(ty)
    OpPhi(dest, incoming) ->
      "    "
      <> dest
      <> " = phi ["
      <> string.join(
        list.map(incoming, fn(pair) {
          let #(operand, label) = pair
          operand_text(operand) <> " @" <> label
        }),
        ", ",
      )
      <> "]"
    OpClosure(dest, code, captures, env_ty, ty) -> {
      let env_suffix = case env_ty {
        "" -> ""
        _ -> " env " <> env_ty
      }
      "    "
      <> dest
      <> " = closure "
      <> code
      <> " { "
      <> string.join(list.map(captures, operand_text), ", ")
      <> " }"
      <> env_suffix
      <> " : "
      <> describe_type(ty)
    }
    OpEnvGet(dest, env_ty, index, ty) ->
      "    "
      <> dest
      <> " = envget "
      <> env_ty
      <> "."
      <> int.to_string(index)
      <> " : "
      <> describe_type(ty)
    OpCallIndirect(dest, fval, args, ty) ->
      "    "
      <> dest
      <> " = callindirect "
      <> operand_text(fval)
      <> "("
      <> string.join(list.map(args, operand_text), ", ")
      <> ") : "
      <> describe_type(ty)
    OpClosureEnv(dest, closure, ty) ->
      "    "
      <> dest
      <> " = closureenv "
      <> operand_text(closure)
      <> " : "
      <> describe_type(ty)
    OpRetain(src, ty) -> "    retain " <> src <> " : " <> describe_type(ty)
    OpDrop(src, ty) -> "    drop " <> src <> " : " <> describe_type(ty)
    OpMachineStart(fut, fun, args, result_dest) ->
      "    "
      <> fut
      <> " = machinestart "
      <> fun
      <> "("
      <> string.join(list.map(args, operand_text), ", ")
      <> ") -> "
      <> result_dest
    OpTaskStart(fut, fun, args, into_future) ->
      "    "
      <> fut
      <> " = taskstart "
      <> fun
      <> "("
      <> string.join(list.map(args, operand_text), ", ")
      <> ") into_future="
      <> case into_future {
        True -> "true"
        False -> "false"
      }
    OpTaskStartClosure(fut, fun, closure, into_future) ->
      "    "
      <> fut
      <> " = taskstartclosure "
      <> fun
      <> "("
      <> operand_text(closure)
      <> ") into_future="
      <> case into_future {
        True -> "true"
        False -> "false"
      }
    OpFrameNew(dest, frame_ty) -> "    " <> dest <> " = framenew " <> frame_ty
    OpFrameGet(dest, frame, index, ty) ->
      "    "
      <> dest
      <> " = frameget "
      <> operand_text(frame)
      <> "."
      <> int.to_string(index)
      <> " : "
      <> describe_type(ty)
    OpFrameSet(frame, index, value) ->
      "    frameset "
      <> operand_text(frame)
      <> "."
      <> int.to_string(index)
      <> " = "
      <> operand_text(value)
  }
}

fn term_text(term: Terminator) -> String {
  case term {
    Jmp(label) -> "jmp " <> label
    Branch(cond, then, otherwise) ->
      "branch " <> operand_text(cond) <> " ? " <> then <> " : " <> otherwise
    Ret(value) -> "ret " <> operand_text(value)
    Tailcall(fun, args) ->
      "tailcall "
      <> fun
      <> "("
      <> string.join(list.map(args, operand_text), ", ")
      <> ")"
    TailcallIndirect(fval, args) ->
      "tailcallindirect "
      <> operand_text(fval)
      <> "("
      <> string.join(list.map(args, operand_text), ", ")
      <> ")"
    TailMachine(fun, args) ->
      "tailmachine "
      <> fun
      <> "("
      <> string.join(list.map(args, operand_text), ", ")
      <> ")"
    Suspend(fut, dest, resume, mode) ->
      "suspend "
      <> operand_text(fut)
      <> " -> "
      <> dest
      <> " @"
      <> resume
      <> " ["
      <> resume_mode_text(mode)
      <> "]"
    Unreachable -> "unreachable"
  }
}

fn resume_mode_text(mode: ResumeMode) -> String {
  case mode {
    Host -> "host"
    Machine -> "machine"
    Boxed -> "boxed"
    BoxedBorrow -> "boxed_borrow"
  }
}

fn operand_text(operand: Operand) -> String {
  case operand {
    Var(name) -> name
    Lit(value) -> literal_text(value)
  }
}

fn literal_text(value: Literal) -> String {
  case value {
    LInt(v) -> int.to_string(v)
    LFloat(v) -> float.to_string(v)
    LBool(True) -> "true"
    LBool(False) -> "false"
    LUnit -> "()"
    LString(v) -> "\"" <> v <> "\""
  }
}
