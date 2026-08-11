import ArgumentParser
import Foundation

/// Manual escape hatch for the background token-refresh daemon
/// (`RefreshTokensCommand` / `com.offskylab.orrery.token-refresh`
/// LaunchAgent): force-refresh one or all Claude accounts' OAuth tokens
/// right now, ignoring the near-expiry threshold. Useful for debugging the
/// daemon or recovering an account it keeps failing to refresh.
public struct RefreshTokenCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "refresh-token",
        abstract: "Force-refresh a Claude account's OAuth token"
    )

    @Argument(help: ArgumentHelp("Account display name to refresh. Omit and pass --all to refresh every Claude account."))
    public var name: String?

    @Flag(name: .long, help: ArgumentHelp("Refresh every Claude account instead of a single named one."))
    public var all: Bool = false

    public init() {}

    public func run() throws {
        #if os(macOS)
        let acctStore = AccountStore.default
        let accounts: [Account]
        if all {
            accounts = try acctStore.list(tool: .claude)
        } else {
            guard let name else {
                throw ValidationError("Specify an account name, or pass --all to refresh every Claude account.")
            }
            guard let account = try acctStore.findByDisplayName(name, tool: .claude) else {
                throw ValidationError("No Claude account named '\(name)'.")
            }
            accounts = [account]
        }

        let results = TokenRefreshRunner.live.sweep(accounts: accounts, threshold: 0, force: true)
        var anyFailed = false
        for (account, outcome) in results {
            switch outcome {
            case .refreshed:
                print("✓ \(account.displayName): refreshed")
            case .skipped:
                print("– \(account.displayName): skipped (no readable credential)")
            case .failed(let reason):
                anyFailed = true
                print("✗ \(account.displayName): failed — \(reason)")
            }
        }

        if !all && anyFailed {
            throw ExitCode.failure
        }
        #else
        print("orrery: token refresh is only supported on macOS")
        #endif
    }
}
