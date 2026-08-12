import Foundation

/// Fired by `CaptureClaudeExitCommand` when it detects that an account's
/// OAuth credential actually changed during a `claude` session (a fresh
/// `/login` or a token rotation) — not on every exit unconditionally.
///
/// Two reactions, both best-effort (never throw, never block the shell
/// prompt on a hook failure):
/// - Refetch the account's cached `email`/`plan` (they may have changed,
///   e.g. after switching which login was used).
/// - Run a user-scriptable hook at `~/.orrery/hooks/on-login`, if present
///   and executable — mirrors the git-hooks convention: drop a script
///   there, orrery runs it with the account's info in the environment.
///   Nothing ships one by default.
public enum AccountLoginHooks {
    /// `ORRERY_HOME`-relative, so it's isolated the same way in tests.
    public static var onLoginScriptURL: URL {
        orreryHomeURL().appendingPathComponent("hooks/on-login")
    }

    public static func fire(account: Account, accountStore: AccountStore = .default) {
        var updated = account
        if updated.refreshInfo(accountStore: accountStore) {
            try? accountStore.save(updated)
        }
        runExternalScript(for: updated)
    }

    private static func runExternalScript(for account: Account) {
        guard FileManager.default.isExecutableFile(atPath: onLoginScriptURL.path) else { return }

        let proc = Process()
        proc.executableURL = onLoginScriptURL
        var env = ProcessInfo.processInfo.environment
        env["ORRERY_HOOK_EVENT"] = "login"
        env["ORRERY_ACCOUNT_ID"] = account.id
        env["ORRERY_ACCOUNT_NAME"] = account.displayName
        env["ORRERY_ACCOUNT_TOOL"] = account.tool.rawValue
        if let email = account.email { env["ORRERY_ACCOUNT_EMAIL"] = email }
        if let plan = account.plan { env["ORRERY_ACCOUNT_PLAN"] = plan }
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return }
        proc.waitUntilExit()
    }
}
