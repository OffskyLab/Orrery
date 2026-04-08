import ArgumentParser
import Foundation

public struct InfoCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show details of an orbital environment"
    )

    @Argument(help: "Environment name")
    public var name: String

    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default
        let env = try store.load(named: name)
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium

        print("Name:        \(env.name)")
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
