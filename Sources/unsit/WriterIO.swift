import Foundation
import Darwin

/// Per-call syscall adapter: tests inject precise failures without production
/// environment switches or global mutable hooks.
struct WriterIO {
    var create: (Int32, String) -> Int32 = { openat($0, $1, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644) }
    var write: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
    var xattr: (Int32, String, UnsafeRawPointer, Int, UInt32) -> Int32 = { fsetxattr($0, $1, $2, $3, $4, 0) }
    var times: (Int32, UnsafePointer<timeval>) -> Int32 = { futimes($0, $1) }
    var flush: (Int32) -> Int32 = { fsync($0) }
    var close: (Int32) -> Int32 = { Darwin.close($0) }
    var publish: (Int32, String, String) -> Int32 = { renameatx_np($0, $1, $0, $2, UInt32(RENAME_EXCL)) }
    var stage: (String) -> Void = { _ in }
}
