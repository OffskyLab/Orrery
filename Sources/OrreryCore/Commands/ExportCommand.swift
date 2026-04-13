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
        guard name != ReservedEnvironment.defaultName else { return [] }
        var env = try store.load(named: name)
        env.lastUsed = Date()
        try store.save(env)

        // Ensure shared session symlinks are in place for existing environments
        // (per-tool: only the tools whose sessions aren't isolated)
        for tool in env.tools where !env.isolateSessions(for: tool) {
            try store.ensureSharedSessionLinks(tool: tool, environment: name)
        }
        // gemini-cli ignores GEMINI_CONFIG_DIR; isolation is achieved by
        // overriding HOME to a wrapper dir whose `.gemini` symlinks back to
        // the env's gemini config. Make sure the wrapper exists for old envs.
        if env.tools.contains(.gemini) {
            try store.ensureGeminiHomeWrapper(envName: name)
        }

        var lines: [String] = []
        for tool in env.tools {
            let dir = store.toolConfigDir(tool: tool, environment: name).path
            lines.append("export \(tool.envVarName)=\(dir)")
        }
        if env.tools.contains(.gemini) {
            let homeDir = store.geminiHomeDir(environment: name).path
            lines.append("export ORRERY_GEMINI_HOME=\(homeDir)")
        }
        for (key, value) in env.env.sorted(by: { $0.key < $1.key }) {
            lines.append("export \(key)=\(value)")
        }
        return lines
    }
}
