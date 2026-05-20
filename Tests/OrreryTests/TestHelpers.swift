import Foundation

/// Process-global lock serializing every test that mutates the global ORRERY_HOME
/// env var. swift-testing's `.serialized` only serializes within a single suite;
/// this lock serializes across ALL suites that touch ORRERY_HOME.
private let orreryHomeLock = NSLock()

/// Runs `body` with `ORRERY_HOME` pointed at a fresh temp directory.
/// Holds a process-global lock for the duration so concurrent suites cannot race.
/// Restores the previous ORRERY_HOME and deletes the temp dir afterwards.
func withIsolatedHome(_ body: () throws -> Void) rethrows {
    orreryHomeLock.lock()
    defer { orreryHomeLock.unlock() }

    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let saved = ProcessInfo.processInfo.environment["ORRERY_HOME"]
    setenv("ORRERY_HOME", tmpDir.path, 1)
    defer {
        if let saved {
            setenv("ORRERY_HOME", saved, 1)
        } else {
            unsetenv("ORRERY_HOME")
        }
        try? FileManager.default.removeItem(at: tmpDir)
    }

    try body()
}
