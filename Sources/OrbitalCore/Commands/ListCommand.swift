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
        let activeEnv = ProcessInfo.processInfo.environment["ORBITAL_ACTIVE_ENV"]
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
        var rows = ["\(defaultActive) \(defaultName.padding(toLength: 12, withPad: " ", startingAt: 0))\(L10n.Create.defaultDescription)"]

        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short

        for name in names {
            let env = try store.load(named: name)
            let active = name == activeEnv ? "*" : " "
            let tools = env.tools.map(\.rawValue).joined(separator: ", ")
            let toolsCol = tools.isEmpty ? "(none)" : tools
            let lastUsed = df.string(from: env.lastUsed)
            rows.append("\(active) \(name.padding(toLength: 12, withPad: " ", startingAt: 0))\(toolsCol.padding(toLength: 24, withPad: " ", startingAt: 0))\(lastUsed)")
        }
        return rows
    }
}
