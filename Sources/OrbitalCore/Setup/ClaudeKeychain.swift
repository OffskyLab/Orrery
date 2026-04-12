#if canImport(CryptoKit)
import CryptoKit
import Foundation

/// Read/write Claude Code credentials in the macOS Keychain.
///
/// Claude Code derives the Keychain service name from CLAUDE_CONFIG_DIR:
/// - unset: "Claude Code-credentials"
/// - set:   "Claude Code-credentials-{SHA256(configDir).hex.prefix(8)}"
/// Account is the system username.
public enum ClaudeKeychain {
    /// Keychain service name Claude Code uses for a given config dir.
    /// Pass `nil` for the origin state (CLAUDE_CONFIG_DIR unset, `~/.claude`).
    public static func service(for configDir: String?) -> String {
        guard let configDir else { return "Claude Code-credentials" }
        let normalized = configDir.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hex)"
    }

    /// Copy the Claude credential from one config dir to another.
    /// Pass `nil` for `srcDir` to copy from the origin (unset CLAUDE_CONFIG_DIR) entry.
    /// Returns true on success.
    @discardableResult
    public static func copyCredential(from srcDir: String?, to dstDir: String) -> Bool {
        let account = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        guard let password = findPassword(service: service(for: srcDir), account: account) else {
            return false
        }
        return addPassword(service: service(for: dstDir), account: account, password: password)
    }

    private static func findPassword(service: String, account: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
}
#endif
