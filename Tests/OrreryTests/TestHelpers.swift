import Foundation

/// Process-global lock serializing every test that mutates the global ORRERY_HOME
/// env var. swift-testing's `.serialized` only serializes within a single suite;
/// this lock serializes across ALL suites that touch ORRERY_HOME.
private let orreryHomeLock = NSLock()

/// Runs `body` with `ORRERY_HOME` pointed at a fresh temp directory.
/// Holds a process-global lock for the duration so concurrent suites cannot race.
/// Restores the previous ORRERY_HOME and deletes the temp dir afterwards.
///
/// `ORRERY_ACTIVE_ENV` is scrubbed for the duration too: a dev running the
/// suite from a shell that is "in" a sandbox would otherwise leak that name
/// into commands like `orrery show`, which read the active env from the
/// process environment. Restored afterwards.
func withIsolatedHome(_ body: () throws -> Void) rethrows {
    orreryHomeLock.lock()
    defer { orreryHomeLock.unlock() }

    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let savedHome = ProcessInfo.processInfo.environment["ORRERY_HOME"]
    let savedActiveEnv = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
    // ORRERY_USER_HOME is redirected too: `Tool.defaultConfigDir` (and other
    // home-relative paths) resolve via `userHomeURL()`, which honors it. Without
    // this a test that triggers origin-takeover code would symlink/write into the
    // developer's real ~/.claude even though ORRERY_HOME was isolated. We use a
    // dedicated var, NOT $HOME — setting $HOME breaks macOS Keychain resolution.
    let savedUserHome = ProcessInfo.processInfo.environment["ORRERY_USER_HOME"]
    setenv("ORRERY_HOME", tmpDir.path, 1)
    setenv("ORRERY_USER_HOME", tmpDir.path, 1)
    unsetenv("ORRERY_ACTIVE_ENV")
    defer {
        if let savedHome {
            setenv("ORRERY_HOME", savedHome, 1)
        } else {
            unsetenv("ORRERY_HOME")
        }
        if let savedUserHome {
            setenv("ORRERY_USER_HOME", savedUserHome, 1)
        } else {
            unsetenv("ORRERY_USER_HOME")
        }
        if let savedActiveEnv {
            setenv("ORRERY_ACTIVE_ENV", savedActiveEnv, 1)
        } else {
            unsetenv("ORRERY_ACTIVE_ENV")
        }
        try? FileManager.default.removeItem(at: tmpDir)
    }

    try body()
}
