import Foundation
#if os(macOS)
import Security
#endif

/// Moving a claude login from one config directory to another.
///
/// This is the knowledge the host hands over a directory rather than trying to
/// express: which file holds the credential, or which keychain entry, how that
/// entry is named, and what else has to travel with it for the login to be
/// usable. None of it is a path, which is why the boundary is `adoptLogin(from:)`
/// and not a copy the host could have performed itself.
///
/// ## Two mechanisms, one per platform
///
/// On macOS claude keeps the credential in the login keychain, under a service
/// name derived from the config directory — so moving a login means copying a
/// keychain item between two derived names, and the file tree carries none of it.
/// Elsewhere the credential is `.credentials.json` inside the directory, and a
/// file copy is the whole of it.
///
/// `.claude.json` travels either way. It carries who the login belongs to, and an
/// account holding a working credential that cannot say whose it is would list
/// with a blank identity and look broken.
enum ClaudeCredentials {

    enum Failure: Error, CustomStringConvertible {
        case noLoginFound(in: URL)
        case couldNotAdopt(String)

        var description: String {
            switch self {
            case .noLoginFound(let dir):
                return "no claude login was found in \(dir.path)"
            case .couldNotAdopt(let reason):
                return "could not adopt the claude login: \(reason)"
            }
        }
    }

    /// Take the login in `source` and make it the login of `target`.
    ///
    /// - Throws: ``Failure/noLoginFound(in:)`` when the directory holds nothing
    ///   usable. That has to be an error: a login reported as adopted when none
    ///   arrived hands someone an account they believe works.
    static func adopt(from source: URL, to target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        var adoptedCredential = false

        #if os(macOS)
        // The keychain item is the credential. It is not in the directory at all
        // — the directory only names it, through the service-name derivation.
        let sourceService = ClaudeIdentity.keychainService(forConfigDir: source)
        let targetService = ClaudeIdentity.keychainService(forConfigDir: target)
        if let secret = keychainSecret(service: sourceService) {
            guard setKeychainSecret(secret, service: targetService) else {
                throw Failure.couldNotAdopt("the keychain refused the copied item")
            }
            adoptedCredential = true
        }
        #else
        let credential = source.appendingPathComponent(".credentials.json")
        if fm.fileExists(atPath: credential.path) {
            let destination = target.appendingPathComponent(".credentials.json")
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: credential, to: destination)
            adoptedCredential = true
        }
        #endif

        // Identity travels with the credential. Without it the account holds a
        // working login it cannot name, which lists as though something failed.
        let identity = source.appendingPathComponent(".claude.json")
        if fm.fileExists(atPath: identity.path) {
            let destination = target.appendingPathComponent(".claude.json")
            try? fm.removeItem(at: destination)
            try? fm.copyItem(at: identity, to: destination)
        }

        guard adoptedCredential else { throw Failure.noLoginFound(in: source) }
    }

    // MARK: - Keychain

    #if os(macOS)
    /// The generic-password primitives, here rather than borrowed from the host.
    ///
    /// The host having them was the arrangement this replaces: it had to know
    /// claude's service-name derivation to use them, which is exactly the
    /// knowledge that belongs on this side.
    private static var currentUser: String {
        ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
    }

    private static func keychainSecret(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: currentUser,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    private static func setKeychainSecret(_ secret: Data, service: String) -> Bool {
        let identifying: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: currentUser,
        ]
        // Update first: an account being logged in again already has an entry,
        // and adding over it fails rather than replacing.
        let updated = SecItemUpdate(
            identifying as CFDictionary,
            [kSecValueData as String: secret] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }

        var adding = identifying
        adding[kSecValueData as String] = secret
        return SecItemAdd(adding as CFDictionary, nil) == errSecSuccess
    }
    #endif
}
