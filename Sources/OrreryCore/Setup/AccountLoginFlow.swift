import Foundation

public enum AccountLoginFlow {

    public enum LoginError: Swift.Error, LocalizedError {
        /// The tool's login completed but no credential appeared in the staging dir.
        case credentialNotProduced(Tool)
        /// A macOS Claude account is missing its Keychain item name.
        case missingKeychainItem
        /// The login subprocess exited non-zero.
        case toolExitedNonZero(status: Int32)
        /// The user cancelled the login (e.g. Ctrl-C / SIGINT).
        case loginCancelled

        public var errorDescription: String? {
            switch self {
            case .credentialNotProduced(let tool):
                return "Login for '\(tool.rawValue)' did not produce a credential. "
                    + "The login flow may have been cancelled or failed."
            case .missingKeychainItem:
                return "Account is missing its Keychain item name; cannot import the credential."
            case .toolExitedNonZero(let status):
                return "Login command exited with status \(status)."
            case .loginCancelled:
                return "Login was cancelled."
            }
        }
    }

    // MARK: - Importable core (unit-testable)

    /// Imports a credential a tool wrote into `stagingDir` into the pool account `account`.
    ///
    /// - codex / gemini / Linux claude: copies the credential file from `stagingDir`
    ///   into the account's pool directory, overwriting any existing file.
    /// - macOS claude: copies the Keychain item the login wrote (service derived from
    ///   the staging dir) into the account's own Keychain service.
    ///
    /// After the credential is in place, the freshly-known email/plan are captured
    /// onto the pool `Account` and saved via `AccountStore.default`, so subsequent
    /// `account list` / `account show` reads do not have to re-parse credentials.
    public static func importFrom(stagingDir: URL, into account: Account) throws {
        #if os(macOS)
        if account.tool == .claude {
            guard let dstService = account.keychainItem else {
                throw LoginError.missingKeychainItem
            }
            let srcService = ClaudeKeychain.service(for: stagingDir.path)
            guard ClaudeKeychain.copyKeychainItem(from: srcService, to: dstService) else {
                throw LoginError.credentialNotProduced(account.tool)
            }
            captureInfo(account: account)
            return
        }
        #endif
        try importCredentialFile(stagingDir: stagingDir, into: account)
        captureInfo(account: account)
    }

    /// Refresh `email` / `plan` from the just-imported credential and persist.
    /// Best-effort: a failure here must not mask the success of the import.
    private static func captureInfo(account: Account) {
        var updated = account
        let changed = updated.refreshInfo(accountStore: AccountStore.default)
        guard changed else { return }
        do {
            try AccountStore.default.save(updated)
        } catch {
            FileHandle.standardError.write(Data(
                "orrery: warning: could not persist refreshed account info for '\(account.displayName)': \(error)\n".utf8
            ))
        }
    }

    /// File-based import: codex, gemini, and Linux claude.
    private static func importCredentialFile(stagingDir: URL, into account: Account) throws {
        let fm = FileManager.default
        let fileName = FilesystemCredentialAdapter.credentialFileName(for: account.tool)
        let source = stagingDir.appendingPathComponent(fileName)

        guard fm.fileExists(atPath: source.path) else {
            throw LoginError.credentialNotProduced(account.tool)
        }

        let accountDir = AccountStore.default.accountDir(id: account.id, tool: account.tool)
        try fm.createDirectory(at: accountDir, withIntermediateDirectories: true)

        let destination = accountDir.appendingPathComponent(fileName)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    // MARK: - Interactive login (integration path, not unit-testable)

    /// Triggers the tool's interactive login against a fresh staging config dir,
    /// then imports the resulting credential into the account pool.
    public static func run(account: Account) throws {
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("orrery-login-\(UUID().uuidString)")
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: stagingDir)
            // gemini's isolation wrapper is a SIBLING of the staging dir, not a
            // child, so removing the staging dir alone would leave it behind
            // (holding a now-dangling `.gemini` symlink). No-op for other tools.
            try? fm.removeItem(at: stagingDir.deletingLastPathComponent()
                .appendingPathComponent(stagingDir.lastPathComponent + "-home"))
        }

