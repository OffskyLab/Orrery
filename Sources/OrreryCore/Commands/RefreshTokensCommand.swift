import ArgumentParser
import Foundation

/// Internal: background sweep invoked by the `com.offskylab.orrery.token-refresh`
/// LaunchAgent every ~15 minutes. Refreshes any Claude account whose access
/// token is within an hour of expiring. Best-effort — always exits 0, never
/// throws, one account's failure never blocks the rest.
public struct RefreshTokensCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_refresh-tokens",
        abstract: "Internal: refresh near-expiry Claude account OAuth tokens",
        shouldDisplay: false
    )

    /// How far ahead of expiry to proactively refresh.
    static let threshold: TimeInterval = 60 * 60

    public init() {}

    public func run() throws {
        #if os(macOS)
        TokenRefreshDaemonInstaller.rotateLogIfNeeded()
        let accounts = (try? AccountStore.default.list(tool: .claude)) ?? []
        let results = TokenRefreshRunner.live.sweep(accounts: accounts, threshold: Self.threshold)
        for (account, outcome) in results {
            switch outcome {
            case .skipped:
                continue
            case .refreshed:
                print("orrery: refreshed token for '\(account.displayName)'")
            case .failed(let reason):
                FileHandle.standardError.write(
                    Data("orrery: token refresh failed for '\(account.displayName)': \(reason)\n".utf8)
                )
            }
        }
        #endif
    }
}
