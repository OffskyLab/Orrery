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

    @Option(name: .long, help: ArgumentHelp(L10n.Create.toolHelp))
    public var tool: String?

    @Option(name: .long, help: ArgumentHelp(L10n.Create.copyLoginHelp))
    public var copyLoginFrom: String?

    @Option(name: .long, help: ArgumentHelp(L10n.Create.cloneHelp))
    public var clone: String?

    @Flag(name: .long, help: ArgumentHelp(L10n.Create.isolateSessionsHelp))
    public var isolateSessions: Bool = false

    @Flag(name: .long, help: ArgumentHelp(L10n.Create.isolateMemoryHelp))
    public var isolateMemory: Bool = false

    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default

        if name == ReservedEnvironment.defaultName {
            throw ValidationError(L10n.Create.reservedName)
        }
        if (try? store.load(named: name)) != nil {
            throw ValidationError(L10n.Create.alreadyExists(name))
        }

        // Gather per-tool configs.
        // - `--tool X` selects the tool and skips the per-tool yes/no loop, but the
        //   sub-wizard (login / clone / sessions / memory) still runs for that tool
        //   unless those steps are also overridden by their own flags.
        // - No `--tool` runs the full wizard (yes/no per tool, then sub-wizard for each
        //   "yes"). Same per-step flag overrides apply.
        var configs: [ToolSetupRunner.Config]
        var installStatusline = false
        if let toolFlag = tool {
            guard let t = Tool(rawValue: toolFlag) else {
                throw ValidationError(L10n.Create.unknownTool(toolFlag))
            }
            configs = [ToolSetupRunner.runWizard(
                for: t,
                store: store,
                loginSourceOverride: copyLoginFrom,
                cloneSourceOverride: clone,
                isolateSessionsOverride: isolateSessions,
                isolateMemoryOverride: isolateMemory
            )]
        } else {
            (configs, installStatusline) = Self.runWizard(store: store)
        }

        // Create empty env — per-tool flags populated during apply()
        let env = OrreryEnvironment(name: name, description: description)
        try store.save(env)
        print(L10n.Create.created(name))

        // Apply each tool's config (addTool + login copy + clone settings)
        for config in configs {
            try ToolSetupRunner.apply(config, to: name, store: store)
        }

        if configs.isEmpty {
            print(L10n.Create.noToolSelected)
        } else {
            print(L10n.Create.tools(configs.map(\.tool.rawValue).joined(separator: ", ")))
        }

        // Auto-activate if this is the first environment
        let allNames = try store.listNames()
        if allNames.count == 1 {
            try store.setCurrent(name)
            print(L10n.Create.firstEnvCreated(name))
        }

        // Interactive auth fallback for tools where the user chose "independent" (no login copy)
        let toolsNeedingLogin = configs.filter { $0.loginSource == nil }.map(\.tool)
        if !toolsNeedingLogin.isEmpty {
            ToolSetup.execLoginIfNeeded(tools: toolsNeedingLogin, store: store, envName: name)
        }

        if installStatusline {
            do {
                let registry = try ThirdPartyRuntime.registry()
                let runner = try ThirdPartyRuntime.runner()
                let pkg = try registry.lookup("statusline")
                let record = try runner.install(pkg, into: name, refOverride: nil, forceRefresh: false)
                print(L10n.Create.installedStatusline(record.packageID, name))
            } catch {
                print("Could not install statusline: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Wizard

    /// Loop through all tools, asking setup/skip and running the per-tool wizard for each "setup".
    /// Returns configs and whether the user chose to install statusline (asked after Claude setup).
    static func runWizard(store: EnvironmentStore) -> ([ToolSetupRunner.Config], installStatusline: Bool) {
        var configs: [ToolSetupRunner.Config] = []
        var installStatusline = false
        for tool in Tool.allCases {
            guard askSetupTool(tool.rawValue, defaultYes: tool == .claude) else { continue }
            configs.append(ToolSetupRunner.runWizard(for: tool, store: store))
            if tool == .claude {
                installStatusline = askInstallStatusline()
            }
        }
        return (configs, installStatusline)
    }

    static func askInstallStatusline() -> Bool {
        let selector = SingleSelect(
            title: L10n.Create.askInstallStatusline,
            options: [L10n.Create.installStatuslineYes, L10n.Create.installStatuslineNo],
            selected: 0
        )
        return selector.run() == 0
    }

    static func askSetupTool(_ toolName: String, defaultYes: Bool) -> Bool {
        let selector = SingleSelect(
            title: L10n.Create.askSetupTool(toolName),
            options: [L10n.Create.setupToolYes, L10n.Create.setupToolNo],
            selected: defaultYes ? 0 : 1
        )
        return selector.run() == 0
    }

    // MARK: - Public helper (used by tests)

    public static func createEnvironment(
        name: String,
        description: String,
        tool: Tool,
        isolateSessions: Bool = false,
        isolateMemory: Bool = false,
        store: EnvironmentStore
    ) throws {
        let env = OrreryEnvironment(
            name: name,
            description: description,
            isolatedSessionTools: isolateSessions ? [tool] : [],
            isolateMemory: isolateMemory
        )
        try store.save(env)
        try store.addTool(tool, to: name)

        if tool == .claude {
            let projectKey = FileManager.default.currentDirectoryPath
                .replacingOccurrences(of: "/", with: "-")
            let claudeConfigDir = store.toolConfigDir(tool: .claude, environment: name)
            store.linkOrreryMemory(projectKey: projectKey, envName: name, claudeConfigDir: claudeConfigDir)
        }
    }
}
