import ArgumentParser
import Foundation

public struct InfoCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show details of an orbital environment"
    )

    @Argument(help: "Environment name (defaults to active environment)")
    public var name: String?

    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default
        let resolvedName: String
        if let name {
            resolvedName = name
        } else if let active = ProcessInfo.processInfo.environment["ORBITAL_ACTIVE_ENV"] {
            resolvedName = active
        } else {
            throw ValidationError("No active environment. Specify a name or run 'orbital use <name>' first.")
        }
        let env = try store.load(named: resolvedName)
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium

        let path = try store.envDir(for: resolvedName).path

        print("Name:        \(env.name)")
        print("ID:          \(env.id)")
        print("Path:        \(path)")
        print("Description: \(env.description.isEmpty ? "(none)" : env.description)")
        print("Created:     \(df.string(from: env.createdAt))")
        print("Last Used:   \(df.string(from: env.lastUsed))")
        print("Tools:       \(env.tools.isEmpty ? "(none)" : env.tools.map(\.rawValue).joined(separator: ", "))")
        if env.env.isEmpty {
            print("Env Vars:    (none)")
        } else {
            print("Env Vars:")
            for (key, value) in env.env.sorted(by: { $0.key < $1.key }) {
                let masked = value.count > 8 ? String(value.prefix(4)) + "****" : "****"
                print("  \(key)=\(masked)")
            }
        }
    }
}
