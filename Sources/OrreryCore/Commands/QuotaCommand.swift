import ArgumentParser
import Foundation

public struct QuotaCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "quota",
        abstract: L10n.Quota.abstract,
        subcommands: [Refresh.self]
    )
    public init() {}

    public struct Refresh: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "refresh",
            abstract: L10n.Quota.refreshAbstract
        )

        @Option(name: .shortAndLong, help: ArgumentHelp(L10n.Quota.envHelp))
        public var environment: String?

        public init() {}

        public func run() throws {
            let store = EnvironmentStore.default
            let envName = try environment ?? quotaCurrentEnvOrThrow()
            let cache = QuotaCache(homeURL: store.homeURL)

            // Resolve the Claude config dir for this env. `nil` = origin.
            let configDir: String?
            if envName == ReservedEnvironment.defaultName {
                configDir = nil
            } else {
                configDir = store.toolConfigDir(tool: .claude, environment: envName).path
            }

            let quota: UsageQuota
            do {
                quota = try ClaudeUsageFetcher.fetch(configDir: configDir)
            } catch ClaudeUsageError.noAccessToken {
                print(L10n.Quota.notLoggedIn(envName))
                throw ExitCode(1)
            } catch {
                print(L10n.Quota.fetchFailed(error.localizedDescription))
                throw ExitCode(1)
            }

            try cache.update(envName: envName, claude: quota)
            printQuota(envName: envName, quota: quota)
        }

        private func printQuota(envName: String, quota: UsageQuota) {
            print(L10n.Quota.refreshedHeader(envName))
            if let w = quota.fiveHour {
                print("  5h:  \(formatPct(w.utilization))%\(formatReset(w.resetsAt))")
            }
            if let w = quota.sevenDay {
                print("  7d:  \(formatPct(w.utilization))%\(formatReset(w.resetsAt))")
            }
            if let w = quota.sevenDayOpus {
                print("  7d (opus):   \(formatPct(w.utilization))%\(formatReset(w.resetsAt))")
            }
            if let w = quota.sevenDaySonnet {
                print("  7d (sonnet): \(formatPct(w.utilization))%\(formatReset(w.resetsAt))")
            }
        }

        private func formatPct(_ utilization: Double) -> String {
            // API returns percentage already (e.g. 13.0 for 13%).
            String(format: "%.1f", utilization)
        }

        private func formatReset(_ resetsAt: Date?) -> String {
            guard let resetsAt else { return "" }
            let df = DateFormatter()
            df.dateStyle = .short
            df.timeStyle = .short
            return "  · resets \(df.string(from: resetsAt))"
        }
    }
}

private func quotaCurrentEnvOrThrow() throws -> String {
    if let env = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"] { return env }
    throw ValidationError("No active environment. Use --environment <env> or switch with `orrery use <env>`.")
}
