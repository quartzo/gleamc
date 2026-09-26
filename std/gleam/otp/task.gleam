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

/// Wait for the value computed by a task.
///
/// The timeout is not wired to the scheduler yet, so this waits indefinitely.
pub fn await(task: Task(value), timeout: Int) -> value {
  let _ = timeout
  task_ffi.await(task)
}

/// Wait for the value computed by a task, returning `Error(Timeout)` if it does
/// not arrive in time. The timeout is not wired yet, so this waits forever.
pub fn try_await(task: Task(value), timeout: Int) -> Result(value, AwaitError) {
  let _ = timeout
  Ok(task_ffi.await(task))
}
