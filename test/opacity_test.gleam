import gleam/string
import gleamc/ffi
import gleamc/loader
import gleamc/pipeline

const dir = "/tmp/gleamc-opacity"

const secret_source = "pub opaque type Secret {\n  Secret(value: Int)\n}\n\npub fn make(value: Int) -> Secret {\n  Secret(value)\n}\n\npub fn reveal(secret: Secret) -> Int {\n  case secret {\n    Secret(v) -> v\n  }\n}\n"

const ok_source = "import secret\n\npub fn main() -> Int {\n  secret.reveal(secret.make(7))\n}\n"

const bad_source = "import secret\n\npub fn main() -> Int {\n  case secret.make(1) {\n    secret.Secret(v) -> v\n  }\n}\n"

pub fn opaque_type_test() {
  let _ = ffi.run("mkdir -p " <> dir)
  let assert Ok(_) = ffi.write_file(dir <> "/secret.gleam", secret_source)

  let assert Ok(_) = ffi.write_file(dir <> "/ok.gleam", ok_source)
  let assert Ok(ok_modules) = loader.load(dir <> "/ok.gleam")
  let assert Ok(_) = pipeline.compile_modules_llvm(ok_modules)

  let assert Ok(_) = ffi.write_file(dir <> "/bad.gleam", bad_source)
  let assert Ok(bad_modules) = loader.load(dir <> "/bad.gleam")
  case pipeline.compile_modules_llvm(bad_modules) {
    Error(message) ->
      case string.contains(message, "opaque") {
        True -> Nil
        False -> panic as "expected an opaque constructor error"
      }
    Ok(_) -> panic as "expected an opaque constructor error"
  }
}
