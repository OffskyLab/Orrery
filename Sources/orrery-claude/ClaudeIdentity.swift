import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Reading who a claude config directory is logged in as.
///
/// This is claude's knowledge, in the claude-specific process: which files hold
/// an identity, what the keys inside them are called, and how the credential
/// store is named. orrery supplies a directory and nothing else — it does not
/// know any of the above, and after this it does not need to.
///
/// ## Two records, and why both are read
///
/// `.claude.json` is what claude itself writes, so it is current. Newer claude
/// versions have stopped putting `emailAddress` anywhere re-derivable, which is
/// why orrery keeps its own snapshot in `claude-identity.json` — pooled account
/// directories carry that instead. A directory can hold either or both.
///
/// ## Why a home directory is never derived here
///
/// The host resolves paths against a seam it can redirect (`ORRERY_USER_HOME`),
/// and that seam does not cross a process boundary — this process has its own
/// environment. A plugin that worked out its own `~` would read the developer's
/// real config during an isolated test run, which is a family of bug this
/// repository has paid for four times. So every path here is one orrery handed
/// over, and there is no fallback that invents one.
enum ClaudeIdentity {

    struct Record {
        var email: String?
        var plan: String?

        var isEmpty: Bool { email == nil && plan == nil }
    }

    /// Everything obtainable without spawning anything.
    ///
    /// This is what a listing gets. The credential store is deliberately not
    /// consulted: on macOS that is a `/usr/bin/security` subprocess *per
    /// directory*, which is the difference between a listing that is free and
    /// one that costs a process spawn per row.
    static func fromFiles(in configDir: URL) -> Record {
        var record = Record(email: nil, plan: nil)

        // orrery's snapshot first, so a live value below can overwrite it.
        if let persisted = oauthAccount(in: configDir.appendingPathComponent("claude-identity.json")) {
            record.email = persisted["emailAddress"] as? String
            record.plan = persisted["subscriptionType"] as? String
        }
        if let live = oauthAccount(in: configDir.appendingPathComponent(".claude.json")) {
            // Only overwrite with something. `.claude.json` carries no plan, and
            // a missing field must not erase a known one.
            record.email = live["emailAddress"] as? String ?? record.email
            record.plan = live["subscriptionType"] as? String ?? record.plan
        }
        return record
    }

    /// The freshest answer available, consulting the credential store.
    ///
    /// Used for a detail view, where one spawn is affordable and being current
    /// matters — an in-session `/login` lands in the credential store before it
    /// lands anywhere else.
    static func fresh(in configDir: URL) -> Record {
        var record = fromFiles(in: configDir)
        if let plan = planFromCredentialStore(configDir: configDir) {
            record.plan = plan
        }
        return record
    }

    // MARK: - Files

    private static func oauthAccount(in url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["oauthAccount"] as? [String: Any]
    }

    // MARK: - Credential store

    private static func planFromCredentialStore(configDir: URL) -> String? {
        guard let json = credentialJSON(configDir: configDir),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any]
        else { return nil }
        return oauth["subscriptionType"] as? String
    }

    #if os(macOS)
    /// The Keychain service name claude derives for a config directory: the
    /// first four bytes of the SHA-256 of the canonically-composed path, in hex.
    ///
    /// The host derives the same name for its own pool operations. Those two
    /// copies are pinned against each other by a test until the host's goes —
    /// one format with two readers drifts silently otherwise.
    static func keychainService(forConfigDir configDir: URL) -> String {
        let normalized = configDir.path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return "Claude Code-credentials-\(digest.prefix(4).map { String(format: "%02x", $0) }.joined())"
    }

    private static func credentialJSON(configDir: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", keychainService(forConfigDir: configDir),
            "-a", ProcessInfo.processInfo.environment["USER"] ?? "",
            "-w",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        // Drain before waiting. Claude Code embeds MCP OAuth tokens in the
        // credential JSON, which can exceed the pipe buffer — waiting first
        // deadlocks `security` on a full pipe against us waiting on its exit.
        // That was observed in the wild as a multi-minute `orrery list` hang,
        // and the same trap is here because the same subprocess is.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #else
    private static func credentialJSON(configDir: URL) -> String? {
        let url = configDir.appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    #endif
}
