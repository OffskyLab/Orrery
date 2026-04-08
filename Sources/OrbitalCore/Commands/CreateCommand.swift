import ArgumentParser
import Foundation

public struct CreateCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new orbital environment"
    )

    @Argument(help: "Name for the new environment")
    public var name: String

    @Option(name: .shortAndLong, help: "Description for this environment")
    public var description: String = ""

    @Option(name: .long, help: "Clone tools and env vars from an existing environment")
    public var clone: String?

    @Option(name: .long, help: "Add a tool (claude, codex, gemini). Repeatable: --tool claude --tool codex")
    public var tool: [String] = []

    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default

        // Resolve tools from --tool flags
        let flaggedTools = try tool.map { raw -> Tool in
            guard let t = Tool(rawValue: raw) else {
                throw ValidationError("Unknown tool '\(raw)'. Valid tools: \(Tool.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return t
        }

        // Determine which tools to use
        let tools: [Tool]
        if !flaggedTools.isEmpty {
            // --tool provided — skip wizard
            tools = flaggedTools
        } else if clone != nil {
            // --clone provided — tools come from source, skip wizard
            tools = []
        } else {
            // Interactive wizard
            tools = Self.runWizard()
        }

        try Self.createEnvironment(name: name, description: description, cloneFrom: clone, tools: tools, store: store)
        print("Created environment: \(name)")
        if let clone { print("Cloned tools and env vars from: \(clone)") }
        if !tools.isEmpty { print("Tools: \(tools.map(\.rawValue).joined(separator: ", "))") }

        // Setup each tool (install check + auth)
        for t in tools {
            let configDir = store.toolConfigDir(tool: t, environment: name)
            try ToolSetup.setup(t, configDir: configDir)
        }

        // Auto-activate if this is the first environment
        let allNames = try store.listNames()
        if allNames.count == 1 {
            try store.setCurrent(name)
            print("\nFirst environment created — activating '\(name)' automatically.")
            print("Run 'orbital use \(name)' to apply it to this shell.")
        }
    }

    static func runWizard() -> [Tool] {
        let selector = MultiSelect(
            title: "Select tools to add (↑↓ move, space toggle, enter confirm):",
            options: Tool.allCases.map(\.rawValue)
        )
        let indices = selector.run()
        return indices.map { Tool.allCases[$0] }
    }

    public static func createEnvironment(
        name: String,
        description: String,
        cloneFrom source: String?,
        tools: [Tool] = [],
        store: EnvironmentStore
    ) throws {
        if (try? store.load(named: name)) != nil {
            throw ValidationError("Environment '\(name)' already exists. Use a different name or 'orbital delete \(name)' first.")
        }

        var env = OrbitalEnvironment(name: name, description: description)

        if let source {
            let sourceEnv = try store.load(named: source)
            env.tools = sourceEnv.tools
            env.env = sourceEnv.env
        }

        try store.save(env)

        // Add each tool (creates config subdirectory)
        for t in tools {
            try store.addTool(t, to: name)
        }
    }
}
