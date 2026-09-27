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

/// Create a new `Selector`, which can wait for a message on several subjects
/// at once.
pub fn new_selector() -> Selector(payload) {
  process_ffi.selector_new()
}

/// Add a `Subject` to a `Selector`.
pub fn select(
  selector: Selector(payload),
  for: Subject(payload),
) -> Selector(payload) {
  process_ffi.selector_add(selector, for)
}

/// Remove a `Subject` from a `Selector`.
pub fn deselect(
  selector: Selector(payload),
  for: Subject(payload),
) -> Selector(payload) {
  process_ffi.selector_remove(selector, for)
}

/// Add a `Subject` to a `Selector`, transforming each message with `mapping`.
///
/// The transform runs in a forwarder task that reads the subject and sends the
/// mapped value on an internal subject the selector waits on.
pub fn select_map(
  selector: Selector(payload),
  for: Subject(message),
  mapping: fn(message) -> payload,
) -> Selector(payload) {
  let mapped = new_subject()
  let _ = process.spawn(fn() { forward(for, mapped, mapping) })
  process_ffi.selector_add(selector, mapped)
}

fn forward(
  from: Subject(message),
  to: Subject(payload),
  mapping: fn(message) -> payload,
) -> Nil {
  let message = receive_forever(from: from)
  send(to, mapping(message))
  forward(from, to, mapping)
}

/// Receive a message from any of the `Selector`'s subjects, within `within`
/// milliseconds.
pub fn selector_receive(
  from: Selector(payload),
  within: Int,
) -> Result(payload, Nil) {
  let _ = process_ffi.selector_wait(from, within)
  let index = process_ffi.selector_ready(from)
  case index < 0 {
    True -> Error(Nil)
    False ->
      Ok(receive_forever(from: process_ffi.selector_subject(from, index)))
  }
}

/// Receive a message from any of the `Selector`'s subjects, waiting forever.
pub fn selector_receive_forever(from: Selector(payload)) -> payload {
  let _ = process_ffi.selector_wait(from, -1)
  let index = process_ffi.selector_ready(from)
  case index < 0 {
    True -> selector_receive_forever(from)
    False -> receive_forever(from: process_ffi.selector_subject(from, index))
  }
}

/// How a timer cancellation ended.
pub type Cancelled {
  /// The timer could not be found; it has likely already triggered.
  TimerNotFound
  /// The timer was cancelled with `time_remaining` milliseconds left.
  Cancelled(time_remaining: Int)
}

/// Schedule `message` to be sent to `subject` after `delay` milliseconds, and
/// return a `Timer` that can be cancelled.
pub fn send_after(subject: Subject(msg), delay: Int, message: msg) -> Timer {
  process_ffi.send_after(subject, delay, message)
}

/// Cancel a timer, reporting how long was left if it had not fired.
pub fn cancel_timer(timer: Timer) -> Cancelled {
  let remaining = process_ffi.cancel_timer(timer)
  case remaining < 0 {
    True -> TimerNotFound
    False -> Cancelled(remaining)
  }
}

/// Suspend the current process for the given number of milliseconds.
pub fn sleep(a: Int) -> Nil {
  time.timer(a)
}

/// Suspend the current process forever.
pub fn sleep_forever() -> Nil {
  process_ffi.receive(new_subject())
}
