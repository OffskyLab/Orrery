import Foundation

#if os(macOS)
import Darwin

/// Resolves the absolute path of the currently-running executable.
///
/// `CommandLine.arguments[0]` is NOT usable for this: when a shell finds a
/// command via `$PATH` (including via the `command` builtin — how every
/// internal orrery subcommand is invoked from the generated shell function),
/// POSIX shells set `argv[0]` to the typed command name ("orrery-bin"), not
/// the resolved path. Joining that against the current working directory
/// (the previous approach here) silently resolves to a path that doesn't
/// exist for any real invocation, making every caller fail closed with no
/// error — which is how the account-add auto-finalize hook and the
/// `_prepare-claude-launch` self-heal hook both went unnoticed as no-ops.
/// `_NSGetExecutablePath` asks the OS directly for the path used to launch
/// this process, independent of `argv[0]` or the working directory.
public enum RunningExecutablePath {
    public static func resolved() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [Int8](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let path = String(cString: buffer)
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return FileManager.default.fileExists(atPath: resolved) ? resolved : nil
    }
}
#endif
