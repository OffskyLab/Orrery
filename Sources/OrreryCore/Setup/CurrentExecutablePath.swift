import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The absolute path to the currently-running executable, resolved
/// independent of how it was invoked — bare command name via `$PATH` (the
/// normal case: the `orrery` shell wrapper's `command orrery-bin ...`, and
/// `install.sh`'s `"$BINARY_NAME" setup`), a relative path, or an absolute
/// path.
///
/// `CommandLine.arguments[0]` is NOT reliable for this: a shell resolving a
/// command via `$PATH` execs the real absolute path but passes the literal
/// typed word as `argv[0]` — so `orrery-bin` invoked the normal way has
/// `argv[0] == "orrery-bin"` with no path info at all. Naively treating that
/// as relative to the current working directory (the previous approach in
/// both `TokenRefreshDaemonInstaller` and `LinuxAgentInstaller`) silently
/// pointed at the wrong file whenever CWD wasn't the install directory —
/// which is the common case — so the sibling `orrery-agent` binary lookup
/// failed and the background token-refresh agent never registered.
func currentExecutablePath() -> String? {
    #if os(Linux)
    // /proc/self/exe is a magic symlink the kernel always resolves to the
    // actual running binary's absolute path, regardless of argv[0].
    return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
    #elseif os(macOS)
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [Int8](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buf, &size) == 0 else { return nil }
    return buf.withUnsafeBufferPointer { ptr in
        URL(fileURLWithPath: String(cString: ptr.baseAddress!)).standardizedFileURL.path
    }
    #else
    return nil
    #endif
}
