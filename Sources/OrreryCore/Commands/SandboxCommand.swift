import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct SandboxCommand: ParsableCommand {
    /// Subcommand list. Shared with WorkspaceCommand (the v3.1 alias) so both
    /// commands route through the same set of operations without referencing
    /// each other's `configuration.subcommands` by structure.
    public static let subcommandTypes: [ParsableCommand.Type] = [
        List.self, Delete.self, Info.self, Rename.self,
        Create.self,
        Export.self, Unexport.self,
    ]

    public static let configuration = CommandConfiguration(
        commandName: "sandbox",
        abstract: L10n.Workspace.abstract,
        subcommands: subcommandTypes
    )

    public init() {}

    // MARK: - List

    public struct List: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: L10n.List.abstract
        )
        public init() {}

        public func run() throws {
            let store = EnvironmentStore.default
            let acctStore = AccountStore.default
            let workspaces = try store.listAllWorkspaces()
            let accountsByTool = try acctStore.listAll()
            print(Self.render(
                workspaces: workspaces,
                accountsByTool: accountsByTool,
                originPath: store.originDir
            ))
        }

        /// Grouped by tool, not by workspace — that's the axis that actually
        /// matters now: since v3.1 an `Account` carries its own `workspace`
        /// field (which workspace's shared content it's pinned to), so "which
        /// accounts does this tool have, and where is each one pinned" is the
        /// natural question. A workspace doesn't own any accounts of its own —
        /// it's pointed at by accounts, not the other way around (the previous
        /// workspace-first design read `Workspace.tools`/live credential
        /// probes, both stale under this model).
        static func render(
            workspaces: [EnvironmentStore.WorkspaceListing],
            accountsByTool: [Tool: [Account]],
            originPath: URL
        ) -> String {
            Tool.allCases.map {
                renderToolSection(
                    tool: $0, workspaces: workspaces, accounts: accountsByTool[$0] ?? [], originPath: originPath)
            }.joined(separator: "\n\n")
        }

        private static func renderToolSection(
            tool: Tool,
            workspaces: [EnvironmentStore.WorkspaceListing],
            accounts: [Account],
            originPath: URL
        ) -> String {
            let entries = [(name: Workspace.reservedOriginName, path: originPath)]
                + workspaces.map { (name: $0.name, path: $0.path) }
            let blocks = entries.map { entry -> String in
                var lines = ["\(entry.name): \(entry.path.path)"]
                let pinned = accounts.filter { $0.workspace == entry.name }
                if !pinned.isEmpty {
                    lines.append(Self.colorize("  \(L10n.List.pinnedHeader)", code: "90"))
                    lines += pinned.map { "    - \($0.displayName)\(Self.accountSuffix($0))" }
                }
                return lines.joined(separator: "\n")
            }
            let header = Self.colorize("[\(tool.rawValue.capitalized)]", code: "1")
            return "\(header)\n" + blocks.joined(separator: "\n\n")
        }

        private static func accountSuffix(_ acct: Account) -> String {
            var parts: [String] = []
            if let email = acct.email { parts.append(colorize(email, code: "38;5;252")) }
            if let plan = acct.plan { parts.append(colorize(plan, code: "38;5;245")) }
            guard !parts.isEmpty else { return "" }
            return " (\(parts.joined(separator: ", ")))"
        }

        private static func colorize(_ s: String, code: String) -> String {
            guard isatty(STDOUT_FILENO) != 0 else { return s }
            return "\u{001B}[\(code)m\(s)\u{001B}[0m"
        }
    }

    // MARK: - Delete

    public struct Delete: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: L10n.Delete.abstract
        )

        @Argument(help: ArgumentHelp(L10n.Delete.nameHelp))
        public var name: String?

        @Flag(name: .long, help: ArgumentHelp(L10n.Delete.forceHelp))
        public var force: Bool = false

        public init() {}

        public func run() throws {
            let store = EnvironmentStore.default
            if let name {
                try Self.deleteOne(name: name, force: force, store: store)
            } else {
                try Self.deleteInteractive(force: force, store: store)
            }
        }

        // MARK: - Single-target

        static func deleteOne(name: String, force: Bool, store: EnvironmentStore) throws {
            if name == Workspace.reservedOriginName {
                throw ValidationError(L10n.Delete.reservedName)
            }
            if !force {
                print(L10n.Delete.confirm(name), terminator: "")
                let input = readLine()?.lowercased().trimmingCharacters(in: .whitespaces)
                guard input == "y" || input == "yes" else {
                    print(L10n.Delete.aborted)
                    return
                }
            }
            try store.delete(named: name)
            print(L10n.Delete.deleted(name))
        }

        // MARK: - Multi-select

        static func deleteInteractive(force: Bool, store: EnvironmentStore) throws {
            let names = (try? store.listNames().sorted()) ?? []
            guard !names.isEmpty else {
                print(L10n.Delete.noEnvs)
                return
            }

            let selector = MultiSelect(title: L10n.Delete.multiSelectTitle, options: names)
            let indices = selector.run()
            let selected = indices.map { names[$0] }
            guard !selected.isEmpty else {
                print(L10n.Delete.nothingSelected)
                return
            }

            if !force {
                // Show the selection so the user can confirm what's about to be deleted.
                for n in selected { print("  - \(n)") }
                print(L10n.Delete.confirmBatch(selected.count), terminator: "")
                let input = readLine()?.lowercased().trimmingCharacters(in: .whitespaces)
                guard input == "y" || input == "yes" else {
                    print(L10n.Delete.aborted)
                    return
                }
            }

            for n in selected {
                do {
                    try store.delete(named: n)
                    print(L10n.Delete.deleted(n))
                } catch {
                    stderrWrite("⚠️  \(n): \(error.localizedDescription)\n")
                }
            }
        }

        // MARK: - Public helper (used by tests)

        public static func deleteEnvironment(name: String, force: Bool, store: EnvironmentStore) throws {
            try deleteOne(name: name, force: force, store: store)
        }
    }

    // MARK: - Info

    public struct Info: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: L10n.Info.abstract
        )

        @Argument(help: ArgumentHelp(L10n.Info.nameHelp))
        public var name: String?

        public init() {}

        public func run() throws {
            let store = EnvironmentStore.default
            let resolvedName: String
            if let name {
                resolvedName = name
            } else if let active = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"] {
                resolvedName = active
            } else {
                throw ValidationError(L10n.Info.noActive)
            }
            guard resolvedName != Workspace.reservedOriginName else {
                Self.printOriginInfo()
                return
            }
            let env = try store.load(named: resolvedName)
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .medium

            let path = try store.envDir(for: resolvedName).path
            let none = L10n.Info.none

            let projectKey = FileManager.default.currentDirectoryPath
                .replacingOccurrences(of: "/", with: "-")
            let memoryDir = store.memoryDir(projectKey: projectKey, envName: resolvedName)

            print("\(L10n.Info.labelName)\(env.name)")
            print("\(L10n.Info.labelID)\(env.id)")
            print("\(L10n.Info.labelPath)\(path)")
            print("\(L10n.Info.labelDescription)\(env.description.isEmpty ? none : env.description)")
            print("\(L10n.Info.labelCreated)\(df.string(from: env.createdAt))")
            print("\(L10n.Info.labelLastUsed)\(df.string(from: env.lastUsed))")
            // Per-tool login info: "  claude (email, plan)" or "  claude" if not logged in.
            print("\(L10n.Info.labelTools)")
            if env.tools.isEmpty {
                print("  \(none)")
            } else {
                for tool in env.tools {
                    let configDir = store.toolConfigDir(tool: tool, environment: resolvedName)
                    let info = ToolAuth.accountInfo(tool: tool, configDir: configDir)
                    let maskedKey = info.key.map { k in k.count > 8 ? String(k.prefix(4)) + "****" : "****" }
                    let suffix = [info.email, info.plan, info.model, maskedKey].compactMap { $0 }.joined(separator: ", ")
                    print(suffix.isEmpty ? "  \(tool.rawValue)" : "  \(tool.rawValue) (\(suffix))")
                    Self.printToolAuthDetail(tool: tool, configDir: configDir)
                }
            }
            let memoryMode = env.isolateMemory ? L10n.Info.modeIsolated : L10n.Info.modeShared
            print("\(L10n.Info.labelMemoryMode)\(memoryMode)")
            print("\(L10n.Info.labelMemoryPath)\(memoryDir.path)")
            // Per-tool session isolation: list each tool's mode
            print("\(L10n.Info.labelSessionMode)")
            if env.tools.isEmpty {
                print("  \(none)")
            } else {
                for tool in env.tools {
                    let mode = env.isolateSessions(for: tool) ? L10n.Info.modeIsolated : L10n.Info.modeShared
                    print("  \(tool.rawValue): \(mode)")
                }
            }
            if env.env.isEmpty {
                print("\(L10n.Info.labelEnvVars)\(none)")
            } else {
                print("\(L10n.Info.labelEnvVars)")
                for (key, value) in env.env.sorted(by: { $0.key < $1.key }) {
                    let masked = value.count > 8 ? String(value.prefix(4)) + "****" : "****"
                    print("  \(key)=\(masked)")
                }
            }
        }

        /// Info output for the reserved `origin` env — same structured format as regular envs.
        static func printOriginInfo() {
            let store = EnvironmentStore.default
            let none = L10n.Info.none

            print("\(L10n.Info.labelName)\(Workspace.reservedOriginName)")
            print("\(L10n.Info.labelPath)\(store.originDir.path)")
            print("\(L10n.Info.labelDescription)\(L10n.Create.defaultDescription)")

            // Tools: show all tools that have a config dir (managed or system)
            print(L10n.Info.labelTools)
            let toolDirs: [(Tool, URL)] = Tool.allCases.compactMap { tool in
                let configDir: URL? = store.isOriginManaged(tool: tool)
                    ? store.originConfigDir(tool: tool)
                    : (FileManager.default.fileExists(atPath: tool.defaultConfigDir.path)
                       ? tool.defaultConfigDir : nil)
                return configDir.map { (tool, $0) }
            }
            if toolDirs.isEmpty {
                print("  \(none)")
            } else {
                for (tool, dir) in toolDirs {
                    // Under origin, CLAUDE_CONFIG_DIR is unset — Claude's credential
                    // lookup must use the unset-dir conventions (keychain service
                    // without hash, ~/.claude.json at home root). Codex/Gemini
                    // store their files inside the (symlinked) managed dir, so
                    // their configDir works either way.
                    let accountDir: URL? = (tool == .claude) ? nil : dir
                    let info = ToolAuth.accountInfo(tool: tool, configDir: accountDir)
                    let maskedKey = info.key.map { k in k.count > 8 ? String(k.prefix(4)) + "****" : "****" }
                    let suffix = [info.email, info.plan, info.model, maskedKey].compactMap { $0 }.joined(separator: ", ")
                    print(suffix.isEmpty ? "  \(tool.rawValue)" : "  \(tool.rawValue) (\(suffix))")
                    printToolAuthDetail(tool: tool, configDir: accountDir)
                }
            }

            // Memory: origin respects OriginConfig
            let projectKey = FileManager.default.currentDirectoryPath
                .replacingOccurrences(of: "/", with: "-")
            let memoryDir = store.memoryDir(projectKey: projectKey, envName: Workspace.reservedOriginName)
            let originConfig = store.loadOriginWorkspace()
            let memoryMode = originConfig.isolateMemory ? L10n.Info.modeIsolated : L10n.Info.modeShared
            print("\(L10n.Info.labelMemoryMode)\(memoryMode)")
            print("\(L10n.Info.labelMemoryPath)\(memoryDir.path)")

            // Session mode: reflect OriginConfig
            print(L10n.Info.labelSessionMode)
            for tool in Tool.allCases {
                let mode = originConfig.isolateSessions(for: tool) ? L10n.Info.modeIsolated : L10n.Info.modeShared
                print("  \(tool.rawValue): \(mode)")
            }

            print("\(L10n.Info.labelEnvVars)\(none)")
        }

        /// Print the credential-store line for a tool.
        /// Pass `nil` for Claude under origin (CLAUDE_CONFIG_DIR unset → default
        /// keychain entry / `~/.claude/.credentials.json`).
        private static func printToolAuthDetail(tool: Tool, configDir: URL?) {
            switch tool {
            case .claude:
                #if os(macOS)
                print("    keychain: \(ClaudeKeychain.service(for: configDir?.path))")
                #else
                let credFile = ClaudeKeychain.credentialsFile(for: configDir?.path)
                if FileManager.default.fileExists(atPath: credFile.path) {
                    print("    file: \(credFile.path)")
                }
                #endif
            case .codex:
                guard let configDir else { return }
                let file = configDir.appendingPathComponent("auth.json")
                if FileManager.default.fileExists(atPath: file.path) {
                    print("    file: \(file.path)")
                }
            case .gemini:
                guard let configDir else { return }
                let credFile = configDir.appendingPathComponent("gemini-credentials.json")
                let oauthFile = configDir.appendingPathComponent("oauth_creds.json")
                let fm = FileManager.default
                if fm.fileExists(atPath: credFile.path) {
                    print("    file: \(credFile.path)")
                } else if fm.fileExists(atPath: oauthFile.path) {
                    print("    file: \(oauthFile.path)")
                }
            }
        }
    }

    // MARK: - Rename

    public struct Rename: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "rename",
            abstract: L10n.Rename.abstract
        )

        @Argument(help: ArgumentHelp(L10n.Rename.nameHelp))
        public var name: String

        @Argument(help: ArgumentHelp(L10n.Rename.newNameHelp))
        public var newName: String

        public init() {}

        public func run() throws {
            if name == Workspace.reservedOriginName || newName == Workspace.reservedOriginName {
                throw ValidationError(L10n.Rename.reservedName)
            }
            let store = EnvironmentStore.default
            try Self.renameEnvironment(from: name, to: newName, store: store)
            print(L10n.Rename.renamed(name, newName))
        }

        public static func renameEnvironment(from oldName: String, to newName: String, store: EnvironmentStore) throws {
            try store.rename(from: oldName, to: newName)
        }
    }

    // MARK: - Create

    public struct Create: ParsableCommand {
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

            if name == Workspace.reservedOriginName {
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
            let env = Workspace(name: name, description: description)
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
            let env = Workspace(
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

    // MARK: - Export

    public struct Export: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "_export",
            abstract: L10n.Export.abstract,
            shouldDisplay: false
        )

        @Argument var name: String
        public init() {}

        public func run() throws {
            let store = EnvironmentStore.default
            let lines = try Self.exportLines(for: name, store: store)
            print(lines.joined(separator: "\n"))
        }

        public static func exportLines(for name: String, store: EnvironmentStore) throws -> [String] {
            guard name != Workspace.reservedOriginName else { return [] }
            var env = try store.load(named: name)
            env.lastUsed = Date()
            try store.save(env)

            // Ensure shared session symlinks are in place for existing environments
            // (per-tool: only the tools whose sessions aren't isolated)
            for tool in env.tools where !env.isolateSessions(for: tool) {
                try store.ensureSharedSessionLinks(tool: tool, environment: name)
            }
            // gemini-cli ignores GEMINI_CONFIG_DIR; isolation is achieved by
            // overriding HOME to a wrapper dir whose `.gemini` symlinks back to
            // the env's gemini config. Make sure the wrapper exists for old envs.
            if env.tools.contains(.gemini) {
                try store.ensureGeminiHomeWrapper(envName: name)
            }

            var lines: [String] = []
            for tool in env.tools {
                let dir = store.toolConfigDir(tool: tool, environment: name).path
                lines.append("export \(tool.envVarName)=\(dir)")
            }
            if env.tools.contains(.gemini) {
                let homeDir = store.geminiHomeDir(environment: name).path
                lines.append("export ORRERY_GEMINI_HOME=\(homeDir)")
            }
            for (key, value) in env.env.sorted(by: { $0.key < $1.key }) {
                lines.append("export \(key)=\(value)")
            }
            return lines
        }
    }

    // MARK: - Unexport

    public struct Unexport: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "_unexport",
            abstract: L10n.Unexport.abstract,
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
            guard name != Workspace.reservedOriginName else { return [] }
            let env = try store.load(named: name)
            var lines: [String] = []

            for tool in env.tools {
                lines.append("unset \(tool.envVarName)")
            }
            if env.tools.contains(.gemini) {
                lines.append("unset ORRERY_GEMINI_HOME")
            }

            for key in env.env.keys.sorted() {
                lines.append("unset \(key)")
            }

            return lines
        }
    }
}

