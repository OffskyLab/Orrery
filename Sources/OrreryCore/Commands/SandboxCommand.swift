import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct SandboxCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sandbox",
        abstract: L10n.Sandbox.abstract,
        subcommands: [
            SetEnv.self, UnsetEnv.self,
            Use.self, List.self, Delete.self, Info.self, Rename.self, Current.self,
            Create.self,
        ]
    )

    public init() {}

    // MARK: - SetEnv

    public struct SetEnv: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "set-env",
            abstract: L10n.Sandbox.setEnvAbstract
        )

        @Argument(help: ArgumentHelp(L10n.Sandbox.setEnvKeyHelp)) public var key: String
        @Argument(help: ArgumentHelp(L10n.Sandbox.setEnvValueHelp)) public var value: String
        @Option(name: [.short, .customLong("sandbox")],
                help: ArgumentHelp(L10n.Sandbox.setEnvSandboxHelp)) public var sandbox: String?

        public init() {}

        public func run() throws {
            guard let envName = sandbox ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"] else {
                throw ValidationError(L10n.Sandbox.setEnvNoActive)
            }
            guard envName != ReservedEnvironment.defaultName else {
                throw ValidationError(L10n.Sandbox.setEnvOriginNotSupported)
            }
            let store = EnvironmentStore.default
            var env = try store.load(named: envName)
            env.env[key] = value
            try store.save(env)
            print(L10n.Sandbox.setEnvSuccess(key, envName))
        }
    }

    // MARK: - UnsetEnv

    public struct UnsetEnv: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "unset-env",
            abstract: L10n.Sandbox.unsetEnvAbstract
        )

        @Argument(help: ArgumentHelp(L10n.Sandbox.unsetEnvKeyHelp)) public var key: String
        @Option(name: [.short, .customLong("sandbox")],
                help: ArgumentHelp(L10n.Sandbox.setEnvSandboxHelp)) public var sandbox: String?

        public init() {}

        public func run() throws {
            // Borrows `setEnvNoActive` / `setEnvOriginNotSupported` from SetEnv:
            // the user-facing strings are tool-action-agnostic and apply equally to unset.
            // If the unset path ever needs different wording, add dedicated keys.
            guard let envName = sandbox ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"] else {
                throw ValidationError(L10n.Sandbox.setEnvNoActive)
            }
            guard envName != ReservedEnvironment.defaultName else {
                throw ValidationError(L10n.Sandbox.setEnvOriginNotSupported)
            }
            let store = EnvironmentStore.default
            var env = try store.load(named: envName)
            env.env.removeValue(forKey: key)
            try store.save(env)
            print(L10n.Sandbox.unsetEnvSuccess(key, envName))
        }
    }

    // MARK: - Use

    public struct Use: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "use",
            abstract: L10n.Use.abstract
        )

        @Argument(help: ArgumentHelp(L10n.Use.nameHelp))
        public var name: String

        public init() {}

        public func run() throws {
            stderrWrite(L10n.Use.needsShellIntegration)
            throw ExitCode.failure
        }
    }

    // MARK: - List

    public struct List: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: L10n.List.abstract
        )
        public init() {}

        public func run() throws {
            let store = EnvironmentStore.default
            let activeEnv = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
            let rows = try Self.environmentRows(activeEnv: activeEnv, store: store)
            if rows.isEmpty {
                print(L10n.List.empty)
            } else {
                print(rows.joined(separator: "\n\n"))
            }
        }

        private struct ToolRow {
            let name: String
            let suffix: String
        }

        private struct EnvRow {
            let active: String
            let name: String
            let tools: [ToolRow]
            let fallbackBody: String?
            let detail: String
        }

        public static func environmentRows(activeEnv: String?, store: EnvironmentStore) throws -> [String] {
            let names = try store.listNames().sorted()
            let defaultName = ReservedEnvironment.defaultName
            let defaultActive = activeEnv == defaultName || activeEnv == nil ? "*" : " "

            let df = DateFormatter()
            df.dateStyle = .short
            df.timeStyle = .short

            // Load env metadata serially (cheap JSON reads).
            let loadedEnvs: [(name: String, env: OrreryEnvironment)] = try names.map {
                ($0, try store.load(named: $0))
            }

            // Flatten every account-info lookup into one work list so we can run
            // them concurrently. Each lookup may hit the macOS Keychain (Claude)
            // or read JSON files (Codex/Gemini) — fanning them out makes the
            // command finish in the time of the slowest single lookup instead
            // of the sum across N envs.
            struct WorkItem: Sendable {
                let tool: Tool
                let configDir: URL?
            }
            var workItems: [WorkItem] = []

            // Origin: probe every tool to detect which are logged in.
            let originRange = workItems.count..<(workItems.count + Tool.allCases.count)
            for tool in Tool.allCases {
                workItems.append(WorkItem(tool: tool, configDir: nil))
            }

            // Per env: only its declared tools.
            var envRanges: [Range<Int>] = []
            for (name, env) in loadedEnvs {
                let start = workItems.count
                for tool in env.tools {
                    let configDir = store.toolConfigDir(tool: tool, environment: name)
                    workItems.append(WorkItem(tool: tool, configDir: configDir))
                }
                envRanges.append(start..<workItems.count)
            }

            let items = workItems
            let collector = ResultsCollector(count: items.count)
            if !items.isEmpty {
                DispatchQueue.concurrentPerform(iterations: items.count) { i in
                    let info = ToolAuth.accountInfo(tool: items[i].tool, configDir: items[i].configDir)
                    collector.set(info, at: i)
                }
            }
            let results = collector.snapshot

            // Build origin row (filter to tools that returned any info).
            let originTools: [ToolRow] = originRange.compactMap { i in
                let item = workItems[i]
                let info = results[i]
                let suffix = [info.email, info.plan, info.model].compactMap { $0 }.joined(separator: ", ")
                guard !suffix.isEmpty else { return nil }
                return ToolRow(
                    name: item.tool.rawValue,
                    suffix: Self.colorizeSuffix(suffix, email: info.email, plan: info.plan, model: info.model)
                )
            }

            var rows: [EnvRow] = [
                EnvRow(
                    active: defaultActive,
                    name: defaultName,
                    tools: originTools,
                    fallbackBody: nil,
                    detail: L10n.Create.defaultDescription
                )
            ]

            for (idx, pair) in loadedEnvs.enumerated() {
                let active = pair.name == activeEnv ? "*" : " "
                let toolRows: [ToolRow] = envRanges[idx].map { i in
                    let item = workItems[i]
                    let info = results[i]
                    let suffix = [info.email, info.plan, info.model].compactMap { $0 }.joined(separator: ", ")
                    return ToolRow(
                        name: item.tool.rawValue,
                        suffix: Self.colorizeSuffix(suffix, email: info.email, plan: info.plan, model: info.model)
                    )
                }
                let lastUsed = df.string(from: pair.env.lastUsed)
                rows.append(EnvRow(
                    active: active,
                    name: pair.name,
                    tools: toolRows,
                    fallbackBody: pair.env.tools.isEmpty ? "(none)" : nil,
                    detail: lastUsed
                ))
            }

            let nameWidth = max(12, rows.map(\.name.count).max() ?? 0) + 2
            let toolWidth = (Tool.allCases.map { $0.rawValue.count }.max() ?? 0) + 2

            return rows.map { row in
                let rawHeader = "\(row.active) \(row.name)\(String(repeating: " ", count: max(0, nameWidth - row.name.count)))\(row.detail)"
                let header = row.active == "*" ? Self.colorize(rawHeader, code: "96") : rawHeader

                let bodyLines: [String]
                if let fallbackBody = row.fallbackBody {
                    bodyLines = ["  · \(fallbackBody)"]
                } else if row.tools.isEmpty, row.name == defaultName {
                    bodyLines = Tool.allCases.map {
                        let padded = $0.rawValue + String(repeating: " ", count: max(0, toolWidth - $0.rawValue.count))
                        return Self.colorize("  · \(padded)", code: "90")
                    }
                } else {
                    bodyLines = row.tools.map { tool in
                        let paddedName = tool.name + String(repeating: " ", count: max(0, toolWidth - tool.name.count))
                        let prefix = Self.colorize("  · \(paddedName)", code: "90")
                        return tool.suffix.isEmpty ? prefix : "\(prefix)\(tool.suffix)"
                    }
                }

                return ([header] + bodyLines).joined(separator: "\n")
            }
        }

        private static func colorizeSuffix(_ suffix: String, email: String?, plan: String?, model: String?) -> String {
            var result = suffix
            if let model, !model.isEmpty, let range = result.range(of: model, options: .backwards) {
                result.replaceSubrange(range, with: colorize(model, code: "38;5;240"))
            }
            if let plan, !plan.isEmpty, let range = result.range(of: plan, options: .backwards) {
                result.replaceSubrange(range, with: colorize(plan, code: "38;5;245"))
            }
            if let email, !email.isEmpty, let range = result.range(of: email) {
                result.replaceSubrange(range, with: colorize(email, code: "38;5;252"))
            }
            return result
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
            if name == ReservedEnvironment.defaultName {
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
            guard resolvedName != ReservedEnvironment.defaultName else {
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

            print("\(L10n.Info.labelName)\(ReservedEnvironment.defaultName)")
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
            let memoryDir = store.memoryDir(projectKey: projectKey, envName: ReservedEnvironment.defaultName)
            let originConfig = store.loadOriginConfig()
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
            if name == ReservedEnvironment.defaultName || newName == ReservedEnvironment.defaultName {
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

    // MARK: - Current

    public struct Current: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "current",
            abstract: L10n.Current.abstract
        )
        public init() {}

        public func run() throws {
            if let active = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"] {
                print(active)
            } else {
                print(L10n.Current.noActive)
            }
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
}

/// Lock-protected sink for parallel `ToolAuth.accountInfo` lookups so the
/// concurrentPerform closure has a Sendable destination without resorting
/// to UnsafeMutableBufferPointer.
private final class ResultsCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ToolAuth.AccountInfo]

    init(count: Int) {
        self.values = Array(
            repeating: ToolAuth.AccountInfo(email: nil, plan: nil, model: nil, key: nil),
            count: count
        )
    }

    func set(_ value: ToolAuth.AccountInfo, at index: Int) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }

    var snapshot: [ToolAuth.AccountInfo] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
