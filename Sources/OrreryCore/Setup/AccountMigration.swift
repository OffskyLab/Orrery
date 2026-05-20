import Foundation

/// One-time v2→v3 migration: lifts credentials that used to live directly inside
/// each env's tool dir (`~/.orrery/envs/<UUID>/<tool>/` and `~/.orrery/origin/<tool>/`)
/// into the shared accounts pool (`~/.orrery/accounts/<tool>/<id>/`), then pins each
/// env/origin to the resulting account via `OrreryEnvironment.accounts` /
/// `OriginConfig.accounts`.
///
/// Safety properties:
/// - Idempotent — guarded by a `.migration-v3` flag file.
/// - Non-destructive — credentials are COPIED into the pool; originals stay in
///   place (a later `orrery run` materialize step replaces them with symlinks).
/// - A full backup of `~/.orrery/` is taken before any mutation.
public enum AccountMigration {
    public static let flagFileName = ".migration-v3"

    public enum MigrationError: Swift.Error {
        case backupFailed(underlying: Error)
        /// Migration aborted because it is running inside a phantom-supervised
        /// session. Exit the phantom session(s) and rerun.
        case phantomSupervisorActive
    }

    /// Runs the v2→v3 account-pool migration once. Idempotent — guarded by a flag file.
    /// Non-destructive: credentials are COPIED into the pool; originals are left in place
    /// (a later `orrery run` materialize step replaces them with symlinks). A full backup
    /// of `~/.orrery/` is taken before any mutation.
    public static func runIfNeeded(homeURL: URL) throws {
        let fm = FileManager.default
        let flagURL = homeURL.appendingPathComponent(flagFileName)

        // Already migrated.
        if fm.fileExists(atPath: flagURL.path) { return }

        // Nothing to migrate: home doesn't exist, or has neither envs nor origin.
        let envsURL = homeURL.appendingPathComponent("envs")
        let originURL = homeURL.appendingPathComponent("origin")
        let hasEnvs = fm.fileExists(atPath: envsURL.path)
        let hasOrigin = fm.fileExists(atPath: originURL.path)
        guard fm.fileExists(atPath: homeURL.path), hasEnvs || hasOrigin else {
            // Fresh install (or home not created yet) — mark done so we never rescan.
            if fm.fileExists(atPath: homeURL.path) {
                try writeFlag(at: flagURL)
            }
            return
        }

        // Refuse to migrate while running inside a phantom-supervised session.
        // The supervisor exports `ORRERY_PHANTOM_SHELL_PID` to its children, so
        // this catches the case where migration is triggered from within a
        // phantom-supervised `claude`. It is NOT a cross-process / system-wide
        // detector — a separate terminal cannot see another shell's env — so the
        // pre-migration backup remains the real safety net (see report notes).
        if ProcessInfo.processInfo.environment["ORRERY_PHANTOM_SHELL_PID"] != nil {
            let message = """
                [orrery migration] A phantom-supervised session is active in this shell.
                Account migration is deferred to avoid touching credentials mid-session.
                Exit your phantom Claude session(s) and run any orrery command again.

                """
            FileHandle.standardError.write(Data(message.utf8))
            throw MigrationError.phantomSupervisorActive
        }

        // 1. Backup before any mutation.
        try backup(homeURL: homeURL)

        let envStore = EnvironmentStore(homeURL: homeURL)
        let acctStore = AccountStore(homeURL: homeURL)

        // 2. Migrate origin + every named env, every tool.
        for tool in Tool.allCases {
            try migrateOrigin(tool: tool, envStore: envStore, acctStore: acctStore)
            for envName in (try? envStore.listNames()) ?? [] {
                try migrateEnv(envName: envName, tool: tool, envStore: envStore, acctStore: acctStore)
            }
        }

        // 3. Mark done.
        try writeFlag(at: flagURL)
    }

    // MARK: - Flag / backup

    private static func writeFlag(at url: URL) throws {
        try Data("v3\n".utf8).write(to: url)
    }

    private static func backup(homeURL: URL) throws {
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = homeURL.deletingLastPathComponent()
            .appendingPathComponent(".orrery-backup-\(ts)")
        do {
            try FileManager.default.copyItem(at: homeURL, to: backupURL)
        } catch {
            throw MigrationError.backupFailed(underlying: error)
        }
        FileHandle.standardError.write(Data("[orrery migration] backup created at \(backupURL.path)\n".utf8))
    }

    // MARK: - Scope migration

    /// Migrates the origin scope's credential for `tool` into the pool and pins it.
    private static func migrateOrigin(
        tool: Tool,
        envStore: EnvironmentStore,
        acctStore: AccountStore
    ) throws {
        let configDir = envStore.originConfigDir(tool: tool)
        guard let credential = extractCredential(tool: tool, configDir: configDir) else {
            return  // tool never logged in for origin — nothing to migrate
        }
        let id = try resolveOrCreateAccount(
            credential: credential, tool: tool, scopeName: "origin", acctStore: acctStore
        )
        var config = envStore.loadOriginConfig()
        config.setAccount(id, for: tool)
        try envStore.saveOriginConfig(config)
    }

