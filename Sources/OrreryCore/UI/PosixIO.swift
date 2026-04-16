/// Posix-based terminal I/O helpers.
///
/// `FileHandle.write(_:)` uses the ObjC `[NSFileHandle writeData:]` API which
/// raises `NSFileHandleOperationException` on write errors — an ObjC exception
/// that Swift cannot catch, causing a fatal crash.  These helpers use the posix
/// `write(2)` syscall directly: errors are returned as a negative value and
/// silently ignored, so the process never crashes on a transient write failure.
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Write a string to stdout (fd 1).
@discardableResult
func stdoutWrite(_ str: String) -> Int {
    var buf = Array(str.utf8)
    return write(STDOUT_FILENO, &buf, buf.count)
}

/// Write a string to stderr (fd 2).
@discardableResult
func stderrWrite(_ str: String) -> Int {
    var buf = Array(str.utf8)
    return write(STDERR_FILENO, &buf, buf.count)
}

/// Write a string to an arbitrary file descriptor.
@discardableResult
func fdWrite(_ fd: Int32, _ str: String) -> Int {
    var buf = Array(str.utf8)
    return write(fd, &buf, buf.count)
}
