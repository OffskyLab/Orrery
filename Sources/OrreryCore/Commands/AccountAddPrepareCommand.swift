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

    @Option(name: .long, help: ArgumentHelp(L10n.Account.addNameHelp))
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
        guard let orreryBinPath = Self.resolvedOrreryBinPath() else { return }
        Self.patchAutoFinalizeHook(stagingDir: stagingDir, orreryBinPath: orreryBinPath)
    }

    /// The actual patch, taking `orreryBinPath` as a plain parameter so it's
    /// testable without depending on `resolvedOrreryBinPath()`'s
    /// `CommandLine.arguments[0]`-based resolution (same caveat as
    /// `PrepareClaudeLaunchCommand.resolvedHookBinaryPath()`).
    static func patchAutoFinalizeHook(stagingDir: URL, orreryBinPath: String) {
        ClaudeAuthSuccessHookInstaller.install(
            command: "\(orreryBinPath) _account-add-finalize --staging \(stagingDir.path) --keep-staging",
            settingsURL: stagingDir.appendingPathComponent("settings.json")
        )
    }

    /// `orrery-bin` resolved to its own absolute path, so the hook command
    /// keeps working regardless of the invoking shell's `PATH`.
    private static func resolvedOrreryBinPath() -> String? {
        let arg0 = CommandLine.arguments[0]
        let binaryPath = arg0.hasPrefix("/")
            ? arg0
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(arg0).standardizedFileURL.path
        return FileManager.default.fileExists(atPath: binaryPath) ? binaryPath : nil
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
