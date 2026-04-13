import ArgumentParser
import Foundation
import Darwin

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

        var rows: [EnvRow] = [
            EnvRow(
                active: defaultActive,
                name: defaultName,
                tools: Self.originToolRows(),
                fallbackBody: nil,
                detail: L10n.Create.defaultDescription
            )
        ]

        for name in names {
            let env = try store.load(named: name)
            let active = name == activeEnv ? "*" : " "
            let toolRows = env.tools.map { tool -> ToolRow in
                let configDir = store.toolConfigDir(tool: tool, environment: name)
                let info = ToolAuth.accountInfo(tool: tool, configDir: configDir)
                let suffix = [info.email, info.plan, info.model].compactMap { $0 }.joined(separator: ", ")
                return ToolRow(name: tool.rawValue, suffix: Self.colorizeSuffix(suffix, email: info.email, plan: info.plan, model: info.model))
            }
            let lastUsed = df.string(from: env.lastUsed)
            rows.append(EnvRow(active: active, name: name, tools: toolRows, fallbackBody: env.tools.isEmpty ? "(none)" : nil, detail: lastUsed))
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
                    return tool.suffix.isEmpty ? prefix : "\(prefix)\(tool.suffix)"
                }
            }

            return ([header] + bodyLines).joined(separator: "\n")
        }
    }

    private static func originToolRows() -> [ToolRow] {
        Tool.allCases.compactMap { tool -> ToolRow? in
            let info = ToolAuth.accountInfo(tool: tool, configDir: nil)
            let suffix = [info.email, info.plan, info.model].compactMap { $0 }.joined(separator: ", ")
            guard !suffix.isEmpty else { return nil }
            return ToolRow(name: tool.rawValue, suffix: Self.colorizeSuffix(suffix, email: info.email, plan: info.plan, model: info.model))
        }
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
