import Foundation

/// v3.1: brings one v3.0.4 claude pool account up to the per-account-dir
/// layout introduced by Plan 1.
///
/// Purely additive:
/// - Creates the workspace-pointing symlinks via `AccountDirectoryRuntime`'s
///   registered claude manager (`ClaudeAdapter.prepareDirectory`, in OrreryAccountKit)
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

        // Build account dir + symlinks (idempotent).
        try AccountDirectoryRuntime.manager(for: .claude).prepareDirectory(
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

        // Seed whatever account identity we already know, then overlay the
        // credential's token fields on top. Same schema rule as
        // `PrepareClaudeLaunchCommand`: `oauthAccount` carries identity
        // (emailAddress, and whatever claude later adds — accountUuid,
        // organizationUuid, …) while the credential blob carries only tokens.
        // Assigning one over the other drops the other half; see
        // `ClaudeJsonMerge.overlayingOAuthCredential`.
        var oauthAccount: [String: Any] = [:]
        if let email = account.email {
            oauthAccount["emailAddress"] = email
        }

        // Load full OAuth credentials from keychain/credentials file if available.
        // This preserves refreshToken/accessToken so users don't need to re-login.
        #if os(macOS)
        if let keychainItem = account.keychainItem,
           let credJSON = ClaudeKeychain.password(forService: keychainItem),
           let credData = credJSON.data(using: .utf8),
           let credObj = try? JSONSerialization.jsonObject(with: credData) as? [String: Any],
           let fullOauth = credObj["claudeAiOauth"] as? [String: Any] {
            oauthAccount = ClaudeJsonMerge.overlayingOAuthCredential(
                fullOauth, onto: oauthAccount)
        }
        #else
        // Linux: try .credentials.json
        let credURL = poolDir.appendingPathComponent(".credentials.json")
        if let credData = try? Data(contentsOf: credURL),
           let credObj = try? JSONSerialization.jsonObject(with: credData) as? [String: Any],
           let fullOauth = credObj["claudeAiOauth"] as? [String: Any] {
            oauthAccount = ClaudeJsonMerge.overlayingOAuthCredential(
                fullOauth, onto: oauthAccount)
        }
        #endif

        if !oauthAccount.isEmpty {
            identity["oauthAccount"] = oauthAccount
        }

        try ClaudeJsonMerge.saveJSON(identity, at: identityURL)
    }
}
