# 5. Concurrency and tasks

`gleamc` has a cooperative scheduler driven by libuv. A **task** is a process
with its own heap frame; tasks yield at suspensions (`receive`, `await`,
`time.timer`, file I/O) and the driver resumes them when the awaited event
completes.

The API mirrors `gleam/erlang/process` and `gleam/otp/task`, so programs are
written the same way.

## The model: subjects are channels

A `Subject(a)` is a typed **channel**: it is its own queue of messages of type
`a`. `send` enqueues into that subject's queue and `receive` dequeues from it.
There is **no single "process mailbox"**: a task owns one queue per subject it
created (plus the monitor/exit queues described below). This matches the
observable Gleam API, which is always *subject-oriented* — you receive `from` a
subject, or from a `Selector` over several subjects — never from "the process".

Because a subject is homogeneous (`Subject(a)`), `receive` returns exactly one
`a`; the pattern match you may want is an ordinary typed `case` in your code.

```gleam
let s = new_subject()          // Subject(message), type resolved by use
send(s, 42)                    // s : Subject(Int)
let x = receive_forever(from: s)   // x : Int
```

## Processes

```gleam
import gleam/erlang/process

pub fn main() {
  let pid = process.spawn(fn() { work() })   // linked process
  let _ = process.spawn_unlinked(fn() { work() })

  process.self()            // Pid of the current task
  process.is_alive(pid)     // Bool
  process.sleep(20)         // suspend this task for 20ms
  process.sleep_forever()
}
```

- `spawn` / `spawn_unlinked` / `task.async` are **builtins**: the compiler
  starts the zero-argument closure as a task at the call site.
- `Pid` is a stable task id.

## Subjects and receive

```gleam
let s = process.new_subject()
process.send(s, "hi")

process.receive(from: s, within: 100)   // Result(String, Nil): Error on timeout
process.receive_forever(from: s)        // String
```

`receive` races the subject against a libuv timer; `receive_forever` waits.

## Tasks

```gleam
import gleam/otp/task

let t = task.async(fn() { expensive() })
task.pid(t)
task.await_forever(t)          // a
task.await(t, 100)             // a, crashes on timeout
task.try_await(t, 100)         // Result(a, AwaitError)
```

`AwaitError` is `Timeout` or `Exit(reason)` (the task was killed before
producing a value; the reason is the `Killed` exit reason wrapped as a
`Dynamic`).

## Selectors

A `Selector(payload)` waits for messages from several subjects at once. Each
handler runs in-process; a message no handler accepts is set aside and
re-examined on the next wake.

```gleam
let sel =
  process.new_selector()
  |> process.select(for: a)                       // Subject(payload)
  |> process.select_map(for: b, mapping: f)       // transform messages
  |> process.deselect(for: c)
process.selector_receive(from: sel, within: 100)  // Result(payload, Nil)
process.selector_receive_forever(from: sel)       // payload
```

- `map_selector` transforms the payload of every handler;
  `merge_selector` combines two selectors (the second wins for a shared
  subject).
- `select_other(mapping: fn(Dynamic) -> payload)` is a **catch-all** over the
  subjects the task owns (a subject created *after* it is added is not
  watched).
- `select_specific_monitor` / `deselect_specific_monitor` add/remove a handler
  filtered by one `Monitor`.

## Monitors, links and exits

```gleam
let mon = process.monitor(pid)          // Down message when pid exits
process.demonitor_process(mon)

let _ = process.link(pid)               // exits propagate
process.unlink(pid)
process.trap_exits(True)                // linked exits arrive as ExitMessage
process.kill(pid)                       // untrappable kill
process.send_exit(pid)                  // Normal exit signal
process.send_abnormal_exit(pid, reason) // abnormal; reason carried as Dynamic
```

- A non-trapping link **propagates** the exit (the linked task is terminated);
  a trapping link receives an `ExitMessage`.
