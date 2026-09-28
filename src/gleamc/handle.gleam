//// Single source of truth for opaque runtime handles.
////
//// A handle is a type whose runtime representation and ownership discipline
//// are decided by the compiler (not by its Gleam definition): a process id, a
//// task/future, a buffer, an environment pointer, and so on. Historically each
//// consumer (`llvm_ty`, `abi`, `ownership_plan`, ...) re-derived those facts by
//// pattern-matching the type name, which drifted. This module centralises the
//// classification so every consumer agrees and a new handle is declared once.
////
//// `Kind` is the ownership discipline: `Copy` values are freely duplicated and
//// never dropped, `Resource` values are refcounted and affine (the ownership
//// pass inserts retain/release), and `Borrow` pointers are never owned.
//// `Drop` says *who* releases a `Resource` (the ownership pass, or the runtime /
//// await machinery explicitly).

import gleam/option.{type Option, None, Some}
import gleam/string

/// How a handle value is represented in a register.
pub type Rep {
  /// An opaque pointer (`i8*`).
  Ptr
  /// A word-sized integer (`i64`).
  Word
}

/// The ownership discipline of a handle.
pub type Kind {
  /// A plain value, freely copied, never dropped (`Pid`, `Monitor`, ...).
  Copy
  /// A refcounted resource: affine, released by the ownership pass.
  Resource
  /// A borrowed pointer: not owned, never released (`void*`, the closure env).
  Borrow
}

/// Who releases a `Resource` value.
pub type Drop {
  NoDrop
  /// The ownership pass emits `gleamc_release` at end of life.
  Release
  /// The runtime / await machinery releases it explicitly, outside ownership
  /// (the `Future` handle).
  Runtime
}

pub type Info {
  Info(kind: Kind, rep: Rep, drop: Drop, user_visible: Bool)
}

/// The name prefix of a machine frame type (`__frame_<fn>`). Frames are internal
/// state cells, not user handles; their struct type is backend-internal.
pub const frame_prefix = "__frame_"

/// The descriptor of a nullary handle name, if it names one.
pub fn nullary(name: String) -> Option(Info) {
  case name {
    // Closure/async environment pointer: borrowed, never owned.
    "void*" -> Some(Info(Borrow, Ptr, NoDrop, False))
    // Internal async handle (`GleamcFuture*`); the await machinery releases it.
    "Future" -> Some(Info(Resource, Ptr, Runtime, False))
    // Async I/O file descriptor, an opaque scalar.
    "Handle" -> Some(Info(Copy, Word, NoDrop, False))
    // A boxed dynamic value (`GleamcDynamic*`), refcounted.
    "Dynamic" -> Some(Info(Resource, Ptr, Release, True))
    // A refcounted selector handle.
    "SelectorHandle" -> Some(Info(Resource, Word, Release, False))
    "Pid" -> Some(Info(Copy, Word, NoDrop, True))
    "Monitor" -> Some(Info(Copy, Word, NoDrop, True))
    "Timer" -> Some(Info(Copy, Word, NoDrop, True))
    "Selector" -> Some(Info(Copy, Word, NoDrop, True))
    "Name" -> Some(Info(Copy, Word, NoDrop, True))
    _ -> None
  }
}

/// The descriptor of a parameterised handle name (`Buffer(a)`, `Task(a)`, ...).
pub fn templated(name: String) -> Option(Info) {
  case name {
    "Buffer" -> Some(Info(Resource, Ptr, Release, True))
    "Subject" -> Some(Info(Resource, Word, Release, True))
    "Task" -> Some(Info(Resource, Ptr, Release, True))
    "Timer" -> Some(Info(Copy, Word, NoDrop, True))
    "Selector" -> Some(Info(Copy, Word, NoDrop, True))
    "Name" -> Some(Info(Copy, Word, NoDrop, True))
    _ -> None
  }
}

/// The descriptor of a handle name after monomorphisation (`Buffer(Int)` becomes
/// `TNamed("Buffer_Int")`).
pub fn of_name(name: String) -> Option(Info) {
  case nullary(name) {
    Some(info) -> Some(info)
    None ->
      case monomorphised(name) {
        Some(info) -> Some(info)
        None -> templated(name)
      }
  }
}

fn monomorphised(name: String) -> Option(Info) {
  case string.starts_with(name, "Buffer_") {
    True -> templated("Buffer")
    False ->
      case string.starts_with(name, "Subject_") {
        True -> templated("Subject")
        False ->
          case string.starts_with(name, "Task_") {
            True -> templated("Task")
            False ->
              case string.starts_with(name, "Selector_") {
                True -> templated("Selector")
                False ->
                  case string.starts_with(name, "Name_") {
                    True -> templated("Name")
                    False -> None
                  }
              }
          }
      }
  }
}

/// The LLVM register type of a handle representation.
pub fn rep_llvm(rep: Rep) -> String {
  case rep {
    Ptr -> "i8*"
    Word -> "i64"
  }
}

/// Whether `name` is an opaque handle (as opposed to a user type or a built-in
/// aggregate like `BitArray`).
pub fn is_opaque(name: String) -> Bool {
  case of_name(name) {
    Some(_) -> True
    None -> False
  }
}

/// Whether a value of this handle needs a drop call (a released resource).
pub fn needs_release(info: Info) -> Bool {
  let Info(kind: kind, drop: drop, ..) = info
  kind == Resource && drop == Release
}
