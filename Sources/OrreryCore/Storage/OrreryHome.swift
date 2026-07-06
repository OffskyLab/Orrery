import Foundation

/// The current user's home directory. Single source of truth for "the home dir"
/// used to build `~/.claude` etc., so tests can isolate those paths from the
/// developer's real home by setting `ORRERY_USER_HOME` (see `withIsolatedHome`).
///
/// A dedicated override — not `$HOME` — is used deliberately: setting the OS
/// `$HOME` would break macOS Keychain resolution (it locates the login keychain
/// via `$HOME`). In production `ORRERY_USER_HOME` is unset, so this is exactly
/// `homeDirectoryForCurrentUser` and behavior is unchanged.
public func userHomeURL() -> URL {
    if let override = ProcessInfo.processInfo.environment["ORRERY_USER_HOME"],
       !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}

/// Resolves the orrery home directory (`$ORRERY_HOME`, else `~/.orrery`).
/// Single source of truth shared by EnvironmentStore and AccountStore.
public func orreryHomeURL() -> URL {
    if let custom = ProcessInfo.processInfo.environment["ORRERY_HOME"] {
        return URL(fileURLWithPath: custom)
    }
    return userHomeURL().appendingPathComponent(".orrery")
}
