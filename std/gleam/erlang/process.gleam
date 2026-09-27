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
    // A message is queued: read it straight from the builtin (a borrow) rather
    // than through `receive_forever`, so no ownership is transferred.
    1 -> Ok(process_ffi.receive(from))
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

/// A message received when a monitored process exits.
pub type Down {
  ProcessDown(monitor: Monitor, pid: Pid, reason: ExitReason)
}

/// Why a process exited.
pub type ExitReason {
  Normal
  Killed
}

/// A message received when a linked process exits and exits are trapped.
pub type ExitMessage {
  ExitMessage(pid: Pid, reason: ExitReason)
}

/// The handlers of a `Selector`, as a recursive list.
type Handlers(payload) {
  More(handle: Int, run: fn() -> Result(payload, Nil), rest: Handlers(payload))
  Done
}

/// Waits for a message on any of several subjects at once. Each handler polls
/// non-destructively; a message no handler accepts is set aside and re-examined
/// on the next wake.
pub opaque type Selector(payload) {
  Selector(handle: Int, handlers: Handlers(payload))
}

/// Create a new `Selector`, which can wait for a message on several subjects
/// at once.
pub fn new_selector() -> Selector(payload) {
  Selector(handle: process_ffi.selector_new(), handlers: Done)
}

/// Add a `Subject` to a `Selector`.
pub fn select(
  selector: Selector(payload),
  for: Subject(payload),
) -> Selector(payload) {
  add_handler(selector, for, fn(message) { Ok(message) })
}

/// Generate a new name that a process can register itself with using
/// `register`, and others can send messages to with `named_subject`.
pub fn new_name(prefix: String) -> Name(message) {
  let _ = prefix
  process_ffi.new_name()
}

