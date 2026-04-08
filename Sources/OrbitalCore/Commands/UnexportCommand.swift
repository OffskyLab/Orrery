import ArgumentParser

public struct UnexportCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_unexport",
        abstract: "Internal: print unset lines for a named environment (called by shell function)",
        shouldDisplay: false
    )

    @Argument var name: String
    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default
        let lines = try Self.unexportLines(for: name, store: store)
        print(lines.joined(separator: "\n"))
    }

    public static func unexportLines(for name: String, store: EnvironmentStore) throws -> [String] {
        let env = try store.load(named: name)
        var lines: [String] = []

        for tool in env.tools {
            lines.append("unset \(tool.envVarName)")
        }

        for key in env.env.keys.sorted() {
            lines.append("unset \(key)")
        }

        return lines
    }
}
