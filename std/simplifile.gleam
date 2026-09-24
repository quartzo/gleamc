import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/set
import gleam/string

/// Mirrors the `simplifile` package FileError type. The compiler maps the
/// negative errno returned by the async `uv.*` builtins through `from_code`.
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

/// Represents a file permission.
pub type Permission {
  Read
  Write
  Execute
}

/// A set of file permissions, matching the `simplifile` FilePermissions record.
pub type FilePermissions {
  FilePermissions(
    user: set.Set(Permission),
    group: set.Set(Permission),
    other: set.Set(Permission),
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

/// Maps a negative errno returned by the async `uv.*` surface to a FileError.
fn error_of(code: Int) -> FileError {
  from_code(0 - code)
}

/// A `uv.*` status call: `0` on success, negative errno on failure.
fn code_result(code: Int) -> Result(Nil, FileError) {
  case code < 0 {
    True -> Error(error_of(code))
    False -> Ok(Nil)
  }
}

// POSIX open flags (see `fcntl.h`).
const o_rdonly = 0
const o_wronly = 1
const o_creat = 64
const o_trunc = 512
const o_append = 1024

pub fn read(from: String) -> Result(String, FileError) {
  use bits <- result.try(read_bits(from: from))
  case bit_array.is_utf8(bits) {
    True -> Ok(bit_array.raw_to_string(bits))
    False -> Error(NotUtf8)
  }
}

/// Reads a whole file over the async loop (open → fstat → read → close).
/// Every step suspends the caller; the caller sees the bytes.
pub fn read_bits(from: String) -> Result(BitArray, FileError) {
  let fd = uv.fs_open(from, o_rdonly, 0)
  case fd < 0 {
    True -> Error(error_of(fd))
    False -> {
      let size = uv.fs_fstat(fd)
      case size < 0 {
        True -> {
          let _ = uv.fs_close(fd)
          Error(error_of(size))
        }
        False -> {
          let bits = uv.fs_read(fd, size)
          let _ = uv.fs_close(fd)
          Ok(bits)
        }
      }
    }
  }
}

fn write_flags(to: String, bits: BitArray, flags: Int) -> Result(Nil, FileError) {
  let fd = uv.fs_open(to, flags, 420)
  case fd < 0 {
    True -> Error(error_of(fd))
    False -> {
      let code = uv.fs_write(fd, bits)
      let _ = uv.fs_close(fd)
      case code < 0 {
        True -> Error(error_of(code))
        False -> Ok(Nil)
      }
    }
  }
}

pub fn write(to: String, contents: String) -> Result(Nil, FileError) {
  write_bits(to: to, bits: bit_array.from_string(contents))
}

pub fn write_bits(to: String, bits: BitArray) -> Result(Nil, FileError) {
  write_flags(to, bits, o_wronly + o_creat + o_trunc)
}

pub fn append(to: String, contents: String) -> Result(Nil, FileError) {
  append_bits(to: to, bits: bit_array.from_string(contents))
}

pub fn append_bits(to: String, bits: BitArray) -> Result(Nil, FileError) {
  write_flags(to, bits, o_wronly + o_creat + o_append)
}

pub fn delete(file_or_dir_at: String) -> Result(Nil, FileError) {
  case is_directory(file_or_dir_at) {
    Error(err) -> Error(err)
    Ok(True) -> remove_tree(file_or_dir_at)
    Ok(False) -> code_result(uv.fs_unlink(file_or_dir_at))
  }
}

fn remove_tree(path: String) -> Result(Nil, FileError) {
  case read_directory(at: path) {
    Error(err) -> Error(err)
    Ok(names) ->
      case remove_entries(path, names) {
        Error(err) -> Error(err)
        Ok(Nil) -> code_result(uv.fs_rmdir(path))
      }
  }
}

fn remove_entries(
  directory: String,
  names: List(String),
) -> Result(Nil, FileError) {
  case names {
    [] -> Ok(Nil)
    [name, ..rest] ->
      case delete(join(directory, name)) {
        Error(err) -> Error(err)
        Ok(Nil) -> remove_entries(directory, rest)
      }
  }
}

pub fn delete_all(paths: List(String)) -> Result(Nil, FileError) {
  case paths {
    [] -> Ok(Nil)
    [path, ..rest] ->
      case delete(path) {
        Ok(_) -> delete_all(rest)
        Error(Enoent) -> delete_all(rest)
        Error(err) -> Error(err)
      }
  }
}

pub fn clear_directory(at: String) -> Result(Nil, FileError) {
  case read_directory(at: at) {
    Error(err) -> Error(err)
    Ok(names) -> remove_entries(at, names)
  }
}

pub fn rename(at: String, to: String) -> Result(Nil, FileError) {
  code_result(uv.fs_rename(at, to))
}

pub fn rename_file(at: String, to: String) -> Result(Nil, FileError) {
  rename(at: at, to: to)
}

pub fn rename_directory(at: String, to: String) -> Result(Nil, FileError) {
  rename(at: at, to: to)
}

pub fn copy_file(at: String, to: String) -> Result(Nil, FileError) {
  case read_bits(from: at) {
    Error(err) -> Error(err)
    Ok(bits) -> write_bits(to: to, bits: bits)
  }
}

pub fn create_symlink(to: String, from: String) -> Result(Nil, FileError) {
  code_result(uv.fs_symlink(to, from))
}

pub fn create_link(to: String, from: String) -> Result(Nil, FileError) {
  code_result(uv.fs_link(to, from))
}

pub fn touch(at: String) -> Result(Nil, FileError) {
  code_result(touch_file(at))
}

pub fn resolve(path: String) -> Result(String, FileError) {
  let bits = uv.fs_realpath(path)
  case bit_array.byte_size(bits) {
    0 -> Error(Enoent)
    _ -> Ok(bit_array.raw_to_string(bits))
  }
}

pub fn copy(src: String, dest: String) -> Result(Nil, FileError) {
  case is_directory(src) {
    Error(err) -> Error(err)
    Ok(True) -> copy_directory(at: src, to: dest)
    Ok(False) -> copy_file(at: src, to: dest)
  }
}

pub fn copy_directory(at: String, to: String) -> Result(Nil, FileError) {
  case create_directory(to) {
    Ok(_) -> copy_children(at, to)
    Error(Eexist) -> copy_children(at, to)
    Error(err) -> Error(err)
  }
}

fn copy_children(from_dir: String, to_dir: String) -> Result(Nil, FileError) {
  case read_directory(at: from_dir) {
    Error(err) -> Error(err)
    Ok(names) -> copy_entries(from_dir, to_dir, names)
  }
}

fn copy_entries(
  from_dir: String,
  to_dir: String,
  names: List(String),
) -> Result(Nil, FileError) {
  case names {
    [] -> Ok(Nil)
    [name, ..rest] -> {
      let src = join(from_dir, name)
      let dest = join(to_dir, name)
      case is_directory(src) {
        Error(err) -> Error(err)
        Ok(True) ->
          case copy_directory(at: src, to: dest) {
            Error(err) -> Error(err)
            Ok(Nil) -> copy_entries(from_dir, to_dir, rest)
          }
        Ok(False) ->
          case copy_file(at: src, to: dest) {
            Error(err) -> Error(err)
            Ok(Nil) -> copy_entries(from_dir, to_dir, rest)
          }
      }
    }
  }
}

pub fn delete_file(at: String) -> Result(Nil, FileError) {
  code_result(uv.fs_unlink(at))
}

pub fn create_directory(filepath: String) -> Result(Nil, FileError) {
  code_result(uv.fs_mkdir(filepath, 493))
}

/// Creates the file if missing, without truncating an existing one.
fn create_empty_file(at: String) -> Int {
  let fd = uv.fs_open(at, o_wronly + o_creat, 420)
  case fd < 0 {
    True -> fd
    False -> uv.fs_close(fd)
  }
}

/// Updates the timestamp (or creates the file); opening is enough for the
/// operations `simplifile` needs.
fn touch_file(at: String) -> Int {
  create_empty_file(at)
}

pub fn create_directory_all(dirpath: String) -> Result(Nil, FileError) {
  let parts = string.split(dirpath, "/")
  let prefix = case string.starts_with(dirpath, "/") {
    True -> "/"
    False -> ""
  }
  mkdir_parts(parts, prefix)
}

fn mkdir_parts(parts: List(String), prefix: String) -> Result(Nil, FileError) {
  case parts {
    [] -> Ok(Nil)
    [part, ..rest] -> {
      let next = case part {
        "" -> prefix
        _ -> join_sep(prefix, part)
      }
      case mkdir_ignore_exists(next) {
        Error(err) -> Error(err)
        Ok(Nil) -> mkdir_parts(rest, next)
      }
    }
  }
}

fn join_sep(prefix: String, part: String) -> String {
  case prefix {
    "" -> part
    "/" -> "/" <> part
    _ -> prefix <> "/" <> part
  }
}

fn mkdir_ignore_exists(path: String) -> Result(Nil, FileError) {
  case create_directory(path) {
    Ok(Nil) -> Ok(Nil)
    Error(Eexist) -> Ok(Nil)
    Error(err) -> Error(err)
  }
}

pub fn create_file(at: String) -> Result(Nil, FileError) {
  code_result(create_empty_file(at))
}

/// `stat` (follow) or `lstat` (no follow) over the async loop; the blob is
/// empty when the path does not exist / the call failed.
fn stat_blob(filepath: String, follow_links: Bool) -> BitArray {
  uv.fs_stat(filepath, case follow_links {
    True -> 1
    False -> 0
  })
}

pub fn exists(filepath: String, follow_links: Bool) -> Result(Bool, FileError) {
  Ok(bit_array.byte_size(stat_blob(filepath, follow_links)) > 0)
}

pub fn is_file(filepath: String) -> Result(Bool, FileError) {
  let blob = stat_blob(filepath, True)
  case bit_array.byte_size(blob) > 0 {
    True -> Ok(file_info_type(decode_file_info(blob)) == File)
    False -> Ok(False)
  }
}

pub fn is_directory(filepath: String) -> Result(Bool, FileError) {
  let blob = stat_blob(filepath, True)
  case bit_array.byte_size(blob) > 0 {
    True -> Ok(file_info_type(decode_file_info(blob)) == Directory)
    False -> Ok(False)
  }
}

pub fn is_symlink(filepath: String) -> Result(Bool, FileError) {
  let blob = stat_blob(filepath, False)
  case bit_array.byte_size(blob) > 0 {
    True -> Ok(file_info_type(decode_file_info(blob)) == Symlink)
    False -> Ok(False)
  }
}

pub fn file_info(filepath: String) -> Result(FileInfo, FileError) {
  let blob = stat_blob(filepath, True)
  case bit_array.byte_size(blob) {
    0 -> Error(Enoent)
    _ -> Ok(decode_file_info(blob))
  }
}

pub fn link_info(filepath: String) -> Result(FileInfo, FileError) {
  let blob = stat_blob(filepath, False)
  case bit_array.byte_size(blob) {
    0 -> Error(Enoent)
    _ -> Ok(decode_file_info(blob))
  }
}

fn decode_file_info(blob: BitArray) -> FileInfo {
  FileInfo(
    size: bit_array.int64_at(blob, 0),
    mode: bit_array.int64_at(blob, 1),
    nlinks: bit_array.int64_at(blob, 2),
    inode: bit_array.int64_at(blob, 3),
    user_id: bit_array.int64_at(blob, 4),
    group_id: bit_array.int64_at(blob, 5),
    dev: bit_array.int64_at(blob, 6),
    atime_seconds: bit_array.int64_at(blob, 7),
    mtime_seconds: bit_array.int64_at(blob, 8),
    ctime_seconds: bit_array.int64_at(blob, 9),
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

/// Extracts the `FilePermissions` from a `FileInfo` value.
pub fn file_info_permissions(from: FileInfo) -> FilePermissions {
  let mode = from.mode
  FilePermissions(
    user: bits_to_permissions(mode / 64 % 8),
    group: bits_to_permissions(mode / 8 % 8),
    other: bits_to_permissions(mode % 8),
  )
}

fn bits_to_permissions(bits: Int) -> set.Set(Permission) {
  let read = case bits >= 4 {
    True -> [Read]
    False -> []
  }
  let rest = bits % 4
  let write = case rest >= 2 {
    True -> [Write]
    False -> []
  }
  let execute = case rest % 2 {
    1 -> [Execute]
    _ -> []
  }
  set.from_list(list.append(read, list.append(write, execute)))
}

pub fn file_permissions_to_octal(permissions: FilePermissions) -> Int {
  permissions_octal(permissions.user)
  * 64
  + permissions_octal(permissions.group)
  * 8
  + permissions_octal(permissions.other)
}

fn permissions_octal(perms: set.Set(Permission)) -> Int {
  let read = case set.contains(perms, Read) {
    True -> 4
    False -> 0
  }
  let write = case set.contains(perms, Write) {
    True -> 2
    False -> 0
  }
  let execute = case set.contains(perms, Execute) {
    True -> 1
    False -> 0
  }
  read + write + execute
}

pub fn set_permissions(
  for_file_at: String,
  to: FilePermissions,
) -> Result(Nil, FileError) {
  set_permissions_octal(
    for_file_at: for_file_at,
    to: file_permissions_to_octal(to),
  )
}

pub fn set_permissions_octal(
  for_file_at: String,
  to: Int,
) -> Result(Nil, FileError) {
  code_result(uv.fs_chmod(for_file_at, to))
}

pub fn read_directory(at: String) -> Result(List(String), FileError) {
  let blob = uv.fs_readdir(at)
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
      use tail <- result.try(get_files_loop(directory, rest))
      use is_dir <- result.try(is_directory(path))
      case is_dir {
        True -> {
          use nested <- result.try(get_files(in: path))
          Ok(list.append(nested, tail))
        }
        False -> Ok([path, ..tail])
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
  let bits = uv.fs_cwd()
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
