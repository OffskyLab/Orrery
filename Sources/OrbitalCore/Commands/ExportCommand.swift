import ArgumentParser
import Foundation

public struct ExportCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_export",
        abstract: L10n.Export.abstract,
        shouldDisplay: false
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

        // Ensure shared session symlinks are in place for existing environments
        if !env.isolateSessions {
            for tool in env.tools {
                try store.ensureSharedSessionLinks(tool: tool, environment: name)
            }
        }

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
