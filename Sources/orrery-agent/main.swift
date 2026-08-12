import Foundation
import OrreryCore

// The orrery background agent: invoked periodically by the OS scheduler
// (macOS launchd via a `.app` bundle, Linux systemd --user via a timer —
// see TokenRefreshDaemonInstaller / LinuxAgentInstaller) to refresh any
// Claude account whose OAuth token is within an hour of expiring.
//
// Deliberately a separate, minimal executable rather than a hidden
// subcommand of `orrery-bin`: the background responsibility is independent
// of the interactive CLI, so it gets its own binary, its own name, and (on
// macOS) its own icon — no ArgumentParser, no subcommand routing, it does
// exactly one thing. Best-effort throughout: never throws, always exits 0,
// one account's failure never blocks the rest.

#if os(macOS)
TokenRefreshDaemonInstaller.rotateLogIfNeeded()
#endif

let threshold: TimeInterval = 60 * 60
let accounts = (try? AccountStore.default.list(tool: .claude)) ?? []
let results = TokenRefreshRunner.live.sweep(accounts: accounts, threshold: threshold)

for (account, outcome) in results {
    switch outcome {
    case .skipped:
        continue
    case .refreshed:
        print("orrery-agent: refreshed token for '\(account.displayName)'")
    case .failed(let reason):
        FileHandle.standardError.write(
            Data("orrery-agent: token refresh failed for '\(account.displayName)': \(reason)\n".utf8)
        )
    }
}
