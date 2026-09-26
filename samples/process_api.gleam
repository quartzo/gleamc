import gleam/erlang/process
import gleam/int
import gleam/io

fn int_subject() -> Subject(Int) {
  process.new_subject()
}

pub fn main() {
  let subject = int_subject()
  process.send(subject, 42)
  process.send(subject, 7)

  let first = process.receive_forever(from: subject)
  io.println(int.to_string(first))

  case process.receive(from: subject, within: 100) {
    Ok(second) -> io.println(int.to_string(second))
    Error(_) -> io.println("timeout")
  }

  process.sleep(1)
  io.println("done")
}
