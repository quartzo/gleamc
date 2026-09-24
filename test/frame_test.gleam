import gleam/list
import gleamc/frame
import gleamc/ir
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

const timer_source = "import gleam/io

pub fn main() {
  io.println(\"start\")
  let _ = time.timer(5)
  io.println(\"end\")
}
"

/// A suspension makes `main` a machine function.
pub fn frame_machine_test() {
  let assert Ok(module) = pipeline.compile_to_ir(timer_source)
  let machines = frame.machine_functions(module)
  assert !list.is_empty(machines)
  assert list.contains(machines, "main")
}
