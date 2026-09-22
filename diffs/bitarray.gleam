import gleam/bit_array
import gleam/int
import gleam/io
import gleam/result

fn sum_bytes(data: BitArray) -> Int {
  case data {
    <<a, b, c>> -> a + b + c
    _ -> 0
  }
}

pub fn main() {
  io.println(result.unwrap(bit_array.to_string(<<104, 105>>), "err"))
  io.println(int.to_string(bit_array.byte_size(<<1, 2, 3>>)))
  io.println(result.unwrap(
    bit_array.to_string(bit_array.from_string("hi")),
    "err",
  ))
  io.println(result.unwrap(
    bit_array.to_string(bit_array.concat([<<104>>, <<105>>])),
    "err",
  ))
  io.println(int.to_string(sum_bytes(<<1, 2, 3>>)))
  io.println(int.to_string(sum_bytes(<<1, 2>>)))
}
