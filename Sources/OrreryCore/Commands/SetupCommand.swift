import ArgumentParser
import Foundation

public struct SetupCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: L10n.Setup.abstract
    )

    @Option(name: .long, help: ArgumentHelp(L10n.Setup.shellHelp))
    public var shell: String?

    public init() {}

    public func run() throws {
        let resolved = try Self.resolveShell(explicit: shell)
        let rcFile = Self.rcFile(for: resolved)
        let activateFile = Self.activateFile()

        // 1. Generate activate.sh
        Self.writeActivateScript(to: activateFile)

        // 2. Add source line to rc file
        Self.installShellIntegration(to: rcFile, activatePath: activateFile.path)

        // 3. Offer origin takeover (interactive, skipped when /dev/tty unavailable)
        Self.offerOriginTakeover()
    }

    static func resolveShell(explicit: String?) throws -> String {
        if let explicit {
            let lower = explicit.lowercased()
            guard lower == "bash" || lower == "zsh" else {
                throw ValidationError(L10n.Setup.unsupportedShell(explicit))
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

    static func activateFile() -> URL {
        let home: URL
        if let custom = ProcessInfo.processInfo.environment["ORRERY_HOME"] {
            home = URL(fileURLWithPath: custom)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".orrery")
        }
        return home.appendingPathComponent("activate.sh")
    }

    static func writeActivateScript(to url: URL) {
        let content = ShellFunctionGenerator.generate()
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data(L10n.Setup.wroteActivate(url.path).utf8))
        } catch {
            FileHandle.standardError.write(Data(L10n.Setup.failedToWrite(url.path, error.localizedDescription).utf8))
        }
    }

    static func offerOriginTakeover() {
        let store = EnvironmentStore.default
        for tool in Tool.allCases {
            guard !store.isOriginManaged(tool: tool),
                  FileManager.default.fileExists(atPath: tool.defaultConfigDir.path)
            else { continue }
            if (try? store.originTakeover(tool: tool)) != nil {
                FileHandle.standardError.write(
                    Data(L10n.Origin.tookOver(tool.rawValue, store.originConfigDir(tool: tool).path).utf8 + [0x0A])
                )
            }
        }
    }

    static func installShellIntegration(to url: URL, activatePath: String) {
        let sourceLine = "source \"\(activatePath)\""
        let oldEvalLine = #"eval "$(orrery setup)""#
        var existing = ""
        if FileManager.default.fileExists(atPath: url.path) {
            existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        // Already has the source line
        if existing.contains(sourceLine) {
            FileHandle.standardError.write(Data(L10n.Setup.alreadyPresent(url.path).utf8))
            return
        }

        // Migrate old eval line to source line
        if existing.contains(oldEvalLine) {
            let migrated = existing.replacingOccurrences(of: oldEvalLine, with: sourceLine)
            do {
                try migrated.write(to: url, atomically: true, encoding: .utf8)
                FileHandle.standardError.write(Data(L10n.Setup.migratedRc(url.path).utf8))
            } catch {
                FileHandle.standardError.write(Data(L10n.Setup.failedToWrite(url.path, error.localizedDescription).utf8))
            }
            return
        }

        // Fresh install
        let appended = existing + "\n# orrery shell integration\n\(sourceLine)\n"
        do {
            try appended.write(to: url, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data(L10n.Setup.addedTo(url.path).utf8))
        } catch {
            FileHandle.standardError.write(Data(L10n.Setup.failedToWrite(url.path, error.localizedDescription).utf8))
        }
    }
}
