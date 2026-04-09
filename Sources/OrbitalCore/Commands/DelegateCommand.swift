import ArgumentParser
import Foundation

public struct DelegateCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "delegate",
        abstract: L10n.Delegate.abstract,
        discussion: "Example: orbital delegate --claude -e work \"check error handling\""
    )

    @Flag(help: ArgumentHelp(L10n.ToolFlag.claude))
    public var claude: Bool = false

    @Flag(help: ArgumentHelp(L10n.ToolFlag.codex))
    public var codex: Bool = false

    @Flag(help: ArgumentHelp(L10n.ToolFlag.gemini))
    public var gemini: Bool = false

    @Option(name: .shortAndLong, help: ArgumentHelp(L10n.Delegate.envHelp))
    public var environment: String?

    @Argument(help: ArgumentHelp(L10n.Delegate.promptHelp))
    public var prompt: String

    public init() {}

    public func run() throws {
        let tool = resolvedTool()
        let envName = environment ?? ProcessInfo.processInfo.environment["ORBITAL_ACTIVE_ENV"]

        let store = EnvironmentStore.default

        // Build environment variables
        var envVars: [String: String] = [:]
        if let envName, envName != ReservedEnvironment.defaultName {
            let env = try store.load(named: envName)
            for t in env.tools {
                envVars[t.envVarName] = store.toolConfigDir(tool: t, environment: envName).path
            }
            for (key, value) in env.env {
                envVars[key] = value
            }
        }

        var processEnv = ProcessInfo.processInfo.environment
        for (key, value) in envVars {
            processEnv[key] = value
        }
        // Strip IPC variables to prevent child claude from hanging
        processEnv.removeValue(forKey: "CLAUDECODE")
        processEnv.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        processEnv.removeValue(forKey: "CLAUDE_CODE_EXECPATH")
        if let envName, envName == ReservedEnvironment.defaultName {
            for t in Tool.allCases {
                processEnv.removeValue(forKey: t.envVarName)
            }
        }

        let command: [String]
        switch tool {
        case .claude: command = ["claude", "-p", prompt, "--allowedTools", "Bash"]
        case .codex:  command = ["codex", "-q", prompt]
        case .gemini: command = ["gemini", "-p", prompt]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.environment = processEnv
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        throw ExitCode(process.terminationStatus)
    }

    private func resolvedTool() -> Tool {
        if codex { return .codex }
        if gemini { return .gemini }
        return .claude
    }
}
