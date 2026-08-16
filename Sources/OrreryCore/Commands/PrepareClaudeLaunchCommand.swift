import ArgumentParser
import Foundation

/// Internal subcommand wired into the `claude()` shell wrapper.
///
/// Given a v3.1 account dir, merges the per-account identity store and the
/// per-workspace shared store into `<accountDir>/.claude.json` so claude
/// reads consistent state at launch.
///
/// Resolves the workspace via the account's `metadata.json` (its `workspace`
/// field) and `EnvironmentStore.toolConfigDir(tool: .claude, environment:)`.
public struct PrepareClaudeLaunchCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_prepare-claude-launch",
        abstract: "(internal) Merge identity + shared stores into .claude.json before claude launch.",
        shouldDisplay: false
    )

    @Option(name: .long, help: "Absolute path to the account directory (CLAUDE_CONFIG_DIR).")
    public var accountDir: String

    @Flag(name: .long, help: "Only sync workspace symlinks; skip the .claude.json merge. Used for bare origin launches where claude reads ~/.claude.json, not <accountDir>/.claude.json.")
    public var linksOnly: Bool = false

    public init() {}

    public func run() throws {
        let fm = FileManager.default

        // Resolve symlinks up front: bare origin launches pass ~/.claude, which
        // is a symlink to the origin account dir. FileManager.contentsOfDirectory
        // (at:) does not traverse a symlinked directory, so the metadata read and
        // the workspace linker must operate on the real path. No-op for a real
        // (non-symlink) account dir.
        let acctDirURL = URL(fileURLWithPath: accountDir).resolvingSymlinksInPath()

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
        let wsDir = envStore.toolConfigDir(tool: .claude, environment: workspace)

        // The .claude.json merge is skipped for --links-only: bare origin
        // launches (CLAUDE_CONFIG_DIR unset) read ~/.claude.json, NOT
        // <accountDir>/.claude.json, so merging here would target the wrong
        // file. Those launches only need the workspace symlinks synced below.
        if !linksOnly {
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

            #if os(macOS)
            // Ongoing invariant, not flag-guarded: keep the auth_success hook
            // installed in this account's settings.json, self-healing the
            // same way the rest of this command does. Best-effort — a
            // failure here must never block the launch.
            ensureAuthSuccessHookInstalled(accountDir: acctDirURL)
            #endif
        }

        #if os(macOS)
        // Outside the !linksOnly guard on purpose: unlike .claude.json (which
        // bare origin launches read from ~/.claude.json, not the account dir),
        // settings.json IS read from the account dir even on origin, because
        // ~/.claude symlinks to it. Origin sessions need accurate session ids
        // just as much as pinned ones do.
        if let hookBinaryPath = Self.resolvedHookBinaryPath() {
            ClaudeSessionHookInstaller.install(
                command: "\(hookBinaryPath) --session-event",
                settingsURL: acctDirURL.appendingPathComponent("settings.json"))
        }
        #endif

        // Launch only mirrors the workspace into the account: symlink any shared
        // dir the account is missing. It never moves/merges account dirs into the
        // workspace — that account→workspace seeding happens once at pin time
        // (`orrery pin` → prepareDirectory). Best-effort; never blocks launch.
        let linkWarnings = AccountDirectoryRuntime.manager(ifAvailable: .claude)?.mirrorWorkspaceDirsToAccount(
            accountDir: acctDirURL, workspaceDir: wsDir) ?? []
        for w in linkWarnings {
            FileHandle.standardError.write(
                Data("orrery: link-workspace: \(w)\n".utf8))
        }
    }

    #if os(macOS)
    /// Patches `<accountDir>/settings.json` to add a `Notification` hook for
    /// the `auth_success` matcher, pointing at `orrery-claude-hook` — see
    /// `ClaudeLoginSync`'s doc comment for what that hook does. Idempotent
    /// (`SettingsJSONPatcher`'s hook-matcher comparator treats an existing
    /// entry with the same matcher + command set as already present, so this
    /// never duplicates on repeated launches) and additive — every other key
    /// already in settings.json, including other hooks, is left untouched.
    /// Best-effort: silently no-ops if the sibling `orrery-claude-hook`
    /// binary can't be found or the file can't be read/written.
    private func ensureAuthSuccessHookInstalled(accountDir: URL) {
        guard let hookBinaryPath = Self.resolvedHookBinaryPath() else { return }
        Self.patchAuthSuccessHook(accountDir: accountDir, hookBinaryPath: hookBinaryPath)
    }

    /// The actual patch, taking `hookBinaryPath` as a plain parameter so
    /// tests can pin an arbitrary path instead of depending on where the
    /// sibling `orrery-claude-hook` binary actually lives.
    static func patchAuthSuccessHook(accountDir: URL, hookBinaryPath: String) {
        ClaudeAuthSuccessHookInstaller.install(
            command: "\(hookBinaryPath) --account-dir \(accountDir.path)",
            settingsURL: accountDir.appendingPathComponent("settings.json")
        )
    }

    /// `orrery-claude-hook` ships side-by-side with `orrery-bin` (same
    /// install directory — see `.github/workflows/release.yml` and
    /// `docs/install.sh`), resolved by swapping the currently running
    /// `orrery-bin`'s filename. Returns nil if no such binary exists next to
    /// it (e.g. a dev build where only `orrery-bin` was built). See
    /// `RunningExecutablePath` for why this can't use `CommandLine.arguments[0]`.
    private static func resolvedHookBinaryPath() -> String? {
        guard let selfPath = RunningExecutablePath.resolved() else { return nil }
        let candidate = URL(fileURLWithPath: selfPath)
            .deletingLastPathComponent()
            .appendingPathComponent("orrery-claude-hook")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate.path : nil
    }
    #endif
}
