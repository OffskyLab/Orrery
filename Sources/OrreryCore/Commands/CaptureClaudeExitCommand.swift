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
}
