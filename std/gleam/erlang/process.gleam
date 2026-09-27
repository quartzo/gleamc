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
/// `Subject`, waiting at most `within` milliseconds.
pub fn receive(from: Subject(message), within: Int) -> Result(message, Nil) {
  case process_ffi.wait_any(from, within) {
    1 -> Ok(receive_forever(from))
    _ -> Error(Nil)
  }
}

/// Receive a message, waiting forever.
pub fn receive_forever(from: Subject(message)) -> message {
  process_ffi.receive(from)
}

/// Get the `Pid` of the current process.
pub fn self() -> Pid {
  process_ffi.self()
}

/// Check whether the process for a given `Pid` is alive.
pub fn is_alive(a: Pid) -> Bool {
  process_ffi.is_alive(a)
}

/// Suspend the current process for the given number of milliseconds.
pub fn sleep(a: Int) -> Nil {
  time.timer(a)
}

/// Suspend the current process forever.
pub fn sleep_forever() -> Nil {
  process_ffi.receive(new_subject())
}
