import gleam/float
import gleam/io
import gleam/result

fn p(s: String) {
  io.println(
    s <> " => " <> float.to_string(result.unwrap(float.parse(s), -1.0)),
  )
}

pub fn main() {
  p("1.5")
  p("1")
  p("-2.0")
  p("1e3")
  p("1.5e-2")
  p("0.25")
  p("-0.5")
  p("abc")
  p("1.0e3")
  p("1.5E2")
  p("1.")
  p(".5")
  p("+1.5")
  p("01.5")
  p("1.5.5")
  p("1.0e")
}
