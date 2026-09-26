//// Tasks: run a function concurrently and await its result, mirroring
//// `gleam/otp/task`.
////
//// `task.async` is a compiler/runtime builtin with the exact signature
//// `fn(fn() -> a) -> Task(a)`: it must stay a builtin so the compiler can start
//// the closure as a task at the call site, so it is not declared here.

/// The reason a `try_await` did not return a value.
pub type AwaitError {
  Timeout
}

/// Wait endlessly for the value computed by a task.
pub fn await_forever(task: Task(value)) -> value {
  task_ffi.await(task)
}

/// Wait for the value computed by a task, crashing if it does not arrive
/// within `timeout` milliseconds.
pub fn await(task: Task(value), timeout: Int) -> value {
  let assert Ok(value) = try_await(task, timeout)
  value
}

/// Wait for the value computed by a task, returning `Error(Timeout)` if it does
/// not arrive within `timeout` milliseconds.
pub fn try_await(task: Task(value), timeout: Int) -> Result(value, AwaitError) {
  case task_ffi.await_timeout(task, timeout) {
    1 -> Ok(task_ffi.await(task))
    _ -> Error(Timeout)
  }
}
