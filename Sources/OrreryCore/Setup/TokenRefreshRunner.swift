import Foundation

// The only platform-specific piece: how a credential is read/written.
// macOS uses the Keychain; Linux uses `.credentials.json` files, reusing
// the same pure JSON logic from `ClaudeKeychain`.
#if os(macOS)
private let liveOAuthCredential: @Sendable (String) -> ClaudeKeychain.OAuthCredential? =
    ClaudeKeychain.oauthCredential(forService:)
private let liveUpdateCredential: @Sendable (String, String, String, Date) -> Bool =
    ClaudeKeychain.updateOAuthCredential(forService:accessToken:refreshToken:expiresAt:)
#else
private let liveOAuthCredential: @Sendable (String) -> ClaudeKeychain.OAuthCredential? = { path in
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let json = String(data: data, encoding: .utf8)
    else { return nil }
    return ClaudeKeychain.parseOAuthCredential(json: json)
}
private let liveUpdateCredential: @Sendable (String, String, String, Date) -> Bool = { path, accessToken, refreshToken, expiresAt in
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let json = String(data: data, encoding: .utf8),
          let newJSON = ClaudeKeychain.applyingOAuthUpdate(
            toJSON: json, accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt
          ),
          let newData = newJSON.data(using: .utf8)
    else { return false }
    return (try? newData.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
}
#endif

/// Sweeps Claude accounts, refreshing any whose access token is near
/// expiry by exchanging the stored refresh token directly with Anthropic's
/// OAuth endpoint — bypassing the upstream Claude Code CLI's own (buggy,
/// see https://github.com/anthropics/claude-code/issues/50743 and similar)
/// refresh logic entirely. Shared by the background agent (`orrery-agent`)
/// and the manual escape hatch (`RefreshTokenCommand`).
///
/// Platform-agnostic by design: the only thing that differs between macOS
/// (Keychain) and Linux (`.credentials.json` file) is *how a credential is
/// read/written* (`liveOAuthCredential`/`liveUpdateCredential` above) — the
/// sweep/threshold/refresh logic itself is a single shared implementation.
public struct TokenRefreshRunner: Sendable {
    var oauthCredential: @Sendable (_ identifier: String) -> ClaudeKeychain.OAuthCredential?
    var updateCredential: @Sendable (
        _ identifier: String,
        _ accessToken: String,
        _ refreshToken: String,
        _ expiresAt: Date
    ) -> Bool
    var transport: TokenRefreshTransport
    var now: @Sendable () -> Date
    var accountDir: @Sendable (_ account: Account) -> URL

    public static let live = TokenRefreshRunner(
        oauthCredential: liveOAuthCredential,
        updateCredential: liveUpdateCredential,
        transport: .live,
        now: Date.init,
        accountDir: { account in AccountStore.default.accountDir(id: account.id, tool: account.tool) }
    )

    public enum Outcome: Sendable, Equatable {
        case refreshed
        case skipped
        case failed(String)
    }

    /// Refresh every account whose access token is within `threshold` of
    /// expiring, or every account unconditionally when `force` is true.
    /// Never throws; one account's failure never stops the sweep for the
    /// rest (matches the best-effort idiom used by `OriginAccountSeeder`
    /// and `AccountMigration`).
    public func sweep(accounts: [Account], threshold: TimeInterval, force: Bool = false) -> [(Account, Outcome)] {
        accounts.map { account in (account, refreshIfNeeded(account, threshold: threshold, force: force)) }
    }

    /// Accounts the *background* daemon may proactively refresh — excludes
    /// `originAccountID`, since the origin account's pool credential is a
    /// one-time copy of the real, live Claude Code credential made at seed
    /// time (`OriginAccountSeeder`), sharing the same refresh token at that
    /// instant. Anthropic's refresh tokens are single-use/rotating and
    /// nothing syncs this pool copy's rotations back to the live item, so a
    /// daemon-initiated refresh here would silently invalidate the refresh
    /// token the user's real, non-orrery Claude Code CLI still holds — the
    /// origin account is left to refresh itself the normal way instead.
    /// Manual refreshes (`orrery refresh-token`) are unaffected — they call
    /// `sweep` directly and may still target the origin account on purpose.
    public static func excludingOrigin(_ accounts: [Account], originAccountID: AccountID?) -> [Account] {
        accounts.filter { $0.id != originAccountID }
    }

    private func refreshIfNeeded(_ account: Account, threshold: TimeInterval, force: Bool) -> Outcome {
        #if os(macOS)
        // macOS: the Keychain service name Account already carries.
        guard let identifier = account.keychainItem else { return .skipped }
        #else
        // Linux: the pool account's `.credentials.json`, matching the
        // convention already used by `ClaudeKeychain.accountInfo(forPoolAccount:poolDir:)`.
        let identifier = accountDir(account).appendingPathComponent(".credentials.json").path
        #endif

        guard let credential = oauthCredential(identifier) else { return .skipped }
        guard force || credential.expiresAt.timeIntervalSince(now()) < threshold else {
            return .skipped
        }

        switch transport.refresh(credential.refreshToken) {
        case .failure(let reason):
            return .failed(reason)

        case .success(let accessToken, let refreshToken, let expiresIn):
            let newExpiresAt = now().addingTimeInterval(expiresIn)
            guard updateCredential(identifier, accessToken, refreshToken, newExpiresAt) else {
                return .failed("refreshed but failed to write back the credential")
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

    /// `claude-identity.json`'s `oauthAccount` is only re-hydrated from the
    /// credential store by `PrepareClaudeLaunchCommand` when `refreshToken`
    /// is *missing* from it, not when it's merely stale — so a refresh can
    /// leave an already-launched account serving a dead, rotated-out token
    /// until that account happens to lose the key entirely. Keep both
    /// copies in sync whenever the identity file already exists for this
    /// account.
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