    /// Migrates a named env's credential for `tool` into the pool and pins it.
    private static func migrateEnv(
        envName: String,
        tool: Tool,
        envStore: EnvironmentStore,
        acctStore: AccountStore
    ) throws {
        let configDir = envStore.toolConfigDir(tool: tool, environment: envName)
        guard let credential = extractCredential(tool: tool, configDir: configDir) else {
            return  // tool never logged in for this env — nothing to migrate
        }
        let id = try resolveOrCreateAccount(
            credential: credential, tool: tool, scopeName: envName, acctStore: acctStore
        )
        var env = try envStore.load(named: envName)
        env.setAccount(id, for: tool)
        try envStore.save(env)
    }

    // MARK: - Credential extraction

    /// A credential is opaque bytes — file contents for file-based tools, or the
    /// macOS Keychain password (as UTF-8 bytes) for macOS Claude.
    private static func extractCredential(tool: Tool, configDir: URL) -> Data? {
        #if os(macOS)
        if tool == .claude {
            let service = ClaudeKeychain.service(for: configDir.path)
            guard let password = ClaudeKeychain.password(forService: service) else { return nil }
            return Data(password.utf8)
        }
        #endif
        let file = configDir.appendingPathComponent(
            FilesystemCredentialAdapter.credentialFileName(for: tool)
        )
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try? Data(contentsOf: file)
    }

    /// Reads the stored credential of an existing pool account for content comparison.
    private static func storedCredential(of account: Account, acctStore: AccountStore) -> Data? {
        #if os(macOS)
        if account.tool == .claude {
            guard let service = account.keychainItem,
                  let password = ClaudeKeychain.password(forService: service)
            else { return nil }
            return Data(password.utf8)
        }
        #endif
        let file = acctStore.accountDir(id: account.id, tool: account.tool)
            .appendingPathComponent(FilesystemCredentialAdapter.credentialFileName(for: account.tool))
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try? Data(contentsOf: file)
    }

    // MARK: - Dedup + account creation

    /// Returns an existing pool account id whose credential content matches, or
    /// creates a new account (copying the credential into the pool) and returns its id.
    private static func resolveOrCreateAccount(
        credential: Data,
        tool: Tool,
        scopeName: String,
        acctStore: AccountStore
    ) throws -> AccountID {
        // Dedup: reuse the first pool account with identical credential content.
        for existing in try acctStore.list(tool: tool) {
            if storedCredential(of: existing, acctStore: acctStore) == credential {
                return existing.id
            }
        }

        // No match — create a new account.
        let displayName = try uniqueDisplayName(base: scopeName, tool: tool, acctStore: acctStore)
        var account = Account(tool: tool, displayName: displayName)

        #if os(macOS)
        if tool == .claude {
            account.keychainItem = ClaudeKeychain.serviceName(forOrreryAccount: account.id)
        }
        #endif

        try acctStore.save(account)
        try copyCredentialIntoPool(
            credential: credential, account: account, tool: tool, acctStore: acctStore
        )
        return account.id
    }

    /// Picks a display name unique within the tool's pool: `base`, else `base-2`, `base-3`, …
    private static func uniqueDisplayName(
        base: String,
        tool: Tool,
        acctStore: AccountStore
    ) throws -> String {
        if try acctStore.findByDisplayName(base, tool: tool) == nil { return base }
        var suffix = 2
        while true {
            let candidate = "\(base)-\(suffix)"
            if try acctStore.findByDisplayName(candidate, tool: tool) == nil { return candidate }
            suffix += 1
        }
    }

    /// Copies the extracted credential into the account's pool dir / Keychain item.
    private static func copyCredentialIntoPool(
        credential: Data,
        account: Account,
        tool: Tool,
        acctStore: AccountStore
    ) throws {
        #if os(macOS)
        if tool == .claude {
            // `extractCredential` already returned the Keychain password bytes,
            // so store them directly under the account's own service. This is
            // uniform for origin and named envs and avoids re-deriving the
            // source service name.
            let ok = ClaudeKeychain.storePassword(
                String(decoding: credential, as: UTF8.self),
                forOrreryAccount: account.id
            )
            if !ok {
                FileHandle.standardError.write(Data(
                    "[orrery migration] warning: failed to store Claude credential for account \(account.id)\n".utf8
                ))
            }
            return
        }
        #endif
        let fm = FileManager.default
        let dir = acctStore.accountDir(id: account.id, tool: tool)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(
            FilesystemCredentialAdapter.credentialFileName(for: tool)
        )
        try credential.write(to: dest, options: .atomic)
        // Credential files are sensitive — mirror Claude Code's 0600 perms.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
    }
}
