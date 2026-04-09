import ArgumentParser
import Foundation

public struct CreateCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: L10n.Create.abstract
    )

    @Argument(help: ArgumentHelp(L10n.Create.nameHelp))
    public var name: String

    @Option(name: .shortAndLong, help: ArgumentHelp(L10n.Create.descriptionHelp))
    public var description: String = ""

    @Option(name: .long, help: ArgumentHelp(L10n.Create.cloneHelp))
    public var clone: String?

    @Option(name: .long, help: ArgumentHelp(L10n.Create.toolHelp))
    public var tool: [String] = []

    @Flag(name: .long, help: ArgumentHelp(L10n.Create.isolateSessionsHelp))
    public var isolateSessions: Bool = false

    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default

        if name == ReservedEnvironment.defaultName {
            throw ValidationError(L10n.Create.reservedName)
        }

        // Check for duplicate name before showing wizard
        if (try? store.load(named: name)) != nil {
            throw ValidationError(L10n.Create.alreadyExists(name))
        }

        // Resolve tools from --tool flags
        let flaggedTools = try tool.map { raw -> Tool in
            guard let t = Tool(rawValue: raw) else {
                throw ValidationError(L10n.Create.unknownTool(raw))
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

        // Determine session isolation (only prompt in interactive wizard mode)
        let shouldIsolate: Bool
        if isolateSessions {
            shouldIsolate = true
        } else if flaggedTools.isEmpty && clone == nil {
            shouldIsolate = Self.askSessionIsolation()
        } else {
            shouldIsolate = false
        }

        try Self.createEnvironment(name: name, description: description, cloneFrom: clone, tools: tools, isolateSessions: shouldIsolate, store: store)
        print(L10n.Create.created(name))
        if let clone { print(L10n.Create.cloned(clone)) }
        if !tools.isEmpty { print(L10n.Create.tools(tools.map(\.rawValue).joined(separator: ", "))) }
        print(L10n.Create.sessions(shouldIsolate))

        // Setup each tool (install check + auth)
        for t in tools {
            let configDir = store.toolConfigDir(tool: t, environment: name)
            try ToolSetup.setup(t, configDir: configDir, envName: name)
        }

        // Auto-activate if this is the first environment
        let allNames = try store.listNames()
        if allNames.count == 1 {
            try store.setCurrent(name)
            print(L10n.Create.firstEnvCreated(name))
        }
    }

    static func runWizard() -> [Tool] {
        let selector = MultiSelect(
            title: L10n.Create.wizardTitle,
            options: Tool.allCases.map(\.rawValue)
        )
        let indices = selector.run()
        return indices.map { Tool.allCases[$0] }
    }

    static func askSessionIsolation() -> Bool {
        print(L10n.Create.sessionSharePrompt)
        print(L10n.Create.sessionShareYes)
        print(L10n.Create.sessionShareNo)
        print("", terminator: "> ")
        guard let input = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return false
        }
        return input == "n" || input == "no"
    }

    public static func createEnvironment(
        name: String,
        description: String,
        cloneFrom source: String?,
        tools: [Tool] = [],
        isolateSessions: Bool = false,
        store: EnvironmentStore
    ) throws {
        var env = OrbitalEnvironment(name: name, description: description, isolateSessions: isolateSessions)

        if let source {
            let sourceEnv = try store.load(named: source)
            env.tools = sourceEnv.tools
            env.env = sourceEnv.env
        }

        try store.save(env)

        // Add each tool (creates config subdirectory + session symlinks if shared)
        for t in tools {
            try store.addTool(t, to: name)
        }
    }
}
