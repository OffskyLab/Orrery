import Foundation

#if os(macOS)

/// Detects whether claude's live OAuth credential (under the
/// `CLAUDE_CONFIG_DIR`-hashed Keychain service — see `ClaudeKeychain.service(for:)`)
/// differs from the account's own pool copy (`account.keychainItem`), and if
/// so, syncs it and fires `AccountLoginHooks`.
///
/// Shared by two trigger points:
/// - `orrery-claude-hook` (primary): installed per-account as a claude
///   `Notification`/`auth_success` hook by `PrepareClaudeLaunchCommand`, so
///   it runs the instant a login completes.
/// - `CaptureClaudeExitCommand` (fallback, `@available(deprecated)`): runs
///   at claude exit regardless of whether a login happened, kept only until
///   the `auth_success` hook is confirmed to cover every case that matters
///   (e.g. claude's own silent token refresh, not just an explicit
///   `/login` — unverified as of this writing).
///
/// Pool-account launches only (`CLAUDE_CONFIG_DIR` set to the account's own
/// directory) — a bare origin launch's live credential lives under a
/// different, unset-config-dir Keychain service and isn't handled here.
public enum ClaudeLoginSync {
    /// Returns true if a change was detected and handled (synced + hooks fired).
    @discardableResult
    public static func syncIfChanged(accountDir: URL) -> Bool {
        guard let account = try? AccountStore.default.load(id: accountDir.lastPathComponent, tool: .claude),
              let poolService = account.keychainItem
        else { return false }

        let liveService = ClaudeKeychain.service(for: accountDir.path)
        guard let liveCredential = ClaudeKeychain.oauthCredential(forService: liveService) else { return false }

        let poolCredential = ClaudeKeychain.oauthCredential(forService: poolService)
        guard liveCredential.refreshToken != poolCredential?.refreshToken else {
            return false // unchanged — no login/refresh happened
        }

        guard ClaudeKeychain.copyKeychainItem(from: liveService, to: poolService) else { return false }
        AccountLoginHooks.fire(account: account)
        return true
    }
}

#endif
