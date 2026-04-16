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
            print(L10n.Uninstall.confirmPrompt, terminator: "")
            fflush(stdout)
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
        let activatePath = SetupCommand.activateFile().path
        let sourceLine = "source \"\(activatePath)\""
        let integrationComment = "# orrery shell integration"

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser
        let rcFiles: [URL] = shellName == "bash"
            ? [home.appendingPathComponent(".bashrc")]
            : [home.appendingPathComponent(".zshrc")]

        for rcFile in rcFiles {
            guard FileManager.default.fileExists(atPath: rcFile.path),
                  var content = try? String(contentsOf: rcFile, encoding: .utf8)
            else { continue }

            let lines = content.components(separatedBy: "\n")
            let filtered = lines.filter { line in
                !line.trimmingCharacters(in: .whitespaces).hasPrefix(integrationComment) &&
                !line.contains(sourceLine) &&
                // catch older paths like ~/.orbital/activate.sh
                !line.contains("activate.sh")
            }
            let updated = filtered.joined(separator: "\n")
            if updated != content {
                content = updated
                try content.write(to: rcFile, atomically: true, encoding: .utf8)
                stderrWrite(L10n.Uninstall.removedIntegration(rcFile.path))
            }
        }

        print(L10n.Uninstall.done)
    }
}
