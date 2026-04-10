import ArgumentParser
import Foundation

public struct ToolsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tools",
        abstract: L10n.Tools.abstract
    )

    @Option(name: .shortAndLong, help: ArgumentHelp(L10n.Tools.envHelp))
    public var environment: String?

    public init() {}

    public func run() throws {
        guard let envName = environment ?? ProcessInfo.processInfo.environment["ORBITAL_ACTIVE_ENV"] else {
            throw ValidationError(L10n.Tools.noActive)
        }

        guard envName != ReservedEnvironment.defaultName else {
            throw ValidationError(L10n.Tools.defaultNotSupported)
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
            title: L10n.Tools.wizardTitle(envName),
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
            print(L10n.Tools.removed(tool.rawValue))
        }
        for tool in toAdd {
            try store.addTool(tool, to: envName)
            print(L10n.Tools.added(tool.rawValue))
            let configDir = store.toolConfigDir(tool: tool, environment: envName)
            try ToolSetup.setup(tool, configDir: configDir, envName: envName)
        }

        if toAdd.isEmpty && toRemove.isEmpty {
            print(L10n.Tools.noChanges)
        }

        // Offer login for newly added tools (execvp — must be last step)
        if !toAdd.isEmpty {
            ToolSetup.execLoginIfNeeded(tools: Array(toAdd), store: store, envName: envName)
        }
    }
}
