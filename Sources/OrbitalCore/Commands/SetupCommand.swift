import ArgumentParser
import Foundation

public struct SetupCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Install orbital shell integration into ~/.zshrc"
    )
    public init() {}

    public func run() throws {
        let zshrc = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zshrc")
        try Self.installShellIntegration(to: zshrc)
        print("Shell integration installed. Restart your terminal or run: source ~/.zshrc")
    }

    public static func installShellIntegration(to url: URL) throws {
        let initLine = #"eval "$(orbital init)""#
        var existing = ""
        if FileManager.default.fileExists(atPath: url.path) {
            existing = try String(contentsOf: url, encoding: .utf8)
        }
        guard !existing.contains(initLine) else {
            print("Shell integration already present in \(url.path)")
            return
        }
        let appended = existing + "\n# orbital shell integration\n\(initLine)\n"
        try appended.write(to: url, atomically: true, encoding: .utf8)
        print("Added to \(url.path):")
        print("  \(initLine)")
    }
}
