import Foundation

/// One-time v2→v3 migration: lifts credentials that used to live directly inside
/// each env's tool dir (`~/.orrery/envs/<UUID>/<tool>/` and `~/.orrery/origin/<tool>/`)
/// into the shared accounts pool (`~/.orrery/accounts/<tool>/<id>/`), then pins each
/// env/origin to the resulting account via `Workspace.accounts` /
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

        // Nothing to migrate: home doesn't exist, or has neither workspaces nor legacy envs/origin.
        // Phase A migration (if needed) runs before this, so check both old and new paths.
        let envsURL = homeURL.appendingPathComponent("envs")
        let originURL = homeURL.appendingPathComponent("origin")
        let workspacesURL = homeURL.appendingPathComponent("workspaces")
        let hasLegacy = fm.fileExists(atPath: envsURL.path) || fm.fileExists(atPath: originURL.path)
        let hasWorkspaces = fm.fileExists(atPath: workspacesURL.path)
        guard fm.fileExists(atPath: homeURL.path), hasLegacy || hasWorkspaces else {
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
            for envName in try envStore.listNames() {
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
        let suffix = String(UUID().uuidString.prefix(8))
        let backupURL = homeURL.deletingLastPathComponent()
            .appendingPathComponent(".orrery-backup-\(ts)-\(suffix)")
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
        // Skip if already pinned (idempotent re-run).
        var config = envStore.loadOriginWorkspace()
        guard config.account(for: tool) == nil else { return }

        let configDir = envStore.originConfigDir(tool: tool)
        guard let credential = extractCredential(tool: tool, configDir: configDir, isOrigin: true) else {
            return  // tool never logged in for origin — nothing to migrate
        }
        // For origin Claude, `.claude.json` lives at `~/.claude.json`.
        let claudeJSON: URL? = tool == .claude
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
            : nil
        let id = try resolveOrCreateAccount(
            credential: credential,
            tool: tool,
            scopeName: "origin",
            acctStore: acctStore,
            claudeJSONURL: claudeJSON
        )
        config.setAccount(id, for: tool)
        try envStore.saveOriginWorkspace(config)
    }

    /// Migrates a named env's credential for `tool` into the pool and pins it.
    private static func migrateEnv(
        envName: String,
        tool: Tool,
        envStore: EnvironmentStore,
        acctStore: AccountStore
    ) throws {
        // Skip if already pinned (idempotent re-run).
        var env = try envStore.load(named: envName)
        guard env.account(for: tool) == nil else { return }

        let configDir = envStore.toolConfigDir(tool: tool, environment: envName)
        guard let credential = extractCredential(tool: tool, configDir: configDir, isOrigin: false) else {
            return  // tool never logged in for this env — nothing to migrate
        }
        // For named-env Claude, `.claude.json` lives inside the env's tool dir.
        let claudeJSON: URL? = tool == .claude
            ? configDir.appendingPathComponent(".claude.json")
            : nil
        let id = try resolveOrCreateAccount(
            credential: credential,
            tool: tool,
            scopeName: envName,
            acctStore: acctStore,
            claudeJSONURL: claudeJSON
        )
        env.setAccount(id, for: tool)
        try envStore.save(env)
    }

    // MARK: - Credential extraction

    /// A credential is opaque bytes — file contents for file-based tools, or the
    /// macOS Keychain password (as UTF-8 bytes) for macOS Claude.
    ///
    /// - Parameter isOrigin: `true` when extracting the origin scope's credential.
    ///   On macOS, origin's Claude credential was written by Claude with
    ///   `CLAUDE_CONFIG_DIR` unset, so its Keychain service is `service(for: nil)`.
    ///   Named-env credentials use `service(for: configDir.path)` instead.
    private static func extractCredential(tool: Tool, configDir: URL, isOrigin: Bool) -> Data? {
        #if os(macOS)
        if tool == .claude {
            // Origin: CLAUDE_CONFIG_DIR was unset → bare "Claude Code-credentials".
            // Named env: CLAUDE_CONFIG_DIR was set to the env's tool dir.
            let service = isOrigin
                ? ClaudeKeychain.service(for: nil)
                : ClaudeKeychain.service(for: configDir.path)
            guard let password = ClaudeKeychain.password(forService: service) else { return nil }
            return Data(password.utf8)
        }
        #endif
        let file = configDir.appendingPathComponent(
            FilesystemCredentialAdapter.credentialFileName(for: tool)
        )
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        if let data = try? Data(contentsOf: file) { return data }
        // File exists but could not be read — warn and treat as absent.
        FileHandle.standardError.write(Data(
            "orrery migration: warning: could not read credential at \(file.path)\n".utf8
        ))
        return nil
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
    ///
    /// `claudeJSONURL` is the source env's `.claude.json` URL (Claude only), used to
    /// capture the email onto the newly-created account. Ignored for other tools.
    private static func resolveOrCreateAccount(
        credential: Data,
        tool: Tool,
        scopeName: String,
        acctStore: AccountStore,
        claudeJSONURL: URL? = nil
    ) throws -> AccountID {
        // Dedup: reuse the first pool account with identical credential content.
        for existing in try acctStore.list(tool: tool) {
            if storedCredential(of: existing, acctStore: acctStore) == credential {
                var refreshed = existing
                if refreshed.refreshInfo(accountStore: acctStore) {
                    do {
                        try acctStore.save(refreshed)
                    } catch {
                        FileHandle.standardError.write(Data(
                            "[orrery migration] warning: could not save refreshed info for account '\(existing.displayName)': \(error)\n".utf8
                        ))
                    }
                }
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

        // Capture email/plan into the freshly-created Account so `list` / `show`
        // don't have to re-parse on first use.
        account.refreshInfo(accountStore: acctStore)
        try acctStore.save(account)
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

    // MARK: - One-shot retroactive info backfill (v1)

    /// Flag file marking the one-shot account-info backfill as done.
    public static let infoBackfillFlagFileName = ".backfill-account-info-v1"

    /// Best-effort: walks every pool account and backfills `email`/`plan` from
    /// whatever sources are now available. Guarded by a flag file so it only
    /// runs once. Never throws — failures are warnings.
    ///
    /// For Claude accounts whose `email` is still nil, scans envs that reference
    /// the account (`EnvironmentStore.envsReferencing`) to find a `.claude.json`
    /// from which to harvest the email.
    public static func runInfoBackfillIfNeeded(homeURL: URL) {
        let fm = FileManager.default
        let flagURL = homeURL.appendingPathComponent(infoBackfillFlagFileName)
        if fm.fileExists(atPath: flagURL.path) { return }
        // No home means nothing to scan — but still no-op (the next call will
        // also see no home, so we don't write the flag prematurely).
        guard fm.fileExists(atPath: homeURL.path) else { return }

        let acctStore = AccountStore(homeURL: homeURL)

        for tool in Tool.allCases {
            let accounts: [Account]
            do { accounts = try acctStore.list(tool: tool) } catch { continue }

            for account in accounts {
                var updated = account
                let credChanged = updated.refreshInfo(accountStore: acctStore)

                if credChanged {
                    do {
                        try acctStore.save(updated)
                    } catch {
                        FileHandle.standardError.write(Data(
                            "[orrery backfill] warning: could not save account '\(account.displayName)': \(error)\n".utf8
                        ))
                    }
                }
            }
        }

        // Write the flag last so a partial run can retry.
        do {
            try Data("v1\n".utf8).write(to: flagURL)
        } catch {
            FileHandle.standardError.write(Data(
                "[orrery backfill] warning: could not write flag file: \(error)\n".utf8
            ))
        }
    }

    // MARK: - One-shot v3.1 account-layout migration

    /// Flag file marking the one-shot workspace account-symlink migration as done.
    public static let workspaceAccountSymlinksFlagFileName = ".workspace-account-symlinks"

    /// Phase B: rebuild every claude pool account's workspace symlinks against the
    /// unified workspaces/<ws>/claude/ layout. Runs AFTER the account pool exists.
    /// Replaces rc.1's runV31AccountLayoutIfNeeded. Best-effort: never throws.
    public static func runWorkspaceAccountSymlinksIfNeeded(homeURL: URL) {
        let fm = FileManager.default
        let flag = homeURL.appendingPathComponent(workspaceAccountSymlinksFlagFileName)
        if fm.fileExists(atPath: flag.path) { return }
        guard fm.fileExists(atPath: homeURL.path) else { return }

        let acctStore = AccountStore(homeURL: homeURL)
        let envStore = EnvironmentStore(homeURL: homeURL)

        let accounts: [Account]
        do { accounts = try acctStore.list(tool: .claude) }
        catch {
            FileHandle.standardError.write(Data(
                "[orrery workspace symlinks] could not list claude accounts: \(error)\n".utf8))
            return
        }

        for acct in accounts {
            do {
                try ClaudeAccountMigration.migrateAccount(
                    acct, accountStore: acctStore, environmentStore: envStore)
            } catch {
                FileHandle.standardError.write(Data(
                    "[orrery workspace symlinks] could not migrate '\(acct.displayName)': \(error)\n".utf8))
            }
        }

        do { try Data("v1\n".utf8).write(to: flag) }
        catch {
            FileHandle.standardError.write(Data(
                "[orrery workspace symlinks] could not write flag: \(error)\n".utf8))
        }
    }

    // MARK: - Phase C: consolidate config into the account dir

    /// Flag marking the one-shot account-config consolidation as done.
    public static let accountConfigConsolidatedFlagFileName = ".account-config-consolidated"

    /// Phase C: make each claude account dir the authoritative config home.
    ///
    /// The origin takeover captured the user's real `settings.json` (permissions,
    /// hooks, env, plugins, …) into the workspace, but Claude reads settings from
    /// the *account* dir (`CLAUDE_CONFIG_DIR`). This folds the workspace settings
    /// into each pinned account's `settings.json` so the account dir is complete —
    /// a prerequisite for pointing `~/.claude` at the origin account dir. The
    /// workspace then only needs to hold the shared session/memory folders that
    /// account dirs symlink into.
    ///
    /// Best-effort, flag-guarded, never throws. Does not delete the workspace
    /// copies (they become harmless orphans).
    public static func runAccountConfigConsolidationIfNeeded(homeURL: URL) {
        let fm = FileManager.default
        let flag = homeURL.appendingPathComponent(accountConfigConsolidatedFlagFileName)
        if fm.fileExists(atPath: flag.path) { return }
        guard fm.fileExists(atPath: homeURL.path) else { return }

        consolidateClaudeAccountSettings(homeURL: homeURL)
        repointDefaultClaudeDirToOriginAccount(homeURL: homeURL)

        do { try Data("v1\n".utf8).write(to: flag) }
        catch {
            FileHandle.standardError.write(Data(
                "[orrery config consolidation] could not write flag: \(error)\n".utf8))
        }
    }

    /// The claude account dir that `~/.claude` should point at: the account
    /// pinned to the origin workspace. Returns nil if there is no origin claude
    /// pin or its dir isn't built yet. Pure path resolution — does not touch `~`.
    static func originAccountClaudeDir(homeURL: URL) -> URL? {
        let envStore = EnvironmentStore(homeURL: homeURL)
        guard let originID = envStore.loadOriginWorkspace().account(for: .claude) else { return nil }
        let dir = AccountStore(homeURL: homeURL).accountDir(id: originID, tool: .claude)
        guard FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("metadata.json").path) else { return nil }
        return dir
    }

    /// Repoint the real `~/.claude` at the origin account dir, so bare/origin
    /// claude (no `CLAUDE_CONFIG_DIR`) reads the same account dir that
    /// `orrery use` selects.
    private static func repointDefaultClaudeDirToOriginAccount(homeURL: URL) {
        repointClaudeDirSymlink(link: Tool.claude.defaultConfigDir, homeURL: homeURL)
    }

    /// Point `link` at the origin account dir. Guarded: only acts when `link` is
    /// currently the takeover-managed symlink into this home's workspace claude
    /// dir — never clobbers a real directory or a foreign symlink target.
    /// `link` is parameterized so the logic is unit-testable without touching the
    /// real `~/.claude`.
    static func repointClaudeDirSymlink(link: URL, homeURL: URL) {
        let fm = FileManager.default
        guard let target = originAccountClaudeDir(homeURL: homeURL) else { return }

        guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) else { return }
        if dest == target.path { return }   // already correct

        // Only repoint the exact takeover symlink (→ this home's workspace claude dir).
        let workspaceClaude = EnvironmentStore(homeURL: homeURL).originConfigDir(tool: .claude).path
        guard dest == workspaceClaude else { return }

        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(at: link, withDestinationURL: target)
    }

    /// Merge each claude account's pinned-workspace `settings.json` into the
    /// account dir's `settings.json`. Account values win; `statusLine` is never
    /// carried over from the workspace (it is per-account, owned by `orrery
    /// install`, and the workspace copy is typically a stale path).
    static func consolidateClaudeAccountSettings(homeURL: URL) {
        let acctStore = AccountStore(homeURL: homeURL)
        let envStore = EnvironmentStore(homeURL: homeURL)
        let accounts = (try? acctStore.list(tool: .claude)) ?? []

        for acct in accounts {
            let accountSettings = acctStore.accountDir(id: acct.id, tool: .claude)
                .appendingPathComponent("settings.json")
            let workspaceSettings = envStore.claudeWorkspaceDir(workspace: acct.workspace)
                .appendingPathComponent("settings.json")

            // Nothing captured in the workspace → nothing to consolidate.
            guard let wsObj = ClaudeJsonMerge.loadJSON(at: workspaceSettings) else { continue }
            let acctObj = ClaudeJsonMerge.loadJSON(at: accountSettings) ?? [:]
            let merged = mergedClaudeSettings(workspace: wsObj, account: acctObj)
            try? ClaudeJsonMerge.saveJSON(merged, at: accountSettings)
        }
    }

    /// Pure merge: workspace settings as the base (minus `statusLine`), with the
    /// account's own settings overlaid on top (account keys win).
    static func mergedClaudeSettings(
        workspace: [String: Any], account: [String: Any]
    ) -> [String: Any] {
        var result = workspace
        // statusLine is per-account (installed via `orrery install`); never inherit
        // the workspace's, which points at a stale/foreign script path.
        result.removeValue(forKey: "statusLine")
        for (key, value) in account { result[key] = value }
        return result
    }

    // MARK: - Phase A: workspace structure relocation (runs before origin takeover)

    public static let workspaceStructureFlagFileName = ".workspace-structure-relocated"

    /// One-shot relocation of the v3.0.x tree to the unified `workspaces/` layout.
    /// Runs BEFORE OriginTakeoverBootstrap so takeover sees the new locations.
    /// Best-effort: never throws.
    public static func runWorkspaceStructureRelocationIfNeeded(homeURL: URL) {
        let fm = FileManager.default
        let flag = homeURL.appendingPathComponent(workspaceStructureFlagFileName)
        if fm.fileExists(atPath: flag.path) { return }
        guard fm.fileExists(atPath: homeURL.path) else { return }

        let oldEnvs = homeURL.appendingPathComponent("envs")
        let newWorkspaces = homeURL.appendingPathComponent("workspaces")
        let oldOrigin = homeURL.appendingPathComponent("origin")
        let newOrigin = newWorkspaces.appendingPathComponent("origin")

        func warn(_ m: String) {
            FileHandle.standardError.write(Data("[orrery workspace relocation] \(m)\n".utf8))
        }

        // 1. envs/ -> workspaces/ (only if workspaces/ doesn't already exist).
        if fm.fileExists(atPath: oldEnvs.path) && !fm.fileExists(atPath: newWorkspaces.path) {
            do { try fm.moveItem(at: oldEnvs, to: newWorkspaces) }
            catch { warn("could not move envs/ -> workspaces/: \(error)") }
        }
        try? fm.createDirectory(at: newWorkspaces, withIntermediateDirectories: true)

        // 2. origin/ -> workspaces/origin/ (do not overwrite an existing target —
        //    only possible from an rc artifact, never for real users).
        if fm.fileExists(atPath: oldOrigin.path) {
            if fm.fileExists(atPath: newOrigin.path) {
                warn("workspaces/origin already exists; leaving legacy origin/ in place")
            } else {
                do {
                    try fm.moveItem(at: oldOrigin, to: newOrigin)
                    // Repoint ~/.claude (and codex/gemini if origin-managed) to the new root.
                    let store = EnvironmentStore(homeURL: homeURL)
                    for tool in Tool.allCases {
                        let link = tool.defaultConfigDir
                        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path),
                           dest.contains("/origin/\(tool.subdirectory)"),
                           !dest.contains("/workspaces/origin/") {
                            try? fm.removeItem(at: link)
                            try? fm.createSymbolicLink(at: link, withDestinationURL: store.originConfigDir(tool: tool))
                        }
                    }
                } catch { warn("could not move origin/ -> workspaces/origin/: \(error)") }
            }
        }

        // 3. Per-workspace dir: env.json/config.json -> workspace.json;
        //    fold rc-artifact claude-workspace/ into claude/.
        if let dirs = try? fm.contentsOfDirectory(atPath: newWorkspaces.path) {
            for dir in dirs {
                let wsDir = newWorkspaces.appendingPathComponent(dir)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: wsDir.path, isDirectory: &isDir), isDir.boolValue else { continue }

                for legacy in ["env.json", "config.json"] {
                    let from = wsDir.appendingPathComponent(legacy)
                    let to = wsDir.appendingPathComponent("workspace.json")
                    if fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) {
                        try? fm.moveItem(at: from, to: to)
                    }
                }

                let cw = wsDir.appendingPathComponent("claude-workspace")
                let claude = wsDir.appendingPathComponent("claude")
                if fm.fileExists(atPath: cw.path) {
                    if !fm.fileExists(atPath: claude.path) {
                        try? fm.moveItem(at: cw, to: claude)
                    } else {
                        // merge subdirs that don't already exist, then remove
                        let subs = (try? fm.contentsOfDirectory(atPath: cw.path)) ?? []
                        for s in subs {
                            let src = cw.appendingPathComponent(s)
                            let dst = claude.appendingPathComponent(s)
                            if !fm.fileExists(atPath: dst.path) { try? fm.moveItem(at: src, to: dst) }
                        }
                        try? fm.removeItem(at: cw)
                    }
                }
            }
        }

        do { try Data("v1\n".utf8).write(to: flag) }
        catch { warn("could not write flag: \(error)") }
    }
}
