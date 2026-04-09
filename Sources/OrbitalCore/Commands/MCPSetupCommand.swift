import ArgumentParser
import Foundation

public struct MCPSetupCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: L10n.MCPSetup.abstract,
        subcommands: [SetupSubcommand.self],
        defaultSubcommand: SetupSubcommand.self
    )

    public init() {}

    public struct SetupSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "setup",
            abstract: L10n.MCPSetup.setupAbstract
        )

        public init() {}

        public func run() throws {
            let fm = FileManager.default
            let cwd = fm.currentDirectoryPath

            // 1. Register MCP server with each installed tool
            Self.registerMCP(tool: "claude", args: ["claude", "mcp", "add", "--scope", "project", "orbital", "--", "orbital", "mcp-server"])
            Self.registerMCP(tool: "codex", args: ["codex", "mcp", "add", "orbital", "--", "orbital", "mcp-server"])
            Self.registerMCP(tool: "gemini", args: ["gemini", "mcp", "add", "orbital", "--", "orbital", "mcp-server"])

            // 2. Install slash commands
            try Self.installSlashCommands(projectDir: cwd)

            print(L10n.MCPSetup.success)
        }

        static func registerMCP(tool: String, args: [String]) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = args
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError

            // Strip IPC variables to prevent hanging inside AI tool sessions
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "CLAUDECODE")
            env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
            env.removeValue(forKey: "CLAUDE_CODE_EXECPATH")
            process.environment = env

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // Tool not installed — skip silently
            }
        }

        static func installSlashCommands(projectDir: String) throws {
            let fm = FileManager.default
            let commandsDir = URL(fileURLWithPath: projectDir)
                .appendingPathComponent(".claude")
                .appendingPathComponent("commands")
            try fm.createDirectory(at: commandsDir, withIntermediateDirectories: true)

            // List available environments for the prompt
            let store = EnvironmentStore.default
            let envNames = (try? store.listNames().sorted()) ?? []
            let envList = ([ReservedEnvironment.defaultName] + envNames)
                .map { "- \($0)" }
                .joined(separator: "\n")

            let delegateMd = commandsDir.appendingPathComponent("delegate.md")
            let delegateContent = """
            # Delegate task to another account

            Delegate a task to an AI tool running under a different Orbital environment (account).

            Available environments:
            \(envList)

            Usage: Specify which environment to use and describe the task.

            Example: /delegate Use the "work" environment to review the recent changes for security issues.

            When this command is invoked, run:
            ```
            orbital delegate -e <environment> "$ARGUMENTS"
            ```

            Replace `<environment>` with the environment name the user specified.
            If no environment is specified, ask the user which one to use and show the available environments listed above.
            """
            try delegateContent.write(to: delegateMd, atomically: true, encoding: .utf8)

            let sessionsMd = commandsDir.appendingPathComponent("sessions.md")
            let sessionsContent = """
            # List AI sessions

            List all AI tool sessions for the current project.

            When this command is invoked, run:
            ```
            orbital sessions
            ```

            Show the results to the user. If they want to resume a session, suggest:
            ```
            orbital resume <index>
            ```
            """
            try sessionsContent.write(to: sessionsMd, atomically: true, encoding: .utf8)
        }
    }
}
