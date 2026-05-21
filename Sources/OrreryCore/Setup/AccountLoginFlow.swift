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
            captureInfo(stagingDir: stagingDir, account: account)
            return
        }
        #endif
        try importCredentialFile(stagingDir: stagingDir, into: account)
        captureInfo(stagingDir: stagingDir, account: account)
    }

    /// Refresh `email` / `plan` from the just-imported credential and persist.
    /// Best-effort: a failure here must not mask the success of the import.
    private static func captureInfo(stagingDir: URL, account: Account) {
        var updated = account
        let claudeJSONURL: URL? = account.tool == .claude
            ? stagingDir.appendingPathComponent(".claude.json")
            : nil
        let changed = updated.refreshInfo(
            accountStore: AccountStore.default,
            claudeJSONURL: claudeJSONURL
        )
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
        defer { try? fm.removeItem(at: stagingDir) }

        if let authCmd = account.tool.authLoginCommand {
            // Tool has a scriptable login subcommand (e.g. codex).
            try spawnInteractive(
                command: authCmd,
                envVarName: account.tool.envVarName,
                configDir: stagingDir
            )
        } else {
            // Tool has no scriptable login subcommand (e.g. claude): launch it
            // interactively and let the user complete login themselves.
            print(L10n.Account.loginManualHint(account.tool.rawValue, stagingDir.path))
            try spawnInteractive(
                command: [account.tool.rawValue],
                envVarName: account.tool.envVarName,
                configDir: stagingDir
            )
        }

        try importFrom(stagingDir: stagingDir, into: account)
    }

    /// Runs `command` as an interactive subprocess that inherits the parent's
    /// stdin/stdout/stderr (so it can drive the TTY), with `envVarName` pointed
    /// at `configDir`. Throws if the process exits non-zero.
    private static func spawnInteractive(
        command: [String],
        envVarName: String,
        configDir: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command

        var env = ProcessInfo.processInfo.environment
        env[envVarName] = configDir.path
        process.environment = env

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
