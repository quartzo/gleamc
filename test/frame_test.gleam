import gleam/dict
import gleam/list
import gleam/string
import gleamc/ast
import gleamc/frame
import gleamc/ir
import gleamc/llvm
import gleamc/pipeline

const capture_source = "import gleam/io
import gleam/int

fn make(a: Int) -> fn(Int) -> Int {
  fn(b) { a + b }
}

pub fn main() {
  let f = make(10)
  io.println(int.to_string(f(1)))
}
"

/// A closure captures `a`, so some function must report a frame field.
pub fn frame_captured_test() {
  let assert Ok(module) = pipeline.compile_to_ir(capture_source)
  let ir.Module(functions) = module
  let captured =
    list.any(functions, fn(function) {
      !list.is_empty(frame.captured_vars(function))
    })
  assert captured
}

/// A capturing closure makes its function a heap-frame machine. Async does
/// not: a `Future` is a value awaited through the libuv loop.
pub fn frame_machine_test() {
  let assert Ok(module) = pipeline.compile_to_ir(capture_source)
  let machines = frame.machine_functions(module)
  assert list.contains(machines, "make")
}

/// A `step` receiving its frame as the generic `Opaque` handle (`i8*`) is
/// compiled as ordinary code: the backend bitcasts the parameter to the
/// concrete frame struct at entry.
pub fn opaque_frame_param_test() {
  let step =
    ir.Function(
      "f__step",
      ["__frame"],
      ast.TNamed("Future"),
      [
        ir.Block(
          "entry",
          [ir.OpFrameSet(ir.Var("__frame"), 0, ir.Lit(ir.LInt(0)))],
          ir.Ret(ir.Var("__frame")),
        ),
      ],
      [
        ir.Local("__frame", ast.TNamed("Opaque"), ir.Slot),
        ir.Local("x", ast.TInt, ir.Slot),
      ],
    )
  let ll = llvm.emit(ir.Module([step]), [], dict.new())
  assert string.contains(ll, "define i8* @Gleamc_f__step(i8* %arg.__frame)")
  assert string.contains(
    ll,
    "%__fr = bitcast i8* %arg.__frame to %__frame_f__step*",
  )
}
