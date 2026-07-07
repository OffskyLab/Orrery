import Foundation

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

    /// Production wiring — the real Keychain.
    public static let live = KeychainAccess(
        itemExists: ClaudeKeychain.keychainItemExists,
        copyItem: ClaudeKeychain.copyKeychainItem
    )
}
