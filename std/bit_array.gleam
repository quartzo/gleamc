pub fn to_string(bits: BitArray) -> Result(String, Nil) {
  Ok(bit_array.raw_to_string(bits))
}

pub fn concat(bit_arrays: List(BitArray)) -> BitArray {
  case bit_arrays {
    [] -> <<>>
    [first, ..rest] ->
      case rest {
        [] -> first
        _ -> bit_array.append(first, concat(rest))
      }
  }
}
