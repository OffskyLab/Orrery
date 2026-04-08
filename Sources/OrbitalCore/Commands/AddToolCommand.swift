import ArgumentParser
import Foundation

public struct AddToolCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a tool to an environment",
        subcommands: [ToolSubcommand.self]
    )

    public struct ToolSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(commandName: "tool")
        @Argument(help: "Tool name: claude, codex, or gemini") public var tool: String
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
            try AddToolCommand.addTool(t, to: envName, store: store)
            print("Added tool '\(tool)' to environment '\(envName)'")
        }
    }

    public init() {}
    public func run() throws {}

    public static func addTool(_ tool: Tool, to envName: String, store: EnvironmentStore) throws {
        try store.addTool(tool, to: envName)
    }
}
