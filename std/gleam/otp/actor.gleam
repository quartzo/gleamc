//// The `Actor` abstraction, mirroring `gleam/otp/actor`: a process that holds
//// state and handles messages sequentially.
////
//// This is a subset of the original. There are no OTP system messages
//// (`Suspend`/`Resume`/`GetState`/`GetStatus`), no debug/tracing state, and no
//// `charlist`/`logger` integration; unexpected messages are discarded.
////
//// ```gleam
//// pub type Message(element) {
////   Push(element)
////   Pop(reply_with: Subject(Result(element, Nil)))
////   Shutdown
//// }
////
//// fn handle(stack: List(e), message: Message(e)) -> actor.Next(List(e), Message(e)) {
////   case message {
////     Push(value) -> actor.continue([value, ..stack])
////     Pop(client) -> {
////       case stack {
////         [first, ..rest] -> {
////           process.send(client, Ok(first))
////           actor.continue(rest)
////         }
////         [] -> {
////           process.send(client, Error(Nil))
////           actor.continue([])
////         }
////       }
////     }
////     Shutdown -> actor.stop()
////   }
//// }
//// ```

import gleam/dynamic
import gleam/erlang/process.{
  type Down, type ExitReason, type Selector, Abnormal, Killed, Normal,
}
import gleam/option.{type Option, None, Some}
import gleam/result

/// A message handled by the actor: a regular message, or an unexpected one.
type Message(message) {
  Message(message)
  Unexpected(Dynamic)
}

/// What to do after handling a message.
pub opaque type Next(state, message) {
  Continue(state: state, selector: Option(Selector(message)))
  Stop(ExitReason)
}

/// Continue, processing any waiting or future messages.
pub fn continue(state: state) -> Next(state, message) {
  Continue(state: state, selector: None)
}

/// Stop handling messages; the actor exits with reason `Normal`.
pub fn stop() -> Next(state, message) {
  Stop(Normal)
}

/// Stop and exit abnormally with the given reason.
pub fn stop_abnormal(reason: String) -> Next(state, message) {
  Stop(Abnormal(dynamic.from(reason)))
}

/// Replace the selector the actor receives messages with.
pub fn with_selector(
  value: Next(state, message),
  selector: Selector(message),
) -> Next(state, message) {
  case value {
    Continue(state, _) -> Continue(state: state, selector: Some(selector))
    Stop(_) -> value
  }
}

type Self(state, msg) {
  Self(
    parent: Pid,
    state: state,
    selector: Selector(Message(msg)),
    message_handler: fn(state, msg) -> Next(state, msg),
  )
}

/// A value returned to the parent when an actor starts successfully.
pub type Started(data) {
  Started(pid: Pid, data: data)
}

/// The result of starting an actor.
pub type StartResult(data) =
  Result(Started(data), StartError)

/// The result of an actor's initialiser.
pub opaque type Initialised(state, message, data) {
  Initialised(state: state, selector: Option(Selector(message)), return: data)
}

/// Take the post-initialisation state of the actor.
pub fn initialised(state: state) -> Initialised(state, message, Nil) {
  Initialised(state: state, selector: None, return: Nil)
}

/// Give the actor a selector to receive messages with.
pub fn selecting(
  initialised: Initialised(state, old_message, return),
  selector: Selector(message),
) -> Initialised(state, message, return) {
  let Initialised(state, _, return) = initialised
  Initialised(state: state, selector: Some(selector), return: return)
}

/// Set the data returned to the parent process.
pub fn returning(
  initialised: Initialised(state, message, old_return),
  return: return,
) -> Initialised(state, message, return) {
  let Initialised(state, selector, _) = initialised
  Initialised(state: state, selector: selector, return: return)
}

fn default_initialise(
  state: state,
  subject: Subject(message),
) -> Result(Initialised(state, message, Subject(message)), String) {
  let selector = process.new_selector() |> process.select(subject)
  Ok(Initialised(state: state, selector: Some(selector), return: subject))
}

/// A builder for an actor.
pub opaque type Builder(state, message, return) {
  Builder(
    initialise: fn(Subject(message)) ->
      Result(Initialised(state, message, return), String),
    initialisation_timeout: Int,
    on_message: fn(state, message) -> Next(state, message),
    name: Option(Name(message)),
  )
}

/// Create a builder for an actor with default initialisation: it returns a
/// fresh subject to the parent.
pub fn new(state: state) -> Builder(state, message, Subject(message)) {
  Builder(
    initialise: fn(subject: Subject(message)) {
      default_initialise(state, subject)
    },
    initialisation_timeout: 1000,
    on_message: fn(state, _message: message) {
      Continue(state: state, selector: None)
    },
    name: None,
  )
}

/// Create a builder with a custom initialiser that runs before the actor
/// starts handling messages. If it takes longer than `timeout` milliseconds
/// the actor is killed and `start` returns `InitTimeout`.
pub fn new_with_initialiser(
  timeout: Int,
  initialise: fn(Subject(message)) ->
    Result(Initialised(state, message, return), String),
) -> Builder(state, message, return) {
  Builder(
    initialise: initialise,
    initialisation_timeout: timeout,
    on_message: fn(state, _message: message) {
      Continue(state: state, selector: None)
    },
    name: None,
  )
}

