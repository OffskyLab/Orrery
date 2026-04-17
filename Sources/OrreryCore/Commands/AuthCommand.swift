import ArgumentParser
import Foundation

public struct AuthCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Show authentication info for tools in an environment",
        subcommands: [StoreSubcommand.self]
    )
    public init() {}

    // MARK: - Store

    public struct StoreSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "store",
            abstract: "Display credential store info (keychain service, file path, masked key) for tools"
        )

        @Option(name: .shortAndLong, help: "Environment name (defaults to ORRERY_ACTIVE_ENV)")
        public var env: String?

        @Flag(name: .customLong("claude"), help: "Show Claude credential store")
        public var showClaude: Bool = false

        @Flag(name: .customLong("codex"), help: "Show Codex credential store")
        public var showCodex: Bool = false

        @Flag(name: .customLong("gemini"), help: "Show Gemini credential store")
        public var showGemini: Bool = false

        public init() {}

        public func run() throws {
            let store = EnvironmentStore.default
            let resolvedName: String
            if let env {
                resolvedName = env
            } else if let active = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"] {
                resolvedName = active
            } else {
                throw ValidationError("No environment specified. Use --env or set ORRERY_ACTIVE_ENV.")
            }

            let anyToolFlag = showClaude || showCodex || showGemini
            var tools: [Tool] = []
            if !anyToolFlag || showClaude { tools.append(.claude) }
            if !anyToolFlag || showCodex  { tools.append(.codex) }
            if !anyToolFlag || showGemini { tools.append(.gemini) }

            let isOrigin = resolvedName == ReservedEnvironment.defaultName
            let plainOutput = anyToolFlag

            for tool in tools {
                let configDir: URL = isOrigin
                    ? store.originConfigDir(tool: tool)
                    : store.toolConfigDir(tool: tool, environment: resolvedName)

                let info = ToolAuth.accountInfo(tool: tool, configDir: configDir)

                var values: [String] = []

                switch tool {
                case .claude:
                    #if os(macOS)
                    values.append(ClaudeKeychain.service(for: configDir.path))
                    #else
                    values.append(ClaudeKeychain.credentialsFile(for: configDir.path).path)
                    #endif
                case .codex:
                    values.append(configDir.appendingPathComponent("auth.json").path)
                case .gemini:
                    let credFile = configDir.appendingPathComponent("gemini-credentials.json")
                    let oauthFile = configDir.appendingPathComponent("oauth_creds.json")
                    let fm = FileManager.default
                    if fm.fileExists(atPath: credFile.path) {
                        values.append(credFile.path)
                    } else if fm.fileExists(atPath: oauthFile.path) {
                        values.append(oauthFile.path)
                    } else {
                        values.append(configDir.path)
                    }
                }

                if let key = info.key {
                    let masked = key.count > 8 ? String(key.prefix(4)) + "****" : "****"
                    values.append(masked)
                }

                guard !values.isEmpty else { continue }

                if plainOutput {
                    values.forEach { print($0) }
                } else {
                    print("\(tool.rawValue):")
                    values.forEach { print("  \($0)") }
                }
            }
        }
    }
}
