//// Process primitives, mirroring `gleam/erlang/process`.
////
//// Defined in Gleam on top of the `process_ffi.*` builtins so the public
//// signatures and labelled arguments match the original package. `Subject(a)`
//// is a compiler-known handle type, not declared here.

/// Create a new `Subject` owned by the current process.
pub fn new_subject() -> Subject(message) {
  process_ffi.new_subject()
}

/// Send a message using a `Subject`.
pub fn send(subject: Subject(message), message: message) -> Nil {
  process_ffi.send(subject, message)
}

/// Receive a message that has been sent to the current process using the
/// `Subject`, waiting at most `timeout` milliseconds.
pub fn receive(from: Subject(message), within: Int) -> Result(message, Nil) {
  // Timeout is not wired to the scheduler yet; `receive` blocks until a
  // message arrives.
  let _ = within
  Ok(process_ffi.receive(from))
}

/// Receive a message, waiting forever.
pub fn receive_forever(from: Subject(message)) -> message {
  process_ffi.receive(from)
}

/// Suspend the current process for the given number of milliseconds.
pub fn sleep(a: Int) -> Nil {
  time.timer(a)
}

/// Suspend the current process forever.
pub fn sleep_forever() -> Nil {
  process_ffi.receive(new_subject())
}
