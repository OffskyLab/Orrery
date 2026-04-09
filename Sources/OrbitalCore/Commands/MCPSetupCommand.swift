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

            // 1. Write MCP server config to .claude/settings.json
            try Self.installMCPConfig(projectDir: cwd)

            // 2. Install slash commands
            try Self.installSlashCommands(projectDir: cwd)

            print(L10n.MCPSetup.success)
        }

        static func installMCPConfig(projectDir: String) throws {
            let fm = FileManager.default
            let claudeDir = URL(fileURLWithPath: projectDir).appendingPathComponent(".claude")
            try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)

            let settingsFile = claudeDir.appendingPathComponent("settings.json")

            // Read existing settings or start fresh
            var settings: [String: Any] = [:]
            if fm.fileExists(atPath: settingsFile.path),
               let data = try? Data(contentsOf: settingsFile),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings = existing
            }

            // Find orbital binary path
            let orbitalPath = Self.findOrbitalPath() ?? "orbital"

            // Add/update mcpServers.orbital
            var mcpServers = settings["mcpServers"] as? [String: Any] ?? [:]
            mcpServers["orbital"] = [
                "type": "stdio",
                "command": orbitalPath,
                "args": ["mcp-server"]
            ]
            settings["mcpServers"] = mcpServers

            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsFile)

            FileHandle.standardError.write(Data(L10n.MCPSetup.wroteSettings(settingsFile.path).utf8))
        }

        static func findOrbitalPath() -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = ["orbital"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == false ? output : nil
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
