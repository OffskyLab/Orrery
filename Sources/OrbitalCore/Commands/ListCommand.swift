import ArgumentParser
import Foundation

public struct ListCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all orbital environments"
    )
    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default
        let activeEnv = ProcessInfo.processInfo.environment["ORBITAL_ACTIVE_ENV"]
        let rows = try Self.environmentRows(activeEnv: activeEnv, store: store)
        if rows.isEmpty {
            print("No environments found. Create one with: orbital create <name>")
        } else {
            print("  NAME        TOOLS                   LAST USED")
            print(String(repeating: "-", count: 60))
            rows.forEach { print($0) }
        }
    }

    public static func environmentRows(activeEnv: String?, store: EnvironmentStore) throws -> [String] {
        let names = try store.listNames().sorted()
        return try names.map { name in
            let env = try store.load(named: name)
            let active = name == activeEnv ? "*" : " "
            let tools = env.tools.map(\.rawValue).joined(separator: ", ")
            let toolsCol = tools.isEmpty ? "(none)" : tools
            let df = DateFormatter()
            df.dateStyle = .short
            df.timeStyle = .short
            let lastUsed = df.string(from: env.lastUsed)
            return "\(active) \(name.padding(toLength: 12, withPad: " ", startingAt: 0))\(toolsCol.padding(toLength: 24, withPad: " ", startingAt: 0))\(lastUsed)"
        }
    }
}
