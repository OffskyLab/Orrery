import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ListCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: L10n.List.abstract
    )
    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default
        let activeEnv = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
        let rows = try Self.environmentRows(activeEnv: activeEnv, store: store)
        if rows.isEmpty {
            print(L10n.List.empty)
        } else {
            print(rows.joined(separator: "\n\n"))
        }
    }

    private struct ToolRow {
        let name: String
        let suffix: String
        /// Trailing info: last-used relative time (and quota in P2). Already
        /// colorized; rendered after `suffix` with a `·` separator.
        let usage: String
    }

    private struct EnvRow {
        let active: String
        let name: String
        let tools: [ToolRow]
        let fallbackBody: String?
        let detail: String
    }

    public static func environmentRows(activeEnv: String?, store: EnvironmentStore) throws -> [String] {
        let names = try store.listNames().sorted()
        let defaultName = ReservedEnvironment.defaultName
        let defaultActive = activeEnv == defaultName || activeEnv == nil ? "*" : " "

        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short

        // Load env metadata serially (cheap JSON reads).
        let loadedEnvs: [(name: String, env: OrreryEnvironment)] = try names.map {
            ($0, try store.load(named: $0))
        }

        // Flatten every account-info lookup into one work list so we can run
        // them concurrently. Each lookup may hit the macOS Keychain (Claude)
        // or read JSON files (Codex/Gemini) — fanning them out makes the
        // command finish in the time of the slowest single lookup instead
        // of the sum across N envs.
        struct WorkItem: Sendable {
            let tool: Tool
            let configDir: URL?
        }
        var workItems: [WorkItem] = []

        // Origin: probe every tool to detect which are logged in.
        let originRange = workItems.count..<(workItems.count + Tool.allCases.count)
        for tool in Tool.allCases {
            workItems.append(WorkItem(tool: tool, configDir: nil))
        }

        // Per env: only its declared tools.
        var envRanges: [Range<Int>] = []
        for (name, env) in loadedEnvs {
            let start = workItems.count
            for tool in env.tools {
                let configDir = store.toolConfigDir(tool: tool, environment: name)
                workItems.append(WorkItem(tool: tool, configDir: configDir))
            }
            envRanges.append(start..<workItems.count)
        }

        let items = workItems
        let collector = ResultsCollector(count: items.count)
        if !items.isEmpty {
            DispatchQueue.concurrentPerform(iterations: items.count) { i in
                let info = ToolAuth.accountInfo(tool: items[i].tool, configDir: items[i].configDir)
                collector.set(info, at: i)
            }
        }
        let results = collector.snapshot

        // Build origin row (filter to tools that returned any info).
        let originTools: [ToolRow] = originRange.compactMap { i in
            let item = workItems[i]
            let info = results[i]
            let suffix = [info.email, info.plan, info.model].compactMap { $0 }.joined(separator: ", ")
            guard !suffix.isEmpty else { return nil }
            let usage = Self.usageString(
                store: store, tool: item.tool, envName: ReservedEnvironment.defaultName
            )
            return ToolRow(
                name: item.tool.rawValue,
                suffix: Self.colorizeSuffix(suffix, email: info.email, plan: info.plan, model: info.model),
                usage: usage
            )
        }

        var rows: [EnvRow] = [
            EnvRow(
                active: defaultActive,
                name: defaultName,
                tools: originTools,
                fallbackBody: nil,
                detail: L10n.Create.defaultDescription
            )
        ]

        for (idx, pair) in loadedEnvs.enumerated() {
            let active = pair.name == activeEnv ? "*" : " "
            let toolRows: [ToolRow] = envRanges[idx].map { i in
                let item = workItems[i]
                let info = results[i]
                let suffix = [info.email, info.plan, info.model].compactMap { $0 }.joined(separator: ", ")
                let usage = Self.usageString(store: store, tool: item.tool, envName: pair.name)
                return ToolRow(
                    name: item.tool.rawValue,
                    suffix: Self.colorizeSuffix(suffix, email: info.email, plan: info.plan, model: info.model),
                    usage: usage
                )
            }
            let lastUsed = df.string(from: pair.env.lastUsed)
            rows.append(EnvRow(
                active: active,
                name: pair.name,
                tools: toolRows,
                fallbackBody: pair.env.tools.isEmpty ? "(none)" : nil,
                detail: lastUsed
            ))
        }

        let nameWidth = max(12, rows.map(\.name.count).max() ?? 0) + 2
        let toolWidth = (Tool.allCases.map { $0.rawValue.count }.max() ?? 0) + 2

        return rows.map { row in
            let rawHeader = "\(row.active) \(row.name)\(String(repeating: " ", count: max(0, nameWidth - row.name.count)))\(row.detail)"
            let header = row.active == "*" ? Self.colorize(rawHeader, code: "96") : rawHeader

            let bodyLines: [String]
            if let fallbackBody = row.fallbackBody {
                bodyLines = ["  · \(fallbackBody)"]
            } else if row.tools.isEmpty, row.name == defaultName {
                bodyLines = Tool.allCases.map {
                    let padded = $0.rawValue + String(repeating: " ", count: max(0, toolWidth - $0.rawValue.count))
                    return Self.colorize("  · \(padded)", code: "90")
                }
            } else {
                bodyLines = row.tools.map { tool in
                    let paddedName = tool.name + String(repeating: " ", count: max(0, toolWidth - tool.name.count))
                    let prefix = Self.colorize("  · \(paddedName)", code: "90")
                    let body = tool.suffix.isEmpty ? prefix : "\(prefix)\(tool.suffix)"
                    return tool.usage.isEmpty ? body : "\(body)  \(Self.colorize("·", code: "90")) \(tool.usage)"
                }
            }

            return ([header] + bodyLines).joined(separator: "\n")
        }
    }

    /// Trailing per-tool info: last-used relative time + cached quota when
    /// available. Returns "" when there is no signal worth rendering, so the
    /// caller can skip the trailing `·`.
    private static func usageString(store: EnvironmentStore, tool: Tool, envName: String) -> String {
        var parts: [String] = []
        if let last = store.lastUsed(tool: tool, environment: envName) {
            parts.append(colorize(RelativeTime.ago(from: last), code: "38;5;245"))
        }
        if let q = quotaSummary(store: store, tool: tool, envName: envName) {
            parts.append(q)
        }
        return parts.joined(separator: "  \(colorize("·", code: "90")) ")
    }

    /// Compact "5h X% / 7d Y%" string from cached quota. Only Claude has data
    /// in P2 — other tools return nil. Tagged "(stale)" when fetchedAt is
    /// older than 8h, matching statusline.js's TTL.
    private static func quotaSummary(store: EnvironmentStore, tool: Tool, envName: String) -> String? {
        guard tool == .claude else { return nil }
        let cache = QuotaCache(homeURL: store.homeURL)
        guard let snap = cache.load(envName: envName), let q = snap.claude else { return nil }
        var bits: [String] = []
        if let w = q.fiveHour  { bits.append("5h \(formatPct(w.utilization))") }
        if let w = q.sevenDay  { bits.append("7d \(formatPct(w.utilization))") }
        guard !bits.isEmpty else { return nil }
        let stale = Date().timeIntervalSince(snap.fetchedAt) > 8 * 3600
        let body = bits.joined(separator: " / ")
        let colored = colorize(body, code: stale ? "90" : "38;5;108")
        return stale ? "\(colored) \(colorize("(stale)", code: "90"))" : colored
    }

    private static func formatPct(_ percentage: Double) -> String {
        let rounded = (percentage * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? "\(Int(rounded))%"
            : String(format: "%.1f%%", rounded)
    }

    private static func colorizeSuffix(_ suffix: String, email: String?, plan: String?, model: String?) -> String {
        var result = suffix
        if let model, !model.isEmpty, let range = result.range(of: model, options: .backwards) {
            result.replaceSubrange(range, with: colorize(model, code: "38;5;240"))
        }
        if let plan, !plan.isEmpty, let range = result.range(of: plan, options: .backwards) {
            result.replaceSubrange(range, with: colorize(plan, code: "38;5;245"))
        }
        if let email, !email.isEmpty, let range = result.range(of: email) {
            result.replaceSubrange(range, with: colorize(email, code: "38;5;252"))
        }
        return result
    }

    private static func colorize(_ s: String, code: String) -> String {
        guard isatty(STDOUT_FILENO) != 0 else { return s }
        return "\u{001B}[\(code)m\(s)\u{001B}[0m"
    }
}

/// Lock-protected sink for parallel `ToolAuth.accountInfo` lookups so the
/// concurrentPerform closure has a Sendable destination without resorting
/// to UnsafeMutableBufferPointer.
private final class ResultsCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ToolAuth.AccountInfo]

    init(count: Int) {
        self.values = Array(
            repeating: ToolAuth.AccountInfo(email: nil, plan: nil, model: nil, key: nil),
            count: count
        )
    }

    func set(_ value: ToolAuth.AccountInfo, at index: Int) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }

    var snapshot: [ToolAuth.AccountInfo] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
