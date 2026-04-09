import ArgumentParser
import Foundation

public struct ResumeCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "resume",
        abstract: L10n.Resume.abstract,
        discussion: "Example: orbital resume 1 --dangerously-skip-permissions"
    )

    @Flag(help: "Resume Anthropic Claude session (default)")
    public var claude: Bool = false

    @Flag(help: "Resume OpenAI Codex session")
    public var codex: Bool = false

    @Flag(help: "Resume Google Gemini session")
    public var gemini: Bool = false

    @Argument(parsing: .allUnrecognized)
    public var remaining: [String] = []

    public init() {}

    public func run() throws {
        let tool = resolvedTool()

        // Extract index from remaining args
        guard let indexStr = remaining.first(where: { !$0.hasPrefix("-") }),
              let index = Int(indexStr), index > 0 else {
            throw ValidationError(L10n.Resume.noIndex)
        }

        let passthrough = remaining.filter { $0 != indexStr }

        // Find sessions
        let cwd = FileManager.default.currentDirectoryPath
        let store = EnvironmentStore.default
        let entries = SessionsCommand.findSessions(tool: tool, cwd: cwd, store: store)
            .sorted { ($0.lastTime ?? .distantPast) > ($1.lastTime ?? .distantPast) }

        guard index <= entries.count else {
            throw ValidationError(L10n.Resume.indexOutOfRange(index, entries.count))
        }

        let session = entries[index - 1]

        // Build command
        var command: [String]
        switch tool {
        case .claude: command = ["claude", "--resume", session.id]
        case .codex:  command = ["codex", "resume", session.id]
        case .gemini: command = ["gemini", "--resume", session.id]
        }
        command += passthrough

        // Use active environment
        let envName = ProcessInfo.processInfo.environment["ORBITAL_ACTIVE_ENV"]
        var processEnv = ProcessInfo.processInfo.environment
        if let envName, envName != ReservedEnvironment.defaultName {
            let env = try store.load(named: envName)
            for t in env.tools {
                processEnv[t.envVarName] = store.toolConfigDir(tool: t, environment: envName).path
            }
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
