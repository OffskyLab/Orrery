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
    /// The tools that existed when the pre-per-tool flag markers were written,
    /// and therefore the set a legacy marker in one of the all-tool migrations
    /// stands for. A fixed historical fact, not `Tool.allCases` — the point is
    /// that it must NOT grow as tools are added, or a legacy marker would keep
    /// claiming to have covered whatever is newest.
    static let legacyBuiltInTools: Set<String> = ["claude", "codex", "gemini"]

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
        let flag = MigrationFlag(
            url: homeURL.appendingPathComponent(flagFileName),
            legacyCoverage: legacyBuiltInTools)
        let toolIDs = Set(Tool.allCases.map(\.rawValue))
        let pending = flag.pending(among: toolIDs)

        // Already migrated.
        if pending.isEmpty { return }

        // Nothing to migrate: home doesn't exist, or has neither workspaces nor legacy envs/origin.
        // Phase A migration (if needed) runs before this, so check both old and new paths.
        let envsURL = homeURL.appendingPathComponent("envs")
        let originURL = homeURL.appendingPathComponent("origin")
        let workspacesURL = homeURL.appendingPathComponent("workspaces")
        let hasLegacy = fm.fileExists(atPath: envsURL.path) || fm.fileExists(atPath: originURL.path)
        let hasWorkspaces = fm.fileExists(atPath: workspacesURL.path)
        guard fm.fileExists(atPath: homeURL.path), hasLegacy || hasWorkspaces else {
            // Fresh install (or home not created yet) — mark done so we never
            // rescan. Records the same pending set as the real migration path
            // below, not a bare marker: a bare marker reads back as covering
            // every tool forever, including tools that do not exist yet, and
            // this is the one place that shape survived.
            if fm.fileExists(atPath: homeURL.path) {
                try flag.markCovered(pending)
            }
            return
        }

        // Refuse to migrate while a phantom-supervised session is live. This
        // used to check `ORRERY_PHANTOM_SHELL_PID`, an env var the shim no
        // longer sets — so it now queries the phantom registry directly for
        // any live supervisor entry. Unlike the old env check, this IS a
        // system-wide detector: the registry is shared on disk under
        // `homeURL`, so it also catches a supervisor running in a different
        // terminal/shell. The pre-migration backup remains the real safety
        // net regardless (see report notes).
        let livePhantomEntries = PhantomRegistry(homeURL: homeURL)
            .liveEntries(isAlive: ProcessLiveness.isAlive)
        if !livePhantomEntries.isEmpty {
            let message = """
                [orrery migration] A phantom-supervised session is active.
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

        // 2. Migrate origin + every named env, every tool still pending.
        for tool in Tool.allCases where pending.contains(tool.rawValue) {
            try migrateOrigin(tool: tool, envStore: envStore, acctStore: acctStore)
            for envName in try envStore.listNames() {
                try migrateEnv(envName: envName, tool: tool, envStore: envStore, acctStore: acctStore)
            }
        }

        // 3. Mark done.
        try flag.markCovered(pending)
    }

    // MARK: - Flag / backup

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
        let flag = MigrationFlag(
            url: homeURL.appendingPathComponent(infoBackfillFlagFileName),
            legacyCoverage: legacyBuiltInTools)
        let toolIDs = Set(Tool.allCases.map(\.rawValue))
        let pending = flag.pending(among: toolIDs)
        if pending.isEmpty { return }
        // No home means nothing to scan — but still no-op (the next call will
        // also see no home, so we don't write the flag prematurely).
        guard fm.fileExists(atPath: homeURL.path) else { return }

        let acctStore = AccountStore(homeURL: homeURL)

        for tool in Tool.allCases where pending.contains(tool.rawValue) {
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
            try flag.markCovered(pending)
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
        let flag = MigrationFlag(
            url: homeURL.appendingPathComponent(workspaceAccountSymlinksFlagFileName),
            // This migration only ever walked claude accounts, so its
            // legacy marker says nothing about codex or gemini.
            legacyCoverage: [Tool.claude.rawValue])
        // Scoped to claude alone, because that is all the body below touches.
        // A `Tool.allCases` pending set here would record coverage for codex
        // and gemini on a run that never looked at them, so a later version
        // that does handle them would find the work already marked done.
        let pending = flag.pending(among: [Tool.claude.rawValue])
        if pending.isEmpty { return }
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

        do { try flag.markCovered(pending) }
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
        let flag = MigrationFlag(
            url: homeURL.appendingPathComponent(accountConfigConsolidatedFlagFileName),
            legacyCoverage: legacyBuiltInTools)
        let toolIDs = Set(Tool.allCases.map(\.rawValue))
        let pending = flag.pending(among: toolIDs)
        if pending.isEmpty { return }
        guard fm.fileExists(atPath: homeURL.path) else { return }

        consolidateClaudeAccountSettings(homeURL: homeURL, pending: pending)

        do { try flag.markCovered(pending) }
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

    /// Ongoing invariant (runs every invocation, NOT flag-guarded): keep the
    /// origin workspace pinned and `~/.claude` pointing at the origin account dir.
    /// The takeover (legacy behaviour) leaves `~/.claude` pointing at the
    /// workspace; this corrects it to the account dir as soon as that dir exists,
    /// and re-pins a lost "origin" pin. Because it runs every time, an install
    /// that finds `~/.claude` still on the old workspace target self-heals on the
    /// next `orrery` command rather than waiting on a one-shot migration flag.
    /// Idempotent and cheap; never throws.
    public static func enforceOriginClaudeDir(homeURL: URL) {
        guard FileManager.default.fileExists(atPath: homeURL.path) else { return }
        repairOriginPins(homeURL: homeURL)
        repointClaudeDirSymlink(link: Tool.claude.defaultConfigDir, homeURL: homeURL)
    }

    /// Ongoing invariant (runs every invocation, NOT flag-guarded): repair a
    /// home dotfile (`~/.claude`, `~/.codex`, `~/.gemini`) that has become a
    /// DANGLING symlink, pointing it back at this home's origin workspace dir
    /// for that tool.
    ///
    /// The origin takeover owns those paths, but nothing stops another process
    /// running as the same user from repointing them. A manual verification
    /// script aimed all three at `/tmp/orrery-dispatch-test/...`; once that
    /// scratch tree was cleaned up every link dangled, and the tools started
    /// failing against a path the user never chose — gemini-cli's `mkdir`
    /// follows the link and reports `ENOENT` for a directory it cannot
    /// explain. `repointClaudeDirSymlink` below could not rescue any of it: it
    /// only ever touches a link already aimed at the workspace dir.
    ///
    /// Only a dangling link is repaired. A link whose target exists may be a
    /// deliberate choice holding real data, and a real directory certainly is
    /// — both are left exactly as found. A dangling link, by definition,
    /// protects nothing.
    public static func healDanglingOriginSymlinks(homeURL: URL) {
        for tool in Tool.allCases {
            healDanglingOriginSymlink(link: tool.defaultConfigDir, tool: tool, homeURL: homeURL)
        }
    }

    /// The per-tool repair, taking `link` as a plain parameter so it is
    /// testable without touching the real `~/.<tool>` — `tool.defaultConfigDir`
    /// resolves through `userHomeURL()`, which a test cannot redirect merely by
    /// passing a different `homeURL` (the defect fixed in af08548).
    static func healDanglingOriginSymlink(link: URL, tool: Tool, homeURL: URL) {
        let fm = FileManager.default

        // Not a symlink (missing path, or a real directory) → nothing to heal.
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) else { return }

        // A relative target resolves against the link's own directory.
        let resolved = dest.hasPrefix("/")
            ? URL(fileURLWithPath: dest)
            : link.deletingLastPathComponent().appendingPathComponent(dest)
        guard !fm.fileExists(atPath: resolved.path) else { return }   // target is live → leave it

        let target = EnvironmentStore(homeURL: homeURL).originConfigDir(tool: tool)
        guard (try? fm.createDirectory(at: target, withIntermediateDirectories: true)) != nil
        else { return }

        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(at: link, withDestinationURL: target)
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
    ///
    /// - Parameter pending: the tool ids the caller's flag guard has not yet
    ///   marked covered. Threaded through rather than recomputed here — and
    ///   required, not defaulted, so a call site can never silently drift
    ///   from the flag it is meant to agree with. Callers outside the
    ///   flag-guarded entry point (e.g. tests exercising the consolidation
    ///   logic itself) pass `Set(Tool.allCases.map(\.rawValue))` explicitly
    ///   to mean "unconditional."
    static func consolidateClaudeAccountSettings(
        homeURL: URL, pending: Set<String>
    ) {
        guard pending.contains(Tool.claude.rawValue) else { return }
        let acctStore = AccountStore(homeURL: homeURL)
        let envStore = EnvironmentStore(homeURL: homeURL)
        let accounts = (try? acctStore.list(tool: .claude)) ?? []

        for acct in accounts {
            let accountSettings = acctStore.accountDir(id: acct.id, tool: .claude)
                .appendingPathComponent("settings.json")
            let workspaceSettings = envStore.toolConfigDir(tool: .claude, environment: acct.workspace)
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
        // statusLine is per-account (installed via `orrery thirdparty install`); never inherit
        // the workspace's, which points at a stale/foreign script path.
        result.removeValue(forKey: "statusLine")
        for (key, value) in account { result[key] = value }
        return result
    }

    // MARK: - Origin pin repair (upgraded / 3.0.4-damaged installs)

    /// Pin the pool account named "origin" to the origin workspace for any tool
    /// that currently has no pin. The v2→v3 migration names the origin-scope
    /// account "origin", so its display name is the reliable recovery key when
    /// the workspace's pins were lost. Pure store mutation — does not touch `~`.
    static func repairOriginPins(homeURL: URL) {
        let acctStore = AccountStore(homeURL: homeURL)
        let envStore = EnvironmentStore(homeURL: homeURL)

        var origin = envStore.loadOriginWorkspace()
        var changed = false
        for tool in Tool.allCases {
            if origin.account(for: tool) != nil { continue }   // already pinned
            if let acct = try? acctStore.findByDisplayName("origin", tool: tool) {
                origin.setAccount(acct.id, for: tool)
                changed = true
            }
        }
        if changed { try? envStore.saveOriginWorkspace(origin) }
    }

    // MARK: - Phase A: workspace structure relocation (runs before origin takeover)

    public static let workspaceStructureFlagFileName = ".workspace-structure-relocated"

    /// One-shot relocation of the v3.0.x tree to the unified `workspaces/` layout.
    /// Runs BEFORE OriginTakeoverBootstrap so takeover sees the new locations.
    /// Best-effort: never throws.
    public static func runWorkspaceStructureRelocationIfNeeded(homeURL: URL) {
        let fm = FileManager.default
        let flag = MigrationFlag(
            url: homeURL.appendingPathComponent(workspaceStructureFlagFileName),
            legacyCoverage: legacyBuiltInTools)
        let toolIDs = Set(Tool.allCases.map(\.rawValue))
        let pending = flag.pending(among: toolIDs)
        if pending.isEmpty { return }
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
        // The move is global and succeeds exactly once.
        if fm.fileExists(atPath: oldOrigin.path) {
            if fm.fileExists(atPath: newOrigin.path) {
                warn("workspaces/origin already exists; leaving legacy origin/ in place")
            } else {
                do { try fm.moveItem(at: oldOrigin, to: newOrigin) }
                catch { warn("could not move origin/ -> workspaces/origin/: \(error)") }
            }
        }

        // Repointing a tool's home symlink is per-tool and can be owed later, so
        // it must NOT live inside the move branch above. A tool that was not
        // registered on the run that did the move becomes pending on a later
        // run, and by then `origin/` is gone — so nesting this under
        // `fileExists(oldOrigin)` made the repair unreachable for exactly the
        // tools per-tool flags exist to protect.
        //
        // Only ids whose link is genuinely settled are collected. A tool whose
        // repair fails stays out of `repaired`, so it stays pending and can be
        // retried; the old code marked the whole `pending` set covered whether
        // or not anything had been repaired.
        var repaired: Set<String> = []
        let store = EnvironmentStore(homeURL: homeURL)
        for tool in Tool.allCases where pending.contains(tool.rawValue) {
            let link = tool.defaultConfigDir
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path),
                  dest.contains("/origin/\(tool.subdirectory)"),
                  !dest.contains("/workspaces/origin/")
            else {
                // Nothing pointing at the pre-move location: either already
                // correct, not a symlink, or this tool was never origin-managed.
                // Either way there is no work owed, so it counts as settled.
                repaired.insert(tool.rawValue)
                continue
            }
            do {
                try fm.removeItem(at: link)
                try fm.createSymbolicLink(
                    at: link, withDestinationURL: store.originConfigDir(tool: tool))
                repaired.insert(tool.rawValue)
            } catch {
                warn("could not repoint \(link.path) for \(tool.rawValue): \(error)")
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

        // Only what actually got settled. Marking the whole pending set here
        // would tell a tool whose repair failed that it had nothing left to do.
        do { try flag.markCovered(repaired) }
        catch { warn("could not write flag: \(error)") }
    }
}
