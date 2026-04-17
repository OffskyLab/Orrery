import ArgumentParser
import Foundation

public struct InfoCommand: ParsableCommand {
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
                let info = ToolAuth.accountInfo(tool: tool, configDir: dir)
                let maskedKey = info.key.map { k in k.count > 8 ? String(k.prefix(4)) + "****" : "****" }
                let suffix = [info.email, info.plan, info.model, maskedKey].compactMap { $0 }.joined(separator: ", ")
                print(suffix.isEmpty ? "  \(tool.rawValue)" : "  \(tool.rawValue) (\(suffix))")
                printToolAuthDetail(tool: tool, configDir: dir)
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

    private static func printToolAuthDetail(tool: Tool, configDir: URL) {
        switch tool {
        case .claude:
            #if os(macOS)
            print("    keychain: \(ClaudeKeychain.service(for: configDir.path))")
            #else
            let credFile = ClaudeKeychain.credentialsFile(for: configDir.path)
            if FileManager.default.fileExists(atPath: credFile.path) {
                print("    file: \(credFile.path)")
            }
            #endif
        case .codex:
            let file = configDir.appendingPathComponent("auth.json")
            if FileManager.default.fileExists(atPath: file.path) {
                print("    file: \(file.path)")
            }
        case .gemini:
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
