import ArgumentParser
import Foundation

public struct SyncCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "[experimental] P2P real-time memory sync (delegates to orrery-sync)",
        discussion: """
        ⚠️  This feature is experimental and may change in future versions.

        Forwards all arguments to the orrery-sync binary.

        Examples:
          orrery sync daemon --port 9527
          orrery sync pair 192.168.1.10:9527
          orrery sync status
          orrery sync team create my-team   [experimental]
          orrery sync team invite           [experimental]
          orrery sync team join <code>      [experimental]
        """,
        subcommands: [],
        defaultSubcommand: nil
    )

    @Argument(parsing: .allUnrecognized)
    public var args: [String] = []

    public init() {}

    public func run() throws {
        let binary = Self.findBinary()

        guard let binary else {
            stderrWrite("orrery-sync not found. Install it with: brew install OffskyLab/orrery/orrery-sync\n")
            throw ExitCode.failure
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        throw ExitCode(process.terminationStatus)
    }

    /// Find the orrery-sync binary, checking in order:
    /// 1. ORRERY_SYNC_PATH environment variable
    /// 2. ~/.orrery/bin/orrery-sync
    /// 3. PATH (via /usr/bin/which)
    private static func findBinary() -> String? {
        // 1. Explicit env var
        if let path = ProcessInfo.processInfo.environment["ORRERY_SYNC_PATH"],
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        // 2. ~/.orrery/bin/
        let home: String
        if let custom = ProcessInfo.processInfo.environment["ORRERY_HOME"] {
            home = custom
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.path + "/.orrery"
        }
        let localPath = home + "/bin/orrery-sync"
        if FileManager.default.isExecutableFile(atPath: localPath) {
            return localPath
        }

        // 3. System PATH
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["orrery-sync"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        try? which.run()
        which.waitUntilExit()

        if which.terminationStatus == 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let path = output, !path.isEmpty {
                return path
            }
        }

        return nil
    }
}
