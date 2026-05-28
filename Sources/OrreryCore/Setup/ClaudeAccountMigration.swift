import Foundation

/// v3.1: brings one v3.0.4 claude pool account up to the per-account-dir
/// layout introduced by Plan 1.
///
/// Purely additive:
/// - Creates the 5 workspace-pointing symlinks via `ClaudeAccountDirectory.prepareDirectory`
/// - Seeds `claude-identity.json` (account dir) from `Account.email` if available,
///   else writes an empty `{}`.
///
/// Does NOT move, copy, or delete any existing v3.0.4 state — credentials remain
/// in the macOS Keychain / `.credentials.json` exactly where v3.0.4 put them.
/// The v3.0.4 `materialize`/`syncBack` path continues to work for accounts that
/// haven't been migrated yet; Plan 4 removes those once everyone is on v3.1.
///
/// Idempotent: re-running on an already-migrated account is a no-op (won't
/// clobber the live identity file).
public enum ClaudeAccountMigration {

    public static func migrateAccount(
        _ account: Account,
        accountStore: AccountStore,
        environmentStore: EnvironmentStore
    ) throws {
        precondition(account.tool == .claude,
            "ClaudeAccountMigration only handles claude accounts")

        // Build account dir + 5 symlinks (idempotent).
        try ClaudeAccountDirectory.prepareDirectory(
            account: account,
            accountStore: accountStore,
            environmentStore: environmentStore
        )

        // Seed claude-identity.json from Account.email if available, else empty {}.
        let poolDir = accountStore.accountDir(id: account.id, tool: .claude)
        let identityURL = ClaudeJsonMerge.identityFileURL(accountDir: poolDir)

        // Don't clobber an existing identity file (migration is idempotent
        // and the live file may have post-migration data from a prior session).
        if FileManager.default.fileExists(atPath: identityURL.path) {
            return
        }

        var identity: [String: Any] = [:]
        if let email = account.email {
            identity["oauthAccount"] = ["emailAddress": email]
        }

        try ClaudeJsonMerge.saveJSON(identity, at: identityURL)
    }
}
