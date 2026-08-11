import Foundation

// macOS-only: depends on `ClaudeKeychain`'s Keychain-backed OAuth accessors,
// which only exist under `#if os(macOS)`.
#if os(macOS)

/// Sweeps Claude accounts, refreshing any whose access token is near
/// expiry by exchanging the stored refresh token directly with Anthropic's
/// OAuth endpoint — bypassing the upstream Claude Code CLI's own (buggy,
/// see https://github.com/anthropics/claude-code/issues/50743 and similar)
/// refresh logic entirely. Shared by the background daemon
/// (`RefreshTokensCommand`) and the manual escape hatch
/// (`AccountRefreshTokenCommand`).
struct TokenRefreshRunner: Sendable {
    var oauthCredential: @Sendable (_ service: String) -> ClaudeKeychain.OAuthCredential?
    var updateCredential: @Sendable (
        _ service: String,
        _ accessToken: String,
        _ refreshToken: String,
        _ expiresAt: Date
    ) -> Bool
    var transport: TokenRefreshTransport
    var now: @Sendable () -> Date
    var accountDir: @Sendable (_ account: Account) -> URL

    static let live = TokenRefreshRunner(
        oauthCredential: ClaudeKeychain.oauthCredential(forService:),
        updateCredential: ClaudeKeychain.updateOAuthCredential(forService:accessToken:refreshToken:expiresAt:),
        transport: .live,
        now: Date.init,
        accountDir: { account in AccountStore.default.accountDir(id: account.id, tool: account.tool) }
    )

    enum Outcome: Sendable, Equatable {
        case refreshed
        case skipped
        case failed(String)
    }

    /// Refresh every account whose access token is within `threshold` of
    /// expiring, or every account unconditionally when `force` is true.
    /// Never throws; one account's failure never stops the sweep for the
    /// rest (matches the best-effort idiom used by `OriginAccountSeeder`
    /// and `AccountMigration`).
    func sweep(accounts: [Account], threshold: TimeInterval, force: Bool = false) -> [(Account, Outcome)] {
        accounts.map { account in (account, refreshIfNeeded(account, threshold: threshold, force: force)) }
    }

    private func refreshIfNeeded(_ account: Account, threshold: TimeInterval, force: Bool) -> Outcome {
        guard let service = account.keychainItem else { return .skipped }
        guard let credential = oauthCredential(service) else { return .skipped }
        guard force || credential.expiresAt.timeIntervalSince(now()) < threshold else {
            return .skipped
        }

        switch transport.refresh(credential.refreshToken) {
        case .failure(let reason):
            return .failed(reason)

        case .success(let accessToken, let refreshToken, let expiresIn):
            let newExpiresAt = now().addingTimeInterval(expiresIn)
            guard updateCredential(service, accessToken, refreshToken, newExpiresAt) else {
                return .failed("refreshed but failed to write back to Keychain")
            }
            patchIdentityFileIfPresent(
                for: account,
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: newExpiresAt
            )
            return .refreshed
        }
    }

    /// `claude-identity.json`'s `oauthAccount` is only re-hydrated from
    /// Keychain by `PrepareClaudeLaunchCommand` when `refreshToken` is
    /// *missing* from it, not when it's merely stale — so a Keychain-only
    /// refresh can leave an already-launched account serving a dead,
    /// rotated-out token until that account happens to lose the key
    /// entirely. Keep both copies in sync whenever the identity file
    /// already exists for this account.
    private func patchIdentityFileIfPresent(
        for account: Account,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date
    ) {
        let identityURL = ClaudeJsonMerge.identityFileURL(accountDir: accountDir(account))
        guard var identity = ClaudeJsonMerge.loadJSON(at: identityURL),
              var oauthAccount = identity["oauthAccount"] as? [String: Any]
        else { return }

        oauthAccount["accessToken"] = accessToken
        oauthAccount["refreshToken"] = refreshToken
        oauthAccount["expiresAt"] = Int64((expiresAt.timeIntervalSince1970 * 1000).rounded())
        identity["oauthAccount"] = oauthAccount

        try? ClaudeJsonMerge.saveJSON(identity, at: identityURL)
    }
}

#endif
