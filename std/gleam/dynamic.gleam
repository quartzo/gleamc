//// Dynamic values: a value of any type with a runtime class tag, mirroring a
//// subset of `gleam/dynamic`. `Dynamic` is a compiler-known opaque type (like
//// `Pid`); it is built on the `dynamic_ffi.*` builtins.

/// The class of an `Int`.
pub const int_class = 0
/// The class of a `Float`.
pub const float_class = 1
/// The class of a `String`.
pub const string_class = 2
/// The class of a `Bool`.
pub const bool_class = 3
/// The class of `Nil`.
pub const nil_class = 4
/// The class of a `List`.
pub const list_class = 5
/// The class of a tuple.
pub const tuple_class = 6
/// The class of a `BitArray`.
pub const bit_array_class = 7
/// The class of a function.
pub const function_class = 8
/// The class of anything else (a custom type, an opaque handle, ...).
pub const other_class = 9

/// Turn any value into a `Dynamic`, tagging it with its class.
pub fn from(a: a) -> Dynamic {
  dynamic_ffi.from(a)
}

/// Unsafely reinterpret a `Dynamic` as a value of any type.
pub fn unsafe_coerce(a: Dynamic) -> b {
  dynamic_ffi.unsafe_coerce(a)
}

/// The class of a `Dynamic` value; compare to the `*_class` constants.
pub fn classify(a: Dynamic) -> Int {
  dynamic_ffi.classify(a)
}

/// Read a `Dynamic` as an `Int`, if it holds one.
pub fn int(a: Dynamic) -> Result(Int, Nil) {
  case dynamic_ffi.classify(a) == int_class {
    True -> Ok(dynamic_ffi.as_int(a))
    False -> Error(Nil)
  }
}

/// Read a `Dynamic` as a `Float`, if it holds one.
pub fn float(a: Dynamic) -> Result(Float, Nil) {
  case dynamic_ffi.classify(a) == float_class {
    True -> Ok(dynamic_ffi.as_float(a))
    False -> Error(Nil)
  }
}

/// Read a `Dynamic` as a `String`, if it holds one.
pub fn string(a: Dynamic) -> Result(String, Nil) {
  case dynamic_ffi.classify(a) == string_class {
    True -> Ok(dynamic_ffi.as_string(a))
    False -> Error(Nil)
  }
}

/// Read a `Dynamic` as a `Bool`, if it holds one.
pub fn bool(a: Dynamic) -> Result(Bool, Nil) {
  case dynamic_ffi.classify(a) == bool_class {
    True -> Ok(dynamic_ffi.as_bool(a))
    False -> Error(Nil)
  }
}
