import ArgumentParser
import Foundation

public struct WhichCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "which",
        abstract: "Print the config directory path for a tool in the active environment"
    )

    @Argument(help: "Tool name: claude, codex, or gemini")
    public var tool: String

    public init() {}

    public func run() throws {
        guard let t = Tool(rawValue: tool) else {
            throw ValidationError("Unknown tool '\(tool)'. Valid tools: claude, codex, gemini")
        }
        guard let envName = ProcessInfo.processInfo.environment["ORBITAL_ACTIVE_ENV"] else {
            throw ValidationError("No active environment. Run 'orbital use <name>' first.")
        }
        let store = EnvironmentStore.default
        let path = store.toolConfigDir(tool: t, environment: envName).path
        print(path)
    }
}
