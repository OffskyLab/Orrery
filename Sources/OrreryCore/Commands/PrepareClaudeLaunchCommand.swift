import ArgumentParser
import Foundation

/// Internal subcommand wired into the `claude()` shell wrapper.
///
/// Given a v3.1 account dir, merges the per-account identity store and the
/// per-workspace shared store into `<accountDir>/.claude.json` so claude
/// reads consistent state at launch.
///
/// Resolves the workspace via the account's `metadata.json` (its `workspace`
/// field) and `EnvironmentStore.claudeWorkspaceDir`.
public struct PrepareClaudeLaunchCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_prepare-claude-launch",
        abstract: "(internal) Merge identity + shared stores into .claude.json before claude launch.",
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

        // Resolve workspace from metadata.json in the account dir.
        let metadataURL = acctDirURL.appendingPathComponent("metadata.json")
        guard let mdData = try? Data(contentsOf: metadataURL) else {
            throw ValidationError("Could not read metadata.json at \(metadataURL.path). Run `orrery pin <account> --workspace <name>` to create or repair the account dir.")
        }

        // Try to decode as Account first (for accessing keychainItem later)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let account = try? decoder.decode(Account.self, from: mdData)

        // Also parse as dict for workspace lookup (backward compat)
        let mdObj = (try? JSONSerialization.jsonObject(with: mdData) as? [String: Any]) ?? [:]
        let workspace = (mdObj["workspace"] as? String) ?? "origin"

        // Compute workspace shared dir (uses default home — caller controls
        // ORRERY_HOME).
        let envStore = EnvironmentStore.default
        let wsDir = envStore.claudeWorkspaceDir(workspace: workspace)

        // Load both stores (nil if absent — treat as empty).
        var identity = ClaudeJsonMerge.loadJSON(
            at: ClaudeJsonMerge.identityFileURL(accountDir: acctDirURL)) ?? [:]
        let shared = ClaudeJsonMerge.loadJSON(
            at: ClaudeJsonMerge.sharedFileURL(workspaceDir: wsDir)) ?? [:]

        // v3.1 fix: If claude-identity.json has incomplete oauthAccount (missing
        // refreshToken), load the full credentials from keychain/credentials file.
        // This handles accounts created before the identity/shared split was added.
        if let oauthDict = identity["oauthAccount"] as? [String: Any],
           !oauthDict.keys.contains("refreshToken"),
           let account = account {
            // Load full credentials from keychain (macOS) or credentials file (Linux)
            #if os(macOS)
            if let keychainItem = account.keychainItem,
               let credJSON = ClaudeKeychain.password(forService: keychainItem),
               let credData = credJSON.data(using: .utf8),
               let credObj = try? JSONSerialization.jsonObject(with: credData) as? [String: Any],
               let fullOauth = credObj["claudeAiOauth"] as? [String: Any] {
                identity["oauthAccount"] = fullOauth
            }
            #else
            let credURL = acctDirURL.appendingPathComponent(".credentials.json")
            if let credData = try? Data(contentsOf: credURL),
               let credObj = try? JSONSerialization.jsonObject(with: credData) as? [String: Any],
               let fullOauth = credObj["claudeAiOauth"] as? [String: Any] {
                identity["oauthAccount"] = fullOauth
            }
            #endif
        }

        // Merge and write out.
        let merged = ClaudeJsonMerge.merge(identity: identity, shared: shared)
        try ClaudeJsonMerge.saveJSON(
            merged,
            at: acctDirURL.appendingPathComponent(".claude.json")
        )
    }
}
