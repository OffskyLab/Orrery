import ArgumentParser
import Foundation

/// Internal command: prepare an account-add login for Claude.
/// Invoked by the orrery shell function (not directly by users).
/// Writes the account to the store, creates a staging dir, writes a
/// `.orrery-prepare.json` metadata file, then prints the staging dir path
/// to stdout so the shell can capture it with `$(...)`.
public struct AccountAddPrepareCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_account-add-prepare",
        abstract: "Prepare an account-add login (internal; invoked by the orrery shell function for Claude).",
        shouldDisplay: false
    )

    @Flag(name: .long) public var claude: Bool = false
    @Flag(name: .long) public var codex: Bool = false
    @Flag(name: .long) public var gemini: Bool = false

    /// Positional, matching `AddCommand` and `orrery remove <name>`. This
    /// command re-parses the user's own arguments — the claude add path is
    /// routed here by the shell wrapper and never reaches `AddCommand` — so it
    /// has to accept the same spelling, or `orrery add --claude <name>` would
    /// break for claude while working for codex and gemini.
    @Argument(help: ArgumentHelp(L10n.Account.addNameHelp))
    public var name: String?

    public init() {}

    public func run() throws {
        AddCommand.announceDefaultToolIfNoFlag(claude: claude, codex: codex, gemini: gemini)
        let tool = try AddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)
        let displayName = try resolveName()

        if try AccountStore.default.findByDisplayName(displayName, tool: tool) != nil {
            throw ValidationError(L10n.Account.addDuplicateName(displayName, tool.rawValue))
        }

        var account = Account(tool: tool, displayName: displayName)
        #if os(macOS)
        if tool == .claude {
            account.keychainItem = ClaudeKeychain.serviceName(forOrreryAccount: account.id)
        }
        #endif

        try AccountStore.default.save(account)

        // Create a staging directory in the system temp directory.
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        // Write the prepare metadata so _account-add-finalize can recover
        // accountID, tool, and displayName without re-passed flags.
        let metadata: [String: String] = [
            "accountID": account.id,
            "tool": tool.rawValue,
            "displayName": displayName,
        ]
        let metadataURL = stagingDir.appendingPathComponent(".orrery-prepare.json")
        let data = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: metadataURL, options: .atomic)

        #if os(macOS)
        if tool == .claude {
            installAutoFinalizeHook(stagingDir: stagingDir)
        }
        #endif

        // Print only the staging dir path — the shell captures this with $(...).
        print(stagingDir.path)
    }

    #if os(macOS)
    /// Installs an `auth_success` Notification hook into the staging dir's
    /// `settings.json` that runs `_account-add-finalize` the instant login
    /// succeeds, so the account is fully imported and usable while the user
    /// is still inside the interactive `claude` session — they no longer
    /// need to explicitly `/exit` for the account to finish setting up.
    /// `--keep-staging` is passed because claude is still running against
    /// this directory (`CLAUDE_CONFIG_DIR`); the shell wrapper's own
    /// exit-time `_account-add-finalize` call (without that flag) captures
    /// the final `.claude.json` state and deletes the staging dir once
    /// claude actually exits. Best-effort: silently no-ops if `orrery-bin`'s
    /// own path can't be resolved.
    private func installAutoFinalizeHook(stagingDir: URL) {
        Self.healHook(stagingDir: stagingDir)
    }

    /// Re-applies the hook installed by `installAutoFinalizeHook` above. Also
    /// called by `_account-add-heal-hook`, which the shell wrapper's `add`
    /// fast path polls in the background for the lifetime of the `claude`
    /// login session — claude's own first-run onboarding write to this
    /// (otherwise-empty) staging `settings.json` replaces the file wholesale,
    /// wiping the hook before OAuth ever completes. Re-patching on a short
    /// interval puts it back well before login finishes. Safe to call
    /// repeatedly: `ClaudeAuthSuccessHookInstaller.install` is additive and
    /// idempotent.
    public static func healHook(stagingDir: URL) {
        guard let orreryBinPath = resolvedOrreryBinPath() else { return }
        patchAutoFinalizeHook(stagingDir: stagingDir, orreryBinPath: orreryBinPath)
    }

    /// The actual patch, taking `orreryBinPath` as a plain parameter so tests
    /// can pin an arbitrary path instead of depending on where the test
    /// binary itself happens to live.
    static func patchAutoFinalizeHook(stagingDir: URL, orreryBinPath: String) {
        ClaudeAuthSuccessHookInstaller.install(
            command: "\(orreryBinPath) _account-add-finalize --staging \(stagingDir.path) --keep-staging",
            settingsURL: stagingDir.appendingPathComponent("settings.json")
        )
    }

    /// `orrery-bin` resolved to its own absolute path, so the hook command
    /// keeps working regardless of the invoking shell's `PATH`. See
    /// `RunningExecutablePath` for why this can't use `CommandLine.arguments[0]`.
    private static func resolvedOrreryBinPath() -> String? {
        RunningExecutablePath.resolved()
    }
    #endif

    private func resolveName() throws -> String {
        if let n = name, !n.isEmpty { return n }
        FileHandle.standardError.write(Data(L10n.Account.addNamePrompt.utf8))
        guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
              !input.isEmpty
        else {
            FileHandle.standardError.write(Data((L10n.Account.addEmptyName + "\n").utf8))
            throw ValidationError(L10n.Account.addEmptyName)
        }
        return input
    }
}
