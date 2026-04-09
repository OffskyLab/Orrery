import ArgumentParser
import Foundation

public struct MemoryCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "memory",
        abstract: L10n.Memory.abstract,
        subcommands: [ExportSubcommand.self],
        defaultSubcommand: ExportSubcommand.self
    )

    public init() {}

    public struct ExportSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: L10n.Memory.exportAbstract
        )

        @Option(name: .shortAndLong, help: ArgumentHelp(L10n.Memory.outputHelp))
        public var output: String?

        public init() {}

        public func run() throws {
            let fm = FileManager.default
            let projectKey = fm.currentDirectoryPath
                .replacingOccurrences(of: "/", with: "-")

            let home: URL
            if let custom = ProcessInfo.processInfo.environment["ORBITAL_HOME"] {
                home = URL(fileURLWithPath: custom)
            } else {
                home = fm.homeDirectoryForCurrentUser.appendingPathComponent(".orbital")
            }

            let memoryFile = home
                .appendingPathComponent("shared")
                .appendingPathComponent("memory")
                .appendingPathComponent(projectKey)
                .appendingPathComponent("ORBITAL_MEMORY.md")

            guard fm.fileExists(atPath: memoryFile.path) else {
                print(L10n.Memory.noMemory)
                return
            }

            let content = try String(contentsOf: memoryFile, encoding: .utf8)

            let outputPath = output ?? "ORBITAL_MEMORY.md"
            let outputURL = URL(fileURLWithPath: outputPath)
            try content.write(to: outputURL, atomically: true, encoding: .utf8)
            print(L10n.Memory.exported(outputURL.path))
        }
    }
}
