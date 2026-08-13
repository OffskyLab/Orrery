import ArgumentParser
import Foundation

/// Internal subcommand wired into the `claude()` shell wrapper.
///
/// Inverse of `PrepareClaudeLaunchCommand`. Reads the (possibly modified)
/// `<accountDir>/.claude.json`, calls `ClaudeJsonMerge.split`, and writes
/// the identity half to the per-account identity store and the shared half
/// to the per-workspace shared store.
///
/// If no `.claude.json` exists (e.g. claude crashed before writing anything),
/// this is a no-op rather than an error — there's nothing to capture.
///
/// Also syncs the Keychain via `ClaudeLoginSync.syncIfChanged` — see that
/// type's doc comment for why the pool copy and claude's live credential
/// can otherwise silently diverge. **This exit-time path is deprecated**:
/// the primary sync trigger is now the `auth_success` claude `Notification`
/// hook (`orrery-claude-hook`, installed per-account by
/// `PrepareClaudeLaunchCommand`), which fires the instant a login
/// completes instead of waiting for exit. This is kept only as a fallback
/// until that hook is confirmed, in practice, to cover every case that
/// matters — in particular, whether it also fires for claude's own silent
/// token refresh and not just an explicit `/login` is unverified as of this
/// writing. Delete once confirmed.
public struct CaptureClaudeExitCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_capture-claude-exit",
        abstract: "(internal) Split .claude.json back into identity + shared stores after claude exit.",
        shouldDisplay: false
    )

    @Option(name: .long, help: "Absolute path to the account directory (CLAUDE_CONFIG_DIR).")
    public var accountDir: String

    public init() {}

    public func run() throws {
        let acctDirURL = URL(fileURLWithPath: accountDir)
        let fm = FileManager.default

        guard fm.fileExists(atPath: acctDirURL.path) else {
            throw ValidationError("Account dir does not exist: \(accountDir)")
        }

        #if os(macOS)
        // Independent of .claude.json below — a Keychain-only refresh (no
        // config file changes) still needs to reach the pool copy.
        syncKeychainToPool(accountDir: acctDirURL)
        #endif

        let claudeJSONURL = acctDirURL.appendingPathComponent(".claude.json")
        guard fm.fileExists(atPath: claudeJSONURL.path) else {
            // No .claude.json — claude may have errored before writing. Nothing to capture.
            return
        }

        // Resolve workspace via metadata.json (same as prepare).
        let metadataURL = acctDirURL.appendingPathComponent("metadata.json")
        guard let mdData = try? Data(contentsOf: metadataURL),
              let mdObj = try? JSONSerialization.jsonObject(with: mdData) as? [String: Any]
        else {
            throw ValidationError("Could not read metadata.json at \(metadataURL.path). Run `orrery pin <account> --workspace <name>` to create or repair the account dir.")
        }
        let workspace = (mdObj["workspace"] as? String) ?? "origin"

        let envStore = EnvironmentStore.default
        let wsDir = envStore.claudeWorkspaceDir(workspace: workspace)

        let split = try ClaudeJsonMerge.split(claudeJSONURL: claudeJSONURL)
        try ClaudeJsonMerge.saveJSON(
            split.identity,
            at: ClaudeJsonMerge.identityFileURL(accountDir: acctDirURL)
        )
        try ClaudeJsonMerge.saveJSON(
            split.shared,
            at: ClaudeJsonMerge.sharedFileURL(workspaceDir: wsDir)
        )
    }

    #if os(macOS)
    @available(*, deprecated, message: "Fallback only — the primary sync trigger is the auth_success claude Notification hook (orrery-claude-hook). Remove once that hook is confirmed to cover every case that matters, e.g. claude's own silent token refresh.")
    private func syncKeychainToPool(accountDir: URL) {
        ClaudeLoginSync.syncIfChanged(accountDir: accountDir)
    }
    #endif
}