        if let authCmd = account.tool.authLoginCommand {
            // Tool has a scriptable login subcommand (codex): just launch it —
            // no preamble needed, the subcommand is self-explanatory.
            try spawnInteractive(
                command: authCmd,
                tool: account.tool,
                configDir: stagingDir
            )
        } else {
            // Tool authenticates on first interactive launch (claude, gemini):
            // launch it and let the user complete login themselves, then quit.
            //
            // For CLAUDE this is the defensive fallback path only — the normal
            // path goes through the orrery shell function (`add)` case in the
            // generated activate.sh), which runs `command claude` straight from
            // the shell so it gets a proper foreground TTY process group.
            // Swift's Process does not give the child the foreground process
            // group, so Claude Code detects "not foreground" and silently exits.
            // If a user invokes `orrery-bin add --claude` directly (bypassing
            // the shell function) we still try, but warn them.
            //
            // GEMINI reaches this branch as its normal path, and does work from
            // here: its TUI has no foreground-process-group check, which is why
            // the old broken invocation hung visibly instead of exiting.
            if account.tool == .claude {
                print(L10n.Account.loginManualFallbackHint(account.tool.rawValue))
            }
            try spawnInteractive(
                command: [account.tool.rawValue],
                tool: account.tool,
                configDir: stagingDir
            )
        }

        try importFrom(stagingDir: stagingDir, into: account)
    }

    /// Runs `command` as an interactive subprocess that inherits the parent's
    /// stdin/stdout/stderr (so it can drive the TTY), with `envVarName` pointed
    /// at `configDir`. Throws if the process exits non-zero.
    /// The environment an interactive login runs under, isolated to
    /// `stagingDir` so the credential it produces lands where `importFrom`
    /// looks for it — and, just as importantly, nowhere near the user's real
    /// config.
    ///
    /// Most tools take a config-dir environment variable. gemini-cli does not:
    /// it ignores `GEMINI_CONFIG_DIR` and only ever reads `$HOME/.gemini` (see
    /// `GeminiAdapter`, and `EnvironmentStore.ensureGeminiHomeWrapper`, which
    /// solve the same problem for every other gemini path). This login flow
    /// was the one place still setting that ignored variable, which meant a
    /// gemini login would have written to the real `~/.gemini` and left the
    /// staging dir empty. Isolation for gemini is therefore a redirected HOME
    /// pointing at a wrapper whose `.gemini` symlink leads to `stagingDir`.
    ///
    /// Creates the wrapper as a side effect; idempotent.
    static func prepareLoginEnvironment(
        tool: Tool,
        stagingDir: URL,
        base: [String: String]
    ) throws -> [String: String] {
        var env = base

        guard tool == .gemini else {
            env[tool.envVarName] = stagingDir.path
            return env
        }

        let fm = FileManager.default
        let wrapper = stagingDir.deletingLastPathComponent()
            .appendingPathComponent(stagingDir.lastPathComponent + "-home")
        try fm.createDirectory(at: wrapper, withIntermediateDirectories: true)

        let link = wrapper.appendingPathComponent(".gemini")
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil
            || fm.fileExists(atPath: link.path) {
            try fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: stagingDir)

        env["HOME"] = wrapper.path
        // Leave GEMINI_CONFIG_DIR unset rather than pointing it anywhere: it
        // does nothing, and setting it invites the next reader to believe it
        // does.
        env.removeValue(forKey: Tool.gemini.envVarName)
        return env
    }

    private static func spawnInteractive(
        command: [String],
        tool: Tool,
        configDir: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.environment = try prepareLoginEnvironment(
            tool: tool,
            stagingDir: configDir,
            base: ProcessInfo.processInfo.environment
        )

        // Do NOT redirect stdio — inheriting it keeps the child interactive on the TTY.
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            if process.terminationReason == .uncaughtSignal {
                throw LoginError.loginCancelled
            }
            throw LoginError.toolExitedNonZero(status: process.terminationStatus)
        }
    }
}
