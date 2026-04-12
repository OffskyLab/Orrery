import ArgumentParser
import Foundation

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
            print(L10n.List.header)
            print(String(repeating: "-", count: 60))
            rows.forEach { print($0) }
        }
    }

    public static func environmentRows(activeEnv: String?, store: EnvironmentStore) throws -> [String] {
        let names = try store.listNames().sorted()
        let defaultName = ReservedEnvironment.defaultName
        let defaultActive = activeEnv == defaultName || activeEnv == nil ? "*" : " "

        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short

        // (active, name, toolsCol, lastUsed)
        var tuples: [(String, String, String, String)] = [
            (defaultActive, defaultName, L10n.Create.defaultDescription, "")
        ]

        for name in names {
            let env = try store.load(named: name)
            let active = name == activeEnv ? "*" : " "
            let toolEntries = env.tools.map { tool -> String in
                let configDir = store.toolConfigDir(tool: tool, environment: name)
                let info = ToolAuth.accountInfo(tool: tool, configDir: configDir)
                let suffix = [info.email, info.plan].compactMap { $0 }.joined(separator: ", ")
                return suffix.isEmpty ? tool.rawValue : "\(tool.rawValue)(\(suffix))"
            }
            let toolsCol = toolEntries.isEmpty ? "(none)" : toolEntries.joined(separator: ", ")
            let lastUsed = df.string(from: env.lastUsed)
            tuples.append((active, name, toolsCol, lastUsed))
        }

        let nameWidth  = max(12, tuples.map(\.1.count).max() ?? 0) + 2
        let toolsWidth = max(24, tuples.map(\.2.count).max() ?? 0) + 2

        return tuples.map { (active, name, tools, lastUsed) in
            "\(active) \(name.padding(toLength: nameWidth, withPad: " ", startingAt: 0))\(tools.padding(toLength: toolsWidth, withPad: " ", startingAt: 0))\(lastUsed)"
        }
    }
}
