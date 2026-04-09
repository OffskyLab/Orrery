import ArgumentParser
import Foundation

public struct RunCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: L10n.Run.abstract,
        discussion: "Example: orbital run -e work claude --resume <id>"
    )

    @Option(name: .shortAndLong, help: ArgumentHelp(L10n.Run.envHelp))
    public var environment: String?

    @Argument(parsing: .allUnrecognized, help: ArgumentHelp(L10n.Run.commandHelp))
    public var command: [String] = []

    public init() {}

    public func run() throws {
        guard !command.isEmpty else {
            throw ValidationError(L10n.Run.noCommand)
        }

        let store = EnvironmentStore.default
        let envName = environment ?? ProcessInfo.processInfo.environment["ORBITAL_ACTIVE_ENV"]

        // Build environment variables
        var envVars: [String: String] = [:]
        if let envName, envName != ReservedEnvironment.defaultName {
            let env = try store.load(named: envName)
            for tool in env.tools {
                envVars[tool.envVarName] = store.toolConfigDir(tool: tool, environment: envName).path
            }
            for (key, value) in env.env {
                envVars[key] = value
            }
        }

        // Run the command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command

        // Inherit current environment + overlay orbital env vars
        var processEnv = ProcessInfo.processInfo.environment
        for (key, value) in envVars {
            processEnv[key] = value
        }
        // Strip IPC variables to prevent child claude from hanging
        processEnv.removeValue(forKey: "CLAUDECODE")
        processEnv.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        processEnv.removeValue(forKey: "CLAUDE_CODE_EXECPATH")
        // If using default, unset tool config dirs
        if let envName, envName == ReservedEnvironment.defaultName {
            for tool in Tool.allCases {
                processEnv.removeValue(forKey: tool.envVarName)
            }
        }
        process.environment = processEnv

        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        throw ExitCode(process.terminationStatus)
    }
}