- `ExitReason` is `Normal`, `Killed` or `Abnormal(reason: Dynamic)`.
- Receive `Down`/`ExitMessage` with `select_monitors`, `select_specific_monitor`
  and `select_trapped_exits`.

## Names

```gleam
let name = process.new_name("server")
let pid = process.spawn(fn() { server(process.named_subject(name)) })
process.register(pid, name)
process.named(name)               // Result(Pid, Nil)
process.named_subject(name)       // Subject(a)
process.unregister(name)
```

`subject_owner(subject)` returns the owning `Pid`;
`subject_name(subject)` returns its `Name` if it has one.

## Timers

```gleam
let timer = process.send_after(subject, 20, message)   // Timer
case process.cancel_timer(timer) {
  Cancelled(remaining) -> ...
  TimerNotFound -> ...
}
```

## Request / reply

```gleam
process.call(inbox, waiting: 100, sending: fn(reply) { Ping(reply) })
process.call_forever(inbox, sending: fn(reply) { Ping(reply) })
```

Both monitor the callee so a crash surfaces instead of hanging.

## Actors (`gleam/otp/actor`)

The OTP actor MVP mirrors the original module's `Builder`/`Next` API.

```gleam
import gleam/erlang/process
import gleam/otp/actor

pub type Message(element) {
  Push(element)
  Pop(reply_with: Subject(Result(element, Nil)))
  Shutdown
}

fn handle_message(
  stack: List(e),
  message: Message(e),
) -> actor.Next(List(e), Message(e)) {
  case message {
    Shutdown -> actor.stop()
    Push(value) -> actor.continue([value, ..stack])
    Pop(client) -> {
      case stack {
        [first, ..rest] -> {
          process.send(client, Ok(first))
          actor.continue(rest)
        }
        [] -> {
          process.send(client, Error(Nil))
          actor.continue([])
        }
      }
    }
  }
}

pub fn main() {
  let assert Ok(a) =
    actor.new([]) |> actor.on_message(handle_message) |> actor.start
  let subject = a.data
  process.send(subject, Push("Joe"))
  let assert Ok("Joe") =
    process.call(subject, waiting: 100, sending: fn(reply) { Pop(reply) })
  process.send(subject, Shutdown)
}
```

- `actor.new(state)` returns a `Builder`; `on_message(builder, handler)` sets the
  handler and `named(builder, name)` registers the actor with `start`.
- `actor.start(builder)` spawns the actor and returns
  `Result(Started(pid:, data:), StartError)`. The initialiser runs before the
  first message; a failure is `InitFailed(String)`, an init crash is
  `InitExited(ExitReason)` and exceeding `initialisation_timeout` is
  `InitTimeout`.
- A handler returns `Next`: `actor.continue(state)`, `actor.stop()` or
  `actor.stop_abnormal(reason)`. `actor.with_selector(next, selector)` swaps the
  selector the actor receives with.
- `new_with_initialiser(timeout, initialise)` builds an actor with a custom
  initialiser returning `Result(Initialised(state, message, return), String)`,
  built with `actor.initialised(state)`, `actor.selecting(...)` and
  `actor.returning(...)`.
- `actor.send` / `actor.call` are re-exports of the process primitives.

`InitTimeout` is currently unreachable because of a pre-existing
`process.spawn` bug (see [known-limitations](../known-limitations.md)).

## Housekeeping

- `flush_messages()` discards every message queued for the current task's
  subjects.
- When `main` returns, the runtime terminates any still-pending tasks (freeing
  their frames, completion futures and queued messages) and closes pending
  timers.

## Caveats

- `Subject` is a channel, not a shared process mailbox; there is no
  whole-inbox selective receive and `select_record` is not implemented (it
  targets raw Erlang tuples, which do not exist here).
- Message payloads are dropped when a message is freed without being received.
- Reference cycles leak (no cycle collector); task/selector/dynamic handles and
  messages are refcounted individually.
