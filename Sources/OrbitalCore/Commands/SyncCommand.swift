import ArgumentParser
import Foundation

public struct SyncCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "P2P real-time sync (delegates to orbital-sync)",
        discussion: """
        Forwards all arguments to the orbital-sync binary.

        Examples:
          orbital sync daemon --port 9527
          orbital sync pair 192.168.1.10:9527
          orbital sync status
          orbital sync team create my-team
          orbital sync team invite
          orbital sync team join <code>
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
            FileHandle.standardError.write(Data(
                "orbital-sync not found. Install it with: brew install OffskyLab/orbital/orbital-sync\n".utf8
            ))
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

    /// Find the orbital-sync binary, checking in order:
    /// 1. ORBITAL_SYNC_PATH environment variable
    /// 2. ~/.orbital/bin/orbital-sync
    /// 3. PATH (via /usr/bin/which)
    private static func findBinary() -> String? {
        // 1. Explicit env var
        if let path = ProcessInfo.processInfo.environment["ORBITAL_SYNC_PATH"],
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        // 2. ~/.orbital/bin/
        let home: String
        if let custom = ProcessInfo.processInfo.environment["ORBITAL_HOME"] {
            home = custom
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.path + "/.orbital"
        }
        let localPath = home + "/bin/orbital-sync"
        if FileManager.default.isExecutableFile(atPath: localPath) {
            return localPath
        }

        // 3. System PATH
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["orbital-sync"]
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
