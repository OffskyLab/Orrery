import ArgumentParser
import Foundation

public struct ExportCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_export",
        abstract: "Internal: print export lines for a named environment (called by shell function)"
    )

    @Argument var name: String
    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default
        let lines = try Self.exportLines(for: name, store: store)
        print(lines.joined(separator: "\n"))
    }

    public static func exportLines(for name: String, store: EnvironmentStore) throws -> [String] {
        var env = try store.load(named: name)
        env.lastUsed = Date()
        try store.save(env)

        var lines: [String] = []
        for tool in env.tools {
            let dir = store.toolConfigDir(tool: tool, environment: name).path
            lines.append("export \(tool.envVarName)=\(dir)")
        }
        for (key, value) in env.env.sorted(by: { $0.key < $1.key }) {
            lines.append("export \(key)=\(value)")
        }
        return lines
    }
}
