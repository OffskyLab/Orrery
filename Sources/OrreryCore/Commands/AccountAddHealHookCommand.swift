import ArgumentParser
import Foundation

#if os(macOS)

/// Internal subcommand: one tick of the account-add login watchdog. Polled
/// in the background by the shell wrapper's `add` fast path (see
/// `ShellFunctionGenerator`) for as long as `claude` is running.
///
/// Two jobs, both defensive rather than load-bearing on their own:
///
/// 1. Re-applies the account-add `auth_success` hook, in case claude's own
///    first-run onboarding write to this otherwise-empty staging
///    `settings.json` replaced the file wholesale and wiped it.
/// 2. Detects login completion directly (the live Keychain item for this
///    staging `CLAUDE_CONFIG_DIR` differing from what's already imported)
///    and runs the same import `_account-add-finalize --keep-staging`
///    would, instead of waiting for claude to actually fire the
///    `auth_success` Notification hook.
///
/// (2) exists because (1) alone isn't sufficient: in testing, the hook was
/// confirmed present in `settings.json` with the correct command and path
/// throughout an entire login, OAuth completed (the staging `.claude.json`
/// had a fully populated `oauthAccount`), and yet claude never invoked it —
/// so relying on claude to fire `Notification`/`auth_success` reliably
/// (or at all, for a fresh account's first login) isn't something this can
/// depend on. Polling the Keychain directly for the credential landing is
/// unaffected by whatever claude's hook-firing behavior turns out to be.
/// It's a diff check, not a one-shot latch, so a `/login` to a different
/// account inside the same still-open session is picked up too.
public struct AccountAddHealHookCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_account-add-heal-hook",
        abstract: "(internal) One tick of the account-add login watchdog: re-patch the auth_success hook and finalize once login completes.",
        shouldDisplay: false
    )

    @Option(name: .long, help: "Absolute path to the account-add staging directory.")
    public var staging: String

    public init() {}

    public func run() throws {
        let stagingURL = URL(fileURLWithPath: staging)
        AccountAddPrepareCommand.healHook(stagingDir: stagingURL)
        Self.finalizeIfLoginComplete(stagingDir: stagingURL)
    }

    /// Re-imports whenever the live credential differs from what's already
    /// in the pool — not just once. A user can `/login` again inside the
    /// same still-open session to switch to a completely different account
    /// before ever `/exit`ing (e.g. they logged into the wrong one first);
    /// gating on "have we ever finalized" would freeze the account on
    /// whichever login happened to land first and silently ignore every
    /// `/login` after that. Comparing refresh tokens (same approach as
    /// `ClaudeLoginSync.syncIfChanged`, which does this for already-pinned
    /// accounts) tracks whatever's actually logged in right now.
    ///
    /// Best-effort: any failure (staging already gone, metadata unreadable,
    /// tool isn't claude, account removed) just skips this tick — the shell
    /// wrapper's own exit-time `_account-add-finalize` call is still there
    /// as the final fallback once `claude` actually exits.
    private static func finalizeIfLoginComplete(stagingDir: URL) {
        let metadataURL = stagingDir.appendingPathComponent(".orrery-prepare.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let accountID = raw["accountID"],
              let toolRaw = raw["tool"],
              let tool = Tool(rawValue: toolRaw),
              tool == .claude,
              let account = try? AccountStore.default.load(id: accountID, tool: tool),
              let poolService = account.keychainItem
        else { return }

        // Only attempt the import once a live credential actually exists.
        // AccountAddFinalizeCommand deletes the account from the store on
        // import failure (see its doc comment) — calling it before login
        // has completed would destroy the in-progress account-add.
        let liveService = ClaudeKeychain.service(for: stagingDir.path)
        guard let liveCredential = ClaudeKeychain.oauthCredential(forService: liveService) else { return }

        let poolCredential = ClaudeKeychain.oauthCredential(forService: poolService)
        guard liveCredential.refreshToken != poolCredential?.refreshToken else {
            return // unchanged since the last successful import — nothing to do
        }

        var finalize = AccountAddFinalizeCommand()
        finalize.staging = stagingDir.path
        finalize.keepStaging = true
        try? finalize.run()
    }
}

#endif
