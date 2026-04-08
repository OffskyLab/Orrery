import ArgumentParser
import Foundation

public struct ToolsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tools",
        abstract: "Manage tools for an environment (interactive multi-select)"
    )

    @Option(name: .shortAndLong, help: "Environment name (defaults to active environment)")
    public var environment: String?

    public init() {}

    public func run() throws {
        guard let envName = environment ?? ProcessInfo.processInfo.environment["ORBITAL_ACTIVE_ENV"] else {
            throw ValidationError("No active environment. Run 'orbital use <name>' first, or use -e <name>.")
        }

        let store = EnvironmentStore.default
        let env = try store.load(named: envName)
        let allTools = Tool.allCases

        // Pre-select currently enabled tools
        var preSelected = IndexSet()
        for (i, tool) in allTools.enumerated() {
            if env.tools.contains(tool) { preSelected.insert(i) }
        }

        let selector = MultiSelect(
            title: "Select tools for '\(envName)' (↑↓ move, space toggle, enter confirm):",
            options: allTools.map(\.rawValue),
            selected: preSelected
        )
        let newIndices = selector.run()
        let newTools = Set(newIndices.map { allTools[$0] })
        let oldTools = Set(env.tools)

        let toAdd    = newTools.subtracting(oldTools)
        let toRemove = oldTools.subtracting(newTools)

        for tool in toRemove {
            try store.removeTool(tool, from: envName)
            print("Removed \(tool.rawValue)")
        }
        for tool in toAdd {
            try store.addTool(tool, to: envName)
            print("Added \(tool.rawValue)")
            let configDir = store.toolConfigDir(tool: tool, environment: envName)
            try ToolSetup.setup(tool, configDir: configDir, envName: envName)
        }

        if toAdd.isEmpty && toRemove.isEmpty {
            print("No changes.")
        }
    }
}
