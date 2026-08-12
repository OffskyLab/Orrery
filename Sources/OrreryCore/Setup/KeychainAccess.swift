import Foundation

// On Linux, origin-account seeding never actually calls these (see
// OriginAccountSeeder's `#if os(macOS)`/`#else` branches, which use
// file-existence checks and AccountLoginFlow.importFrom instead) — these
// closures exist only so `KeychainAccess.live`'s default compiles.
#if os(macOS)
private let liveItemExists: @Sendable (String) -> Bool = ClaudeKeychain.keychainItemExists
private let liveCopyItem: @Sendable (String, String) -> Bool = ClaudeKeychain.copyKeychainItem
#else
private let liveItemExists: @Sendable (String) -> Bool = { _ in false }
private let liveCopyItem: @Sendable (String, String) -> Bool = { _, _ in false }
#endif

/// Injectable seam over the macOS Keychain so origin-account seeding is
/// unit-testable without touching the real login keychain (which cannot be
/// isolated in tests — setting $HOME breaks keychain resolution).
public struct KeychainAccess: Sendable {
    /// True if a keychain generic-password item exists for `service`.
    public var itemExists: @Sendable (_ service: String) -> Bool
    /// Copy the item at `from` service to `to` service; returns success.
    public var copyItem: @Sendable (_ from: String, _ to: String) -> Bool

    public init(
        itemExists: @escaping @Sendable (_ service: String) -> Bool,
        copyItem: @escaping @Sendable (_ from: String, _ to: String) -> Bool
    ) {
        self.itemExists = itemExists
        self.copyItem = copyItem
    }

    /// Production wiring — the real Keychain on macOS; unused no-ops on Linux.
    public static let live = KeychainAccess(
        itemExists: liveItemExists,
        copyItem: liveCopyItem
    )
}
