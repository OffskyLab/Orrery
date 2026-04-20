import ArgumentParser
import Foundation

public struct UninstallCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: L10n.Uninstall.abstract
    )

    @Flag(name: .long, help: "Skip confirmation prompt")
    public var force: Bool = false

    public init() {}

    public func run() throws {
        if !force {
            stdoutWrite(L10n.Uninstall.confirmPrompt)
            let line = readLine() ?? ""
            guard line.lowercased().hasPrefix("y") else {
                print(L10n.Uninstall.aborted)
                return
            }
        }

        let store = EnvironmentStore.default

        // 1. Release all managed origin tools
        for tool in Tool.allCases where store.isOriginManaged(tool: tool) {
            try store.originRelease(tool: tool)
            print(L10n.Origin.released(tool.rawValue, tool.defaultConfigDir.path))
        }

        // 2. Remove shell integration from rc files
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser
        let rcFiles: [URL] = shellName == "bash"
            ? [home.appendingPathComponent(".bashrc")]
            : [home.appendingPathComponent(".zshrc")]

        for rcFile in rcFiles {
            guard FileManager.default.fileExists(atPath: rcFile.path),
                  let content = try? String(contentsOf: rcFile, encoding: .utf8)
            else { continue }

            guard SetupCommand.containsOrreryBlock(content) else { continue }
            let updated = SetupCommand.stripOrreryBlocks(content)
            try updated.write(to: rcFile, atomically: true, encoding: .utf8)
            stderrWrite(L10n.Uninstall.removedIntegration(rcFile.path))
        }

        // 3. Remove the orrery-bin binary
        let binaryPath = CommandLine.arguments[0]
        let binaryURL = URL(fileURLWithPath: binaryPath)
        if FileManager.default.fileExists(atPath: binaryURL.path) {
            try FileManager.default.removeItem(at: binaryURL)
            stderrWrite(L10n.Uninstall.removedBinary(binaryURL.path))
        }

        print(L10n.Uninstall.done)
    }
}
