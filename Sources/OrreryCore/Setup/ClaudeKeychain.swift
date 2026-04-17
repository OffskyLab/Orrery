import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Read/write Claude Code credentials.
///
/// Storage differs by platform:
/// - macOS: system Keychain. Service name is derived from CLAUDE_CONFIG_DIR:
///   - unset: "Claude Code-credentials"
///   - set:   "Claude Code-credentials-{SHA256(configDir).hex.prefix(8)}"
///   Account is the system username.
/// - Linux: `{configDir}/.credentials.json` (or `~/.claude/.credentials.json`
///   when CLAUDE_CONFIG_DIR is unset). Same JSON shape as what Claude Code
///   stores in the macOS Keychain — `{"claudeAiOauth": {...}}`.
public enum ClaudeKeychain {
    #if os(macOS)
    /// Keychain service name Claude Code uses for a given config dir.
    /// Pass `nil` for the origin state (CLAUDE_CONFIG_DIR unset, `~/.claude`).
    public static func service(for configDir: String?) -> String {
        guard let configDir else { return "Claude Code-credentials" }
        let normalized = configDir.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hex)"
    }
    #endif

    /// Location Claude Code uses for the `.credentials.json` file on non-macOS
    /// platforms. Pass `nil` for origin (CLAUDE_CONFIG_DIR unset → `~/.claude`).
    public static func credentialsFile(for configDir: String?) -> URL {
        let dir: URL
        if let configDir {
            dir = URL(fileURLWithPath: configDir)
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        }
        return dir.appendingPathComponent(".credentials.json")
    }

    /// Look up the Claude account email (from `.claude.json`) and plan (from the credential
    /// store) for a given config dir. Pass `nil` for origin (unset CLAUDE_CONFIG_DIR).
    public static func accountInfo(for configDir: String?) -> ToolAuth.AccountInfo {
        let plan = loadCredentialJSON(for: configDir).flatMap { parsePlan(fromCredential: $0) }

        let jsonURL: URL
        if let configDir {
            jsonURL = URL(fileURLWithPath: configDir).appendingPathComponent(".claude.json")
        } else {
            jsonURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        }
        let email = parseEmail(fromClaudeJSON: jsonURL)
        return ToolAuth.AccountInfo(email: email, plan: plan, model: nil, key: nil)
    }

    /// Copy the Claude credential from one config dir to another.
    /// Pass `nil` for `srcDir` to copy from the origin (unset CLAUDE_CONFIG_DIR) entry.
    /// Returns true on success.
    @discardableResult
    public static func copyCredential(from srcDir: String?, to dstDir: String) -> Bool {
        #if os(macOS)
        let account = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        guard let password = findPassword(service: service(for: srcDir), account: account) else {
            return false
        }
        return addPassword(service: service(for: dstDir), account: account, password: password)
        #else
        let src = credentialsFile(for: srcDir)
        let dst = credentialsFile(for: dstDir)
        guard let data = try? Data(contentsOf: src) else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: dst, options: .atomic)
            // Claude Code creates `.credentials.json` with 0600; match that.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
            return true
        } catch {
            return false
        }
        #endif
    }

    // MARK: - Credential JSON loading

    /// Load the raw credential JSON string (`{"claudeAiOauth": {...}}`) for a config
    /// dir, regardless of whether it came from the macOS Keychain or a Linux file.
    private static func loadCredentialJSON(for configDir: String?) -> String? {
        #if os(macOS)
        let account = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        return findPassword(service: service(for: configDir), account: account)
        #else
        let url = credentialsFile(for: configDir)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
        #endif
    }

    private static func parsePlan(fromCredential json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any]
        else { return nil }
        return oauth["subscriptionType"] as? String
    }

    private static func parseEmail(fromClaudeJSON url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauthAccount = obj["oauthAccount"] as? [String: Any]
        else { return nil }
        return oauthAccount["emailAddress"] as? String
    }

    #if os(macOS)
    private static func findPassword(service: String, account: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch { return nil }

        // Drain the pipe BEFORE waitUntilExit. Claude Code now embeds MCP
        // OAuth tokens (figma, notion, etc.) in the credential JSON, which
        // can exceed the pipe buffer (~16 KB on macOS, sometimes less). If
        // we waited first, `security` would block on a full pipe while
        // we'd block on `security` exiting → permanent deadlock observed
        // in the wild as a multi-minute orrery list hang.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else { return nil }
        let pw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (pw?.isEmpty == false) ? pw : nil
    }

    private static func addPassword(service: String, account: String, password: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["add-generic-password", "-U", "-s", service, "-a", account, "-w", password]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }
    #endif
}
