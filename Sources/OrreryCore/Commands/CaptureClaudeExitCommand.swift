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
/// Also syncs the Keychain: claude reads/writes its OAuth credential (incl.
/// any refresh — its own, or an interactive `/login`) under a service keyed
/// to `CLAUDE_CONFIG_DIR` (see `ClaudeKeychain.service(for:)`), which is a
/// *different* Keychain item from the account's own pool copy
/// (`account.keychainItem`, `Claude Code-orrery-<id>`) that orrery's
/// background token-refresh agent reads. Nothing previously kept those two
/// in sync after the initial `orrery add` import, so the pool copy would
/// silently go stale the moment claude (or the user, via `/login`) rotated
/// the refresh token during normal use — the background agent would then
/// fail every refresh with `invalid_grant` against a token that was already
/// dead.
///
/// The sync is gated on actually detecting a change (comparing the pool's
/// cached `refreshToken` against the live one), rather than copying
/// unconditionally on every exit — that comparison **is** the "a login
/// happened" signal, and it's what fires `AccountLoginHooks` (refetch
/// email/plan, run the user's `~/.orrery/hooks/on-login` script if any).
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
    /// Detects whether claude's live credential (under the config-dir-hashed
    /// Keychain service) actually changed since the pool's cached copy — a
    /// fresh login or a token rotation — and if so, copies it into the
    /// account's own pool service and fires `AccountLoginHooks`.
    /// Best-effort throughout: silently no-ops if the account can't be
    /// loaded, has no `keychainItem` (e.g. non-claude tools never reach this
    /// command), or there's simply nothing new to sync.
    private func syncKeychainToPool(accountDir: URL) {
        guard let account = try? AccountStore.default.load(id: accountDir.lastPathComponent, tool: .claude),
              let poolService = account.keychainItem
        else { return }

        let liveService = ClaudeKeychain.service(for: accountDir.path)
        guard let liveCredential = ClaudeKeychain.oauthCredential(forService: liveService) else { return }

        let poolCredential = ClaudeKeychain.oauthCredential(forService: poolService)
        guard liveCredential.refreshToken != poolCredential?.refreshToken else {
            return // unchanged since last capture — no login/refresh happened this session
        }

        guard ClaudeKeychain.copyKeychainItem(from: liveService, to: poolService) else { return }
        AccountLoginHooks.fire(account: account)
    }
    #endif
}
