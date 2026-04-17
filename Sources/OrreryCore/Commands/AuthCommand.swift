import ArgumentParser
import Foundation

public struct AuthCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Show authentication info for tools in an environment",
        subcommands: [ShowSubcommand.self]
    )
    public init() {}

    // MARK: - Show

    public struct ShowSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Display credential info for one or more tools"
        )

        @Option(name: .shortAndLong, help: "Environment name (defaults to ORRERY_ACTIVE_ENV)")
        public var env: String?

        @Flag(name: .customLong("claude"), help: "Show Claude auth info")
        public var showClaude: Bool = false

        @Flag(name: .customLong("codex"), help: "Show Codex auth info")
        public var showCodex: Bool = false

        @Flag(name: .customLong("gemini"), help: "Show Gemini auth info")
        public var showGemini: Bool = false

        @Flag(name: .customLong("filename"), help: "Show credential file or keychain identifier")
        public var filename: Bool = false

        @Flag(name: .customLong("masked-key"), help: "Show masked API key")
        public var maskedKey: Bool = false

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

            // Which tools to show
            let anyToolFlag = showClaude || showCodex || showGemini
            var tools: [Tool] = []
            if !anyToolFlag || showClaude { tools.append(.claude) }
            if !anyToolFlag || showCodex  { tools.append(.codex) }
            if !anyToolFlag || showGemini { tools.append(.gemini) }

            // Which fields to show: if neither flag is set, show both
            let showFilename = filename || (!filename && !maskedKey)
            let showKey      = maskedKey || (!filename && !maskedKey)

            let isOrigin = resolvedName == ReservedEnvironment.defaultName

            // When a specific tool is requested, output plain values (scriptable).
            // When showing all tools, use labelled group format.
            let plainOutput = anyToolFlag

            for tool in tools {
                let configDir: URL = isOrigin
                    ? store.originConfigDir(tool: tool)
                    : store.toolConfigDir(tool: tool, environment: resolvedName)

                let info = ToolAuth.accountInfo(tool: tool, configDir: configDir)

                var values: [String] = []

                if showFilename {
                    switch tool {
                    case .claude:
                        #if canImport(CryptoKit)
                        values.append(ClaudeKeychain.service(for: configDir.path))
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
                }

                if showKey, let key = info.key {
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