/// Set the message handler for the actor.
pub fn on_message(
  builder: Builder(state, message, return),
  handler: fn(state, message) -> Next(state, message),
) -> Builder(state, message, return) {
  Builder(..builder, on_message: handler)
}

/// Register the actor under a name when it starts.
pub fn named(
  builder: Builder(state, message, return),
  name: Name(message),
) -> Builder(state, message, return) {
  Builder(..builder, name: Some(name))
}

fn exit_process(reason: ExitReason) -> ExitReason {
  case reason {
    Abnormal(reason) -> process.send_abnormal_exit(process.self(), reason)
    Killed -> process.kill(process.self())
    _ -> Nil
  }
  reason
}

fn receive_message(selector: Selector(Message(msg))) -> Message(msg) {
  process.selector_receive_forever(from: selector)
}

fn running_selector(
  selector: Selector(Message(msg)),
) -> Selector(Message(msg)) {
  process.new_selector()
  |> process.select_other(fn(message) { Unexpected(message) })
  |> process.merge_selector(selector)
}

fn loop(self: Self(state, msg)) -> ExitReason {
  let Self(parent, state, selector, handler) = self
  case receive_message(selector) {
    Unexpected(_message) -> loop(Self(parent, state, selector, handler))
    Message(msg) ->
      case handler(state, msg) {
        Stop(reason) -> exit_process(reason)
        Continue(state: state, selector: new_selector) -> {
          let selector = case new_selector {
            None -> selector
            Some(s) ->
              running_selector(process.map_selector(s, fn(m) { Message(m) }))
          }
          loop(Self(parent, state, selector, handler))
        }
      }
  }
}

fn initialise_actor(
  builder: Builder(state, msg, return),
  parent: Pid,
  ack: Subject(Result(return, String)),
) -> ExitReason {
  let Builder(initialise, _timeout, handler, name_op) = builder
  let result = {
    use subject <- result.try(case name_op {
      None -> Ok(process.new_subject())
      Some(name) -> {
        use _ <- result.try(try_register_self(name))
        Ok(process.named_subject(name))
      }
    })
    use result <- result.try(initialise(subject))
    Ok(#(subject, result))
  }

  case result {
    Ok(#(subject, Initialised(state:, selector:, return:))) -> {
      let selector = case selector {
        Some(selector) -> selector
        None -> process.new_selector() |> process.select(subject)
      }
      let selector =
        running_selector(process.map_selector(selector, fn(m) { Message(m) }))
      process.send(ack, Ok(return))
      let self =
        Self(
          parent: parent,
          state: state,
          selector: selector,
          message_handler: handler,
        )
      let reason = loop(self)
      reason
    }
    Error(reason) -> {
      process.send(ack, Error(reason))
      exit_process(Normal)
    }
  }
}

fn try_register_self(name: Name(msg)) -> Result(Nil, String) {
  case process.register(process.self(), name) {
    Ok(Nil) -> Ok(Nil)
    Error(_) -> Error("name already registered")
  }
}

/// Why an actor failed to start.
pub type StartError {
  InitTimeout
  InitFailed(String)
  InitExited(ExitReason)
}

type StartInitMessage(data) {
  Ack(Result(data, String))
  Mon(Down)
}

/// Start an actor from a `Builder`.
pub fn start(
  builder: Builder(state, msg, return),
) -> Result(Started(return), StartError) {
  let timeout = builder.initialisation_timeout
  let ack_subject = process.new_subject()
  let parent = process.self()
  let child =
    process.spawn(fn() { initialise_actor(builder, parent, ack_subject) })
  let monitor = process.monitor(child)
  let selector =
    process.new_selector()
    |> process.select_map(ack_subject, fn(message) { Ack(message) })
    |> process.select_specific_monitor(monitor, fn(down) { Mon(down) })
  let result = case process.selector_receive(from: selector, within: timeout) {
    Ok(Ack(Ok(subject))) -> Ok(subject)
    Ok(Ack(Error(reason))) -> Error(InitFailed(reason))
    // The child exited. An initialiser that failed sends its result and only
    // then exits, so the ack may be queued alongside the `Down`; prefer it so a
    // failed initialisation reports `InitFailed` rather than `InitExited`.
    Ok(Mon(down)) ->
      case process.receive(ack_subject, 0) {
        Ok(Ok(subject)) -> Ok(subject)
        Ok(Error(reason)) -> Error(InitFailed(reason))
        Error(_) -> Error(InitExited(down.reason))
      }
    Error(Nil) -> {
      process.unlink(child)
      process.kill(child)
      Error(InitTimeout)
    }
  }
  // Drop the monitor used to observe initialisation, so a later exit of the
  // child does not deliver a stray `Down` to the parent.
  process.demonitor_process(monitor)
  case result {
    Ok(data) -> Ok(Started(pid: child, data: data))
    Error(error) -> Error(error)
  }
}

/// Send a message to an actor (a re-export of `process.send`).
pub fn send(subject: Subject(msg), msg: msg) -> Nil {
  process.send(subject, msg)
}

/// Send a message and wait for a reply (a re-export of `process.call`).
pub fn call(
  subject: Subject(message),
  waiting: Int,
  sending: fn(Subject(reply)) -> message,
) -> reply {
  process.call(subject, waiting, sending)
}
