import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Mirrors the `simplifile` package FileError type. The compiler maps the
/// positive errno returned by the `fs.*` builtins through `from_code`.
pub type FileError {
  Eacces
  Eagain
  Ebadf
  Ebadmsg
  Ebusy
  Edeadlk
  Edeadlock
  Edquot
  Eexist
  Efault
  Efbig
  Eftype
  Eintr
  Einval
  Eio
  Eisdir
  Eloop
  Emfile
  Emlink
  Emultihop
  Enametoolong
  Enfile
  Enobufs
  Enodev
  Enolck
  Enolink
  Enoent
  Enomem
  Enospc
  Enosr
  Enostr
  Enosys
  Enotblk
  Enotdir
  Enotsup
  Enxio
  Eopnotsupp
  Eoverflow
  Eperm
  Epipe
  Erange
  Erofs
  Espipe
  Esrch
  Estale
  Etxtbsy
  Exdev
  NotUtf8
  Unknown(inner: String)
}

/// An enumeration of different types of files.
pub type FileType {
  File
  Directory
  Symlink
  Other
}

/// File metadata, matching the `simplifile` FileInfo record.
pub type FileInfo {
  FileInfo(
    size: Int,
    mode: Int,
    nlinks: Int,
    inode: Int,
    user_id: Int,
    group_id: Int,
    dev: Int,
    atime_seconds: Int,
    mtime_seconds: Int,
    ctime_seconds: Int,
  )
}

fn from_code(code: Int) -> FileError {
  case code {
    1 -> Eperm
    2 -> Enoent
    3 -> Esrch
    4 -> Eintr
    5 -> Eio
    6 -> Enxio
    9 -> Ebadf
    11 -> Eagain
    12 -> Enomem
    13 -> Eacces
    14 -> Efault
    15 -> Enotblk
    16 -> Ebusy
    17 -> Eexist
    18 -> Exdev
    19 -> Enodev
    20 -> Enotdir
    21 -> Eisdir
    22 -> Einval
    23 -> Enfile
    24 -> Emfile
    26 -> Etxtbsy
    27 -> Efbig
    28 -> Enospc
    29 -> Espipe
    30 -> Erofs
    31 -> Emlink
    32 -> Epipe
    34 -> Erange
    35 -> Edeadlk
    36 -> Enametoolong
    37 -> Enolck
    38 -> Enosys
    40 -> Eloop
    60 -> Enostr
    63 -> Enosr
    67 -> Enolink
    72 -> Emultihop
    74 -> Ebadmsg
    75 -> Eoverflow
    79 -> Eftype
    95 -> Enotsup
    105 -> Enobufs
    116 -> Estale
    122 -> Edquot
    _ -> Unknown(inner: int.to_string(code))
  }
}

fn read_result(result: FileResult) -> Result(BitArray, FileError) {
  case fs.result_code(result) {
    0 -> Ok(fs.result_data(result))
    code -> Error(from_code(code))
  }
}

fn write_result(result: FileResult) -> Result(Nil, FileError) {
  case fs.result_code(result) {
    0 -> Ok(Nil)
    code -> Error(from_code(code))
  }
}

fn bool_result(result: FileResult) -> Result(Bool, FileError) {
  case fs.result_code(result) {
    0 -> Ok(fs.result_size(result) == 1)
    2 -> Ok(False)
    code -> Error(from_code(code))
  }
}

pub fn read(from: String) -> Result(String, FileError) {
  use bits <- result.try(read_bits(from: from))
  case bit_array.is_utf8(bits) {
    True -> Ok(bit_array.raw_to_string(bits))
    False -> Error(NotUtf8)
  }
}

pub fn read_bits(from: String) -> Result(BitArray, FileError) {
  read_result(fs.read(from))
}

pub fn write(to: String, contents: String) -> Result(Nil, FileError) {
  write_bits(to: to, bits: bit_array.from_string(contents))
}

pub fn write_bits(to: String, bits: BitArray) -> Result(Nil, FileError) {
  write_result(fs.write(to, bits))
}

pub fn append(to: String, contents: String) -> Result(Nil, FileError) {
  append_bits(to: to, bits: bit_array.from_string(contents))
}

pub fn append_bits(to: String, bits: BitArray) -> Result(Nil, FileError) {
  write_result(fs.append(to, bits))
}

pub fn delete(file_or_dir_at: String) -> Result(Nil, FileError) {
  write_result(fs.delete(file_or_dir_at))
}

pub fn delete_file(at: String) -> Result(Nil, FileError) {
  write_result(fs.delete(at))
}

pub fn create_directory(filepath: String) -> Result(Nil, FileError) {
  write_result(fs.create_directory(filepath))
}

pub fn create_file(at: String) -> Result(Nil, FileError) {
  write_result(fs.create_file(at))
}

pub fn exists(filepath: String, follow_links: Bool) -> Result(Bool, FileError) {
  case fs.result_code(fs.exists(filepath)) {
    0 -> Ok(True)
    2 -> Ok(False)
    code -> Error(from_code(code))
  }
}

pub fn is_file(filepath: String) -> Result(Bool, FileError) {
  bool_result(fs.is_file(filepath))
}

