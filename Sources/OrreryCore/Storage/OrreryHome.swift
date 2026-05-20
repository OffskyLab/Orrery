import Foundation

/// Resolves the orrery home directory (`$ORRERY_HOME`, else `~/.orrery`).
/// Single source of truth shared by EnvironmentStore and AccountStore.
public func orreryHomeURL() -> URL {
    if let custom = ProcessInfo.processInfo.environment["ORRERY_HOME"] {
        return URL(fileURLWithPath: custom)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".orrery")
}
