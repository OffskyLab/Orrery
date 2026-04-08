import ArgumentParser
import Foundation

public struct RemoveToolCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a tool from an environment",
        subcommands: [ToolSubcommand.self]
    )

    public struct ToolSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(commandName: "tool")
        @Argument public var tool: String
        @Option(name: .shortAndLong) public var environment: String?
        public init() {}

        public func run() throws {
            guard let t = Tool(rawValue: tool) else {
                throw ValidationError("Unknown tool '\(tool)'. Valid tools: claude, codex, gemini")
            }
            guard let envName = environment ?? ProcessInfo.processInfo.environment["ORBITAL_ACTIVE_ENV"] else {
                throw ValidationError("No active environment. Run 'orbital use <name>' first, or use -e <name>.")
            }
            let store = EnvironmentStore.default
            try RemoveToolCommand.removeTool(t, from: envName, store: store)
            print("Removed tool '\(tool)' from environment '\(envName)'")
        }
    }

    public init() {}
    public func run() throws {}

    public static func removeTool(_ tool: Tool, from envName: String, store: EnvironmentStore) throws {
        try store.removeTool(tool, from: envName)
    }
}
