import Foundation
import OrreryCore

// Invoked directly by claude itself as a `Notification`/`auth_success`
// hook command (installed per-account by PrepareClaudeLaunchCommand) — the
// instant a login completes, sync the account's pool Keychain copy from
// claude's live credential and fire AccountLoginHooks. See
// ClaudeLoginSync's doc comment for the full picture.
//
// A separate, minimal executable rather than a hidden orrery-bin
// subcommand: this is invoked by claude, not by the user through the
// orrery CLI, so it's a different "actor" — same reasoning as orrery-agent
// being separate from orrery-bin. No ArgumentParser: it does exactly one
// thing with exactly one required argument.
//
// Claude Code's `Notification` hooks ignore both exit code and stderr, so
// there's no feedback channel back to claude — this is entirely
// best-effort, silent, and always exits 0.

// Drain stdin (the hook's JSON payload) unconditionally, so claude never
// blocks writing to a pipe nobody's reading — same deadlock hazard noted in
// ClaudeKeychain.findPassword's Keychain pipe handling. This applies to every
// mode this binary runs in, including --session-event below.
let stdinData = FileHandle.standardInput.readDataToEndOfFile()

// SessionStart/SessionEnd mode: record claude's own session id in the
// phantom registry instead of leaving it to the mtime-scanning probe. See
// ClaudeSessionHookInstaller's doc comment for why.
if CommandLine.arguments.contains("--session-event") {
    ClaudeSessionHook.apply(
        payload: stdinData,
        phantomId: ProcessInfo.processInfo.environment["ORRERY_PHANTOM_ID"],
        registry: PhantomRegistry(homeURL: EnvironmentStore.default.homeURL))
    exit(0)
}

func accountDirArgument() -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--account-dir"), index + 1 < args.count else {
        return nil
    }
    return args[index + 1]
}

#if os(macOS)
if let accountDir = accountDirArgument() {
    ClaudeLoginSync.syncIfChanged(accountDir: URL(fileURLWithPath: accountDir))
}
#endif
