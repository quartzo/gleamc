import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline
import gleamc/toolchain

// The OTP actor MVP (`gleam/otp/actor`): a stack actor driven with
// `actor.start`, `process.send` and `process.call`, a failed initialiser
// reported as `InitFailed`, and an actor registered under a `Name`.
const source = "import gleam/erlang/process
import gleam/io
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
        [] -> {
          process.send(client, Error(Nil))
          actor.continue([])
        }
        [first, ..rest] -> {
          process.send(client, Ok(first))
          actor.continue(rest)
        }
      }
    }
  }
}

pub fn main() {
  let assert Ok(a) =
    actor.new([]) |> actor.on_message(handle_message) |> actor.start
  let subject = a.data
  process.send(subject, Push(\"Joe\"))
  process.send(subject, Push(\"Mike\"))
  process.send(subject, Push(\"Robert\"))
  let assert Ok(\"Robert\") =
    process.call(subject, waiting: 100, sending: fn(reply) { Pop(reply) })
  let assert Ok(\"Mike\") =
    process.call(subject, waiting: 100, sending: fn(reply) { Pop(reply) })
  let assert Ok(\"Joe\") =
    process.call(subject, waiting: 100, sending: fn(reply) { Pop(reply) })
  let assert Error(Nil) =
    process.call(subject, waiting: 100, sending: fn(reply) { Pop(reply) })
  process.send(subject, Shutdown)
  io.println(\"stack ok\")

  let bad_init = fn(_subject: Subject(Message(String))) { Error(\"nope\") }
  let assert Error(actor.InitFailed(\"nope\")) =
    actor.new_with_initialiser(1000, bad_init)
    |> actor.on_message(handle_message)
    |> actor.start
  io.println(\"initfailed ok\")

  let name = process.new_name(\"stack\")
  let assert Ok(_) =
    actor.new([])
    |> actor.on_message(handle_message)
    |> actor.named(name)
    |> actor.start
  process.send(process.named_subject(name), Push(\"Named\"))
  let assert Ok(\"Named\") =
    process.call(process.named_subject(name), waiting: 100, sending: fn(reply) {
      Pop(reply)
    })
  io.println(\"named ok\")
}
"

/// End-to-end: an actor starts, handles `send`/`call`, stops on `Shutdown`, a
/// failing initialiser reports `InitFailed`, and a named actor is reachable
/// through `named_subject`.
pub fn actor_test() {
  let _ = ffi.run("mkdir -p /tmp/gleamc-test")
  let entry = "/tmp/gleamc-test/actor.gleam"
  let assert Ok(_) = ffi.write_file(entry, source)
  let assert Ok(modules) = loader.load(entry)
  let assert Ok(ll) = pipeline.compile_modules_llvm(modules)
  let ll_path = "/tmp/gleamc-test/actor.ll"
  let bin_path = "/tmp/gleamc-test/actor"
  let assert Ok(_) = ffi.write_file(ll_path, ll)
  let cmd =
    toolchain.build_command(
      toolchain.default_cc(),
      toolchain.Debug,
      [ll_path, "runtime/gleam_runtime.c"],
      ["runtime"],
      bin_path,
    )
  let #(compile_status, compile_out) = toolchain.run_shell(cmd)
  assert compile_status == 0 as compile_out
  let #(run_status, output) = toolchain.run_shell(bin_path)
  assert run_status == 0 as output
  assert string.contains(output, "stack ok") as output
  assert string.contains(output, "initfailed ok") as output
  assert string.contains(output, "named ok") as output
}