/// Register a process under a name.
pub fn register(pid: Pid, name: Name(message)) -> Result(Nil, Nil) {
  case process_ffi.register(pid, name) {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}

/// Un-register a name.
pub fn unregister(name: Name(message)) -> Result(Nil, Nil) {
  case process_ffi.unregister(name) {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}

/// Look up the process registered under a name.
pub fn named(name: Name(message)) -> Result(Pid, Nil) {
  let pid = process_ffi.named(name)
  case pid < 0 {
    True -> Error(Nil)
    False -> Ok(process_ffi.pid_of_int(pid))
  }
}

/// Create a subject for a name, used to send and receive messages.
pub fn named_subject(name: Name(message)) -> Subject(message) {
  process_ffi.named_subject(name)
}

/// Get the owner process of a subject. For a named subject this is the process
/// registered under the name, returning an error if none is registered.
pub fn subject_owner(subject: Subject(message)) -> Result(Pid, Nil) {
  let owner = process_ffi.subject_owner(subject)
  case owner < 0 {
    True -> Error(Nil)
    False -> Ok(process_ffi.pid_of_int(owner))
  }
}

/// Get the name of a subject, returning `Error(Nil)` if it has none.
pub fn subject_name(subject: Subject(message)) -> Result(Name(message), Nil) {
  let name = process_ffi.subject_name(subject)
  case name < 0 {
    True -> Error(Nil)
    False -> Ok(process_ffi.name_of_int(name))
  }
}

/// Monitor a process, so that a `Down` message is sent to the current process
/// when it exits. Remove it with `demonitor`.
pub fn monitor(pid: Pid) -> Monitor {
  process_ffi.monitor(pid)
}

/// Stop monitoring a process.
pub fn demonitor(monitor: Monitor) -> Nil {
  process_ffi.demonitor(monitor)
}

/// Stop monitoring a process (alias of `demonitor`).
pub fn demonitor_process(monitor: Monitor) -> Nil {
  process_ffi.demonitor(monitor)
}

/// Add a handler for `Down` messages from any monitor to a `Selector`.
pub fn select_monitors(
  selector: Selector(payload),
  mapping: fn(Down) -> payload,
) -> Selector(payload) {
  add_handler(selector, process_ffi.self_down_inbox(), fn(down) {
    Ok(mapping(down))
  })
}

/// Send an untrappable kill signal to a process, terminating it.
pub fn kill(pid: Pid) -> Nil {
  process_ffi.kill(pid)
}

/// Send an exit signal to a process. A trapping process receives an
/// `ExitMessage`; a non-trapping one ignores a `Normal` signal.
pub fn send_exit(to: Pid) -> Nil {
  process_ffi.send_exit(to)
}

/// Send an abnormal exit signal to a process, terminating a non-trapping one.
/// The reason is not carried, so a trapping process sees `Killed`.
pub fn send_abnormal_exit(pid: Pid, reason: a) -> Nil {
  let _ = reason
  process_ffi.send_abnormal_exit(pid)
}

/// Create a link between the current process and `pid`.
pub fn link(pid: Pid) -> Bool {
  process_ffi.link(pid)
}

/// Remove any link between the current process and `pid`.
pub fn unlink(pid: Pid) -> Nil {
  process_ffi.unlink(pid)
}

/// Set whether the current process traps exits; when it does, a linked
/// process exiting sends an `ExitMessage` instead of propagating.
pub fn trap_exits(a: Bool) -> Nil {
  process_ffi.trap_exits(a)
}

/// Add a handler for trapped exit messages to a `Selector`.
pub fn select_trapped_exits(
  selector: Selector(payload),
  handler: fn(ExitMessage) -> payload,
) -> Selector(payload) {
  add_handler(selector, process_ffi.self_exit_inbox(), fn(message) {
    Ok(handler(message))
  })
}

/// Add a handler for `Down` messages from a specific monitor.
pub fn select_specific_monitor(
  selector: Selector(payload),
  monitor: Monitor,
  mapping: fn(Down) -> payload,
) -> Selector(payload) {
  add_handler(selector, process_ffi.self_down_inbox(), fn(down) {
    case down {
      ProcessDown(down_monitor, _, _) ->
        case process_ffi.monitor_eq(down_monitor, monitor) {
          True -> Ok(mapping(down))
          False -> Error(Nil)
        }
    }
  })
}

/// Remove a `Subject` from a `Selector`.
pub fn deselect(
  selector: Selector(payload),
  for: Subject(payload),
) -> Selector(payload) {
  Selector(
    handle: process_ffi.selector_remove(selector.handle, for),
    handlers: remove_handler(selector.handlers, process_ffi.subject_handle(for)),
  )
}

/// Transform the payload of every handler in a `Selector`.
pub fn map_selector(a: Selector(a), b: fn(a) -> b) -> Selector(b) {
  Selector(handle: a.handle, handlers: map_handlers(a.handlers, b))
}

fn map_handlers(handlers: Handlers(a), f: fn(a) -> b) -> Handlers(b) {
  case handlers {
    Done -> Done
    More(handle, run, rest) ->
      More(
        handle,
        fn() {
          case run() {
            Ok(value) -> Ok(f(value))
            Error(_) -> Error(Nil)
          }
        },
        map_handlers(rest, f),
      )
  }
}

/// Merge two selectors into one containing the handlers of both. If a subject
/// is handled by both, the second selector's handler takes precedence.
pub fn merge_selector(
  a: Selector(payload),
  b: Selector(payload),
) -> Selector(payload) {
  Selector(
    handle: process_ffi.selector_merge(a.handle, b.handle),
    handlers: append_handlers(b.handlers, a.handlers),
  )
}

fn append_handlers(x: Handlers(payload), y: Handlers(payload)) -> Handlers(payload) {
  case x {
    Done -> y
    More(handle, run, rest) -> More(handle, run, append_handlers(rest, y))
  }
}

/// Add a `Subject` to a `Selector`, transforming each message with `mapping`.
pub fn select_map(
  selector: Selector(payload),
  for: Subject(message),
  mapping: fn(message) -> payload,
) -> Selector(payload) {
  add_handler(selector, for, fn(message) { Ok(mapping(message)) })
}

fn add_handler(
  selector: Selector(payload),
  subject: Subject(message),
  decide: fn(message) -> Result(payload, Nil),
) -> Selector(payload) {
  Selector(
    handle: process_ffi.selector_add(selector.handle, subject),
    handlers: append_handler(
      selector.handlers,
      More(
        process_ffi.subject_handle(subject),
        fn() { drain(subject, decide, process_ffi.mailbox_len(subject)) },
        Done,
      ),
    ),
  )
}

fn append_handler(handlers: Handlers(payload), item: Handlers(payload)) -> Handlers(payload) {
  case handlers {
    Done -> item
    More(handle, run, rest) -> More(handle, run, append_handler(rest, item))
  }
}

fn remove_handler(handlers: Handlers(payload), target: Int) -> Handlers(payload) {
  case handlers {
    Done -> Done
    More(handle, run, rest) ->
      case handle == target {
        True -> remove_handler(rest, target)
        False -> More(handle, run, remove_handler(rest, target))
      }
  }
}

fn drain(
  subject: Subject(message),
  decide: fn(message) -> Result(payload, Nil),
  remaining: Int,
) -> Result(payload, Nil) {
  case remaining <= 0 {
    True -> Error(Nil)
    False ->
      case process_ffi.has_message(subject) {
        False -> Error(Nil)
        True -> {
          let message = process_ffi.receive(subject)
          case decide(message) {
            Ok(value) -> Ok(value)
            Error(_) -> {
              process_ffi.unreceive(subject, message)
              drain(subject, decide, remaining - 1)
            }
          }
        }
      }
  }
}

fn poll(handlers: Handlers(payload)) -> Result(payload, Nil) {
  case handlers {
    Done -> Error(Nil)
    More(_, run, rest) ->
      case run() {
        Ok(value) -> Ok(value)
        Error(_) -> poll(rest)
      }
  }
}

/// Receive a message from any of the `Selector`'s subjects, within `within`
/// milliseconds.
pub fn selector_receive(
  from: Selector(payload),
  within: Int,
) -> Result(payload, Nil) {
  case poll(from.handlers) {
    Ok(value) -> Ok(value)
    Error(_) ->
      case process_ffi.selector_wait(from.handle, within) {
        1 -> selector_receive(from, within)
        _ -> Error(Nil)
      }
  }
}

/// Receive a message from any of the `Selector`'s subjects, waiting forever.
pub fn selector_receive_forever(from: Selector(payload)) -> payload {
  case poll(from.handlers) {
    Ok(value) -> value
    Error(_) -> {
      let _ = process_ffi.selector_wait(from.handle, -1)
      selector_receive_forever(from)
    }
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
