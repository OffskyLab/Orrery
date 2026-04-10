import ArgumentParser
import Foundation

private extension String {
    var shellEscaped: String { "'\(replacingOccurrences(of: "'", with: "'\\''"))'" }
}

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

    @Flag(name: .long, help: ArgumentHelp(L10n.Create.isolateMemoryHelp))
    public var isolateMemory: Bool = false

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

        // Each wizard step only runs if its corresponding flag wasn't provided
        let tools: [Tool]
        if !flaggedTools.isEmpty {
            tools = flaggedTools
        } else if clone != nil {
            tools = []
        } else {
            tools = Self.runToolWizard()
        }

        let cloneSource: String?
        if let clone {
            cloneSource = clone
        } else {
            cloneSource = Self.askCloneSource(store: store)
        }

        let shouldIsolate: Bool
        if isolateSessions {
            shouldIsolate = true
        } else {
            shouldIsolate = Self.askSessionIsolation()
        }

        let shouldIsolateMemory: Bool
        if isolateMemory {
            shouldIsolateMemory = true
        } else {
            shouldIsolateMemory = Self.askMemoryIsolation()
        }

        try Self.createEnvironment(
            name: name,
            description: description,
            cloneFrom: cloneSource,
            tools: tools,
            isolateSessions: shouldIsolate,
            isolateMemory: shouldIsolateMemory,
            store: store
        )
        print(L10n.Create.created(name))
        if let cloneSource { print(L10n.Create.cloned(cloneSource)) }
        if !tools.isEmpty { print(L10n.Create.tools(tools.map(\.rawValue).joined(separator: ", "))) }
        print(L10n.Create.sessions(shouldIsolate))
        print(L10n.Create.memory(shouldIsolateMemory))

        // Setup each tool (install check)
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

        // Ask about login for each tool, then execvp into shell at the end
        var loginCommands: [String] = []
        for t in tools {
            guard let authCmd = t.authLoginCommand else { continue }
            print("")
            FileHandle.standardOutput.write(Data(L10n.ToolSetup.loginNow(t.rawValue).utf8))
            let input = readLine()?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
            guard input.isEmpty || input == "y" || input == "yes" else {
                print(L10n.ToolSetup.skippingLogin(t.rawValue))
                continue
            }
            let configDir = store.toolConfigDir(tool: t, environment: name)
            let cmd = authCmd.joined(separator: " ")
            loginCommands.append("\(t.envVarName)=\(configDir.path.shellEscaped) \(cmd)")
        }

        guard !loginCommands.isEmpty else { return }

        // Strip IPC vars to prevent claude from hanging when launched from Claude Code
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        env.removeValue(forKey: "CLAUDE_CODE_EXECPATH")
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        for (key, value) in env { setenv(key, value, 1) }

        let shellCmd = loginCommands.joined(separator: "; ")
        let argv = (["/bin/sh", "-c", shellCmd] as [String]).map { strdup($0) } + [nil]
        execvp("/bin/sh", UnsafeMutablePointer(mutating: argv))
        perror("execvp")
        throw ExitCode.failure
    }

    // MARK: - Wizard steps

    static func runToolWizard() -> [Tool] {
        let selector = MultiSelect(
            title: L10n.Create.wizardTitle,
            options: Tool.allCases.map(\.rawValue)
        )
        let indices = selector.run()
        return indices.map { Tool.allCases[$0] }
    }

    static func askCloneSource(store: EnvironmentStore) -> String? {
        let defaultName = ReservedEnvironment.defaultName
        var options = [L10n.Create.cloneNone]
        var sources: [String?] = [nil]

        // Add "default" option (clone from system config)
        options.append(L10n.Create.cloneFrom("\(defaultName) - \(L10n.Create.defaultDescription)"))
        sources.append(defaultName)

        // Add existing environments
        if let names = try? store.listNames() {
            for name in names.sorted() {
                if let env = try? store.load(named: name) {
                    let label = env.description.isEmpty ? name : "\(name) - \(env.description)"
                    options.append(L10n.Create.cloneFrom(label))
                    sources.append(name)
                }
            }
        }

        // Skip if no environments to clone from (only "don't clone" and "default")
        guard options.count > 1 else { return nil }

        let selector = SingleSelect(
            title: L10n.Create.clonePrompt,
            options: options,
            selected: 0
        )
        let idx = selector.run()
        return sources[idx]
    }

    static func askMemoryIsolation() -> Bool {
        let selector = SingleSelect(
            title: L10n.Create.memorySharePrompt,
            options: [
                L10n.Create.memoryShareYes,
                L10n.Create.memoryShareNo,
            ],
            selected: 1
        )
        return selector.run() == 1
    }

    static func askSessionIsolation() -> Bool {
        let selector = SingleSelect(
            title: L10n.Create.sessionSharePrompt,
            options: [
                L10n.Create.sessionShareYes,
                L10n.Create.sessionShareNo,
            ],
            selected: 0
        )
        return selector.run() == 1
    }

    // MARK: - Create logic

    public static func createEnvironment(
        name: String,
        description: String,
        cloneFrom source: String?,
        tools: [Tool] = [],
        isolateSessions: Bool = false,
        isolateMemory: Bool = false,
        store: EnvironmentStore
    ) throws {
        var env = OrbitalEnvironment(name: name, description: description, isolateSessions: isolateSessions, isolateMemory: isolateMemory)

        if let source, source != ReservedEnvironment.defaultName {
            let sourceEnv = try store.load(named: source)
            env.tools = sourceEnv.tools
            env.env = sourceEnv.env
        }

        try store.save(env)

        // Add each tool (creates config subdirectory + session symlinks if shared)
        let toolsToAdd = tools.isEmpty && source != nil ? env.tools : tools
        for t in toolsToAdd {
            try store.addTool(t, to: name)
        }

        // Clone config files from source
        if let source {
            let fm = FileManager.default
            let isDefault = source == ReservedEnvironment.defaultName
            let toolsToCopy = isDefault ? Tool.allCases.filter { fm.fileExists(atPath: $0.defaultConfigDir.path) } : env.tools

            for t in toolsToCopy {
                let srcDir = isDefault ? t.defaultConfigDir : store.toolConfigDir(tool: t, environment: source)
                let dstDir = store.toolConfigDir(tool: t, environment: name)

                guard fm.fileExists(atPath: srcDir.path) else { continue }

                // If tool wasn't added yet (cloning from default), add it
                if isDefault {
                    try store.addTool(t, to: name)
                }

                // Copy contents (skip session dirs that are symlinked)
                let contents = (try? fm.contentsOfDirectory(atPath: srcDir.path)) ?? []
                for item in contents {
                    let src = srcDir.appendingPathComponent(item)
                    let dst = dstDir.appendingPathComponent(item)
                    // Don't overwrite symlinks (session sharing)
                    if fm.fileExists(atPath: dst.path) { continue }
                    try? fm.copyItem(at: src, to: dst)
                }
            }
        }
    }
}
