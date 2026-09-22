import gleam/int
import gleam/io
import gleam/list
import gleam/string

fn str(cps: List(Int)) -> String {
  string.from_utf_codepoints(
    list.map(cps, fn(i) {
      let assert Ok(c) = string.utf_codepoint(i)
      c
    }),
  )
}

pub fn main() {
  let e_accent = str([101, 769])
  io.println(int.to_string(string.length(e_accent)))
  let flag = str([127_987, 65_039, 8205, 127_752])
  io.println(int.to_string(string.length(flag)))
  io.println(int.to_string(string.reverse(e_accent) |> string.length))
  io.println(int.to_string(list.length(string.to_graphemes(flag))))
  io.println(string.uppercase(str([99, 97, 102, 233])))
  io.println(string.uppercase(str([223])))
  io.println(string.lowercase(str([65, 201])))
}
