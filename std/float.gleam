pub fn power(base: Float, exponent: Float) -> Result(Float, Nil) {
  Ok(float.raw_power(base, exponent))
}

pub fn square_root(value: Float) -> Result(Float, Nil) {
  Ok(float.raw_square_root(value))
}
