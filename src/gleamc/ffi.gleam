//// Bindings for the Erlang shim (`gleamc_ffi.erl`).
////
//// Isolates all contact with the OS. The rest of the compiler only uses
//// these functions — switching target (Erlang/JS) stays confined to this
//// module.

/// Runs a command in the shell and returns `#(exit_status, output)`.
/// Output includes stderr (stderr_to_stdout).
@external(erlang, "gleamc_ffi", "run")
pub fn run(command: String) -> #(Int, String)

/// Reads a file as UTF-8 text.
@external(erlang, "gleamc_ffi", "read_file")
pub fn read_file(path: String) -> Result(String, String)

/// Writes UTF-8 text to a file (creates/overwrites).
@external(erlang, "gleamc_ffi", "write_file")
pub fn write_file(path: String, contents: String) -> Result(Nil, String)

/// Resolves an executable on the PATH.
@external(erlang, "gleamc_ffi", "which")
pub fn which(name: String) -> Result(String, Nil)

/// Reads an environment variable.
@external(erlang, "gleamc_ffi", "get_env")
pub fn get_env(name: String) -> Result(String, Nil)

/// Command-line arguments.
@external(erlang, "gleamc_ffi", "argv")
pub fn argv() -> List(String)
