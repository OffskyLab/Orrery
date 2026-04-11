import ArgumentParser
import Foundation

public struct LinkMemoryCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_link-memory",
        abstract: "Internal: symlink ORBITAL_MEMORY.md into Claude's auto-memory directory",
        shouldDisplay: false
    )

    public init() {}

    public func run() throws {
        let projectKey = FileManager.default.currentDirectoryPath
            .replacingOccurrences(of: "/", with: "-")
        let envName = ProcessInfo.processInfo.environment["ORBITAL_ACTIVE_ENV"]
        let claudeConfigDirPath = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/.claude")
        let claudeConfigDir = URL(fileURLWithPath: claudeConfigDirPath)
        EnvironmentStore.default.linkOrbitalMemory(
            projectKey: projectKey,
            envName: envName ?? ReservedEnvironment.defaultName,
            claudeConfigDir: claudeConfigDir
        )
    }
}
