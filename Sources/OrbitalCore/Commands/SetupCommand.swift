import ArgumentParser
import Foundation

public struct SetupCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Install orbital shell integration (use: eval \"$(orbital setup)\")"
    )

    @Option(name: .long, help: "Shell type to configure (bash, zsh). Auto-detected if omitted.")
    public var shell: String?

    public init() {}

    public func run() throws {
        let resolved = try Self.resolveShell(explicit: shell)
        let rcFile = Self.rcFile(for: resolved)
        Self.installShellIntegration(to: rcFile)

        // stdout: shell function for immediate eval in current shell
        print(ShellFunctionGenerator.generate())
    }

    static func resolveShell(explicit: String?) throws -> String {
        if let explicit {
            let lower = explicit.lowercased()
            guard lower == "bash" || lower == "zsh" else {
                throw ValidationError("Unsupported shell '\(explicit)'. Supported: bash, zsh")
            }
            return lower
        }
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let name = URL(fileURLWithPath: shellPath).lastPathComponent
        switch name {
        case "bash": return "bash"
        case "zsh":  return "zsh"
        default:     return "zsh"
        }
    }

    static func rcFile(for shell: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch shell {
        case "bash": return home.appendingPathComponent(".bashrc")
        default:     return home.appendingPathComponent(".zshrc")
        }
    }

    static func installShellIntegration(to url: URL) {
        let initLine = #"eval "$(orbital setup)""#
        var existing = ""
        if FileManager.default.fileExists(atPath: url.path) {
            existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        guard !existing.contains(initLine) else {
            FileHandle.standardError.write(Data("orbital: shell integration already present in \(url.path)\n".utf8))
            return
        }
        let appended = existing + "\n# orbital shell integration\n\(initLine)\n"
        do {
            try appended.write(to: url, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("orbital: added to \(url.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("orbital: failed to write \(url.path): \(error.localizedDescription)\n".utf8))
        }
    }
}