pub fn is_directory(filepath: String) -> Result(Bool, FileError) {
  bool_result(fs.is_directory(filepath))
}

pub fn file_info(filepath: String) -> Result(FileInfo, FileError) {
  use blob <- result.try(read_result(fs.file_info(filepath)))
  Ok(decode_file_info(blob))
}

pub fn link_info(filepath: String) -> Result(FileInfo, FileError) {
  use blob <- result.try(read_result(fs.link_info(filepath)))
  Ok(decode_file_info(blob))
}

fn decode_file_info(blob: BitArray) -> FileInfo {
  FileInfo(
    size: fs.int64_at(blob, 0),
    mode: fs.int64_at(blob, 1),
    nlinks: fs.int64_at(blob, 2),
    inode: fs.int64_at(blob, 3),
    user_id: fs.int64_at(blob, 4),
    group_id: fs.int64_at(blob, 5),
    dev: fs.int64_at(blob, 6),
    atime_seconds: fs.int64_at(blob, 7),
    mtime_seconds: fs.int64_at(blob, 8),
    ctime_seconds: fs.int64_at(blob, 9),
  )
}

/// Extracts the file type from a `FileInfo` value.
pub fn file_info_type(from: FileInfo) -> FileType {
  let mode = from.mode
  // mode >> 12 is the POSIX file type (S_IFMT): regular 8, dir 4, link 10.
  case mode / 4096 {
    8 -> File
    4 -> Directory
    10 -> Symlink
    _ -> Other
  }
}

/// Extracts the permission bits (octal representation) from a `FileInfo`.
pub fn file_info_permissions_octal(from: FileInfo) -> Int {
  from.mode % 4096
}

pub fn read_directory(at: String) -> Result(List(String), FileError) {
  use blob <- result.try(read_result(fs.read_directory(at)))
  case bit_array.raw_to_string(blob) {
    "" -> Ok([])
    text -> Ok(string.split(text, "/"))
  }
}

pub fn get_files(in: String) -> Result(List(String), FileError) {
  use names <- result.try(read_directory(at: in))
  get_files_loop(in, names)
}

fn get_files_loop(
  directory: String,
  names: List(String),
) -> Result(List(String), FileError) {
  case names {
    [] -> Ok([])
    [name, ..rest] -> {
      let path = join(directory, name)
      case get_files_loop(directory, rest) {
        Error(err) -> Error(err)
        Ok(tail) ->
          case is_directory(path) {
            Error(err) -> Error(err)
            Ok(True) ->
              case get_files(in: path) {
                Error(err) -> Error(err)
                Ok(nested) -> Ok(list.append(nested, tail))
              }
            Ok(False) -> Ok([path, ..tail])
          }
      }
    }
  }
}

fn join(directory: String, name: String) -> String {
  case string.ends_with(directory, "/") {
    True -> directory <> name
    False -> directory <> "/" <> name
  }
}

pub fn current_directory() -> Result(String, FileError) {
  use bits <- result.try(read_result(fs.current_directory()))
  Ok(bit_array.raw_to_string(bits))
}

pub fn describe_error(error: FileError) -> String {
  case error {
    Eacces -> "Permission denied."
    Eagain -> "Resource temporarily unavailable."
    Ebadf -> "Bad file number."
    Ebadmsg -> "Bad message."
    Ebusy -> "File busy."
    Edeadlk -> "Resource deadlock avoided."
    Edeadlock -> "Resource deadlock avoided."
    Edquot -> "Disk quota exceeded."
    Eexist -> "File already exists."
    Efault -> "Bad address in system call argument."
    Efbig -> "File too large."
    Eftype -> "Inappropriate file type or format."
    Eintr -> "Interrupted system call."
    Einval -> "Invalid argument."
    Eio -> "Input/output error."
    Eisdir -> "Illegal operation on a directory."
    Eloop -> "Too many levels of symbolic links."
    Emfile -> "Too many open files."
    Emlink -> "Too many links."
    Emultihop -> "Multihop attempted."
    Enametoolong -> "Filename too long."
    Enfile -> "File table overflow."
    Enobufs -> "No buffer space available."
    Enodev -> "No such device."
    Enolck -> "No locks available."
    Enolink -> "Link has been severed."
    Enoent -> "No such file or directory."
    Enomem -> "Not enough memory."
    Enospc -> "No space left on device."
    Enosr -> "No STREAM resources."
    Enostr -> "Not a STREAM."
    Enosys -> "Function not implemented."
    Enotblk -> "Block device required."
    Enotdir -> "Not a directory."
    Enotsup -> "Operation not supported."
    Enxio -> "No such device or address."
    Eopnotsupp -> "Operation not supported on socket."
    Eoverflow -> "Value too large to be stored in data type."
    Eperm -> "Not owner."
    Epipe -> "Broken pipe."
    Erange -> "Result too large."
    Erofs -> "Read-only file system."
    Espipe -> "Invalid seek."
    Esrch -> "No such process."
    Estale -> "Stale remote file handle."
    Etxtbsy -> "Text file busy."
    Exdev -> "Cross-domain link."
    NotUtf8 -> "File was requested to be read as UTF-8, but is not UTF-8."
    Unknown(inner) -> inner
  }
}
