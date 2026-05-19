import ArgumentParser
import Foundation

public struct UserMemoryCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "user",
        abstract: "Manage user-global Orrery memory (cross-project, cross-env).",
        subcommands: [
            InfoSubcommand.self,
            PathSubcommand.self,
            EmitSubcommand.self,
            ExportSubcommand.self,
            EnableSubcommand.self,
            DisableSubcommand.self,
        ]
    )

    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default
        let dir = store.userMemoryDir()
        let memoryFile = dir.appendingPathComponent("MEMORY.md")
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: memoryFile.path)
        let size = (try? fm.attributesOfItem(atPath: memoryFile.path)[.size] as? Int) ?? 0

        let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
        let enabled: Bool = {
            guard let envName else { return true }
            if envName == ReservedEnvironment.defaultName {
                return store.loadOriginConfig().shareUserMemory
            }
            return (try? store.load(named: envName))?.shareUserMemory ?? true
        }()

        print("Path: \(dir.path)")
        print("MEMORY.md exists: \(exists), size: \(size) bytes")
        print("Enabled in this env: \(enabled)")
        print("")

        let selector = SingleSelect(
            title: "User memory action:",
            options: ["Info", "Enable in this env", "Disable in this env", "Export"],
            selected: 0
        )
        switch selector.run() {
        case 0:
            var i = InfoSubcommand()
            try i.run()
        case 1:
            var e = EnableSubcommand()
            try e.run()
        case 2:
            var d = DisableSubcommand()
            try d.run()
        case 3:
            var x = ExportSubcommand()
            try x.run()
        default:
            break
        }
    }

    /// Pure helper used by tests and EmitSubcommand. Returns what would be printed
    /// to stdout by `orrery memory user emit`. Capped at 25_600 bytes.
    public static func emit(store: EnvironmentStore) throws -> String {
        let dir = store.userMemoryDir()
        let memStore = MemoryStore(directory: dir)
        return try memStore.emit(maxBytes: 25_600)
    }

    public struct InfoSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Show user memory location and status."
        )
        public init() {}
        public func run() throws {
            let store = EnvironmentStore.default
            let dir = store.userMemoryDir()
            let memoryFile = dir.appendingPathComponent("MEMORY.md")
            let fm = FileManager.default
            let exists = fm.fileExists(atPath: memoryFile.path)
            let size = (try? fm.attributesOfItem(atPath: memoryFile.path)[.size] as? Int) ?? 0
            print("Path: \(dir.path)")
            print("MEMORY.md exists: \(exists), size: \(size) bytes")
        }
    }

    public struct PathSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "path",
            abstract: "Print the user memory directory path."
        )
        public init() {}
        public func run() throws {
            print(EnvironmentStore.default.userMemoryDir().path)
        }
    }

    public struct EmitSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "emit",
            abstract: "Print MEMORY.md to stdout. Used by SessionStart hooks; not for humans."
        )
        public init() {}
        public func run() throws {
            // Best-effort: never fail a hook.
            let output = (try? UserMemoryCommand.emit(store: .default)) ?? ""
            if !output.isEmpty {
                print(output)
            }
        }
    }

    public struct ExportSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Export user MEMORY.md to a file."
        )
        @Option(name: .shortAndLong, help: ArgumentHelp("Output file path (default: USER_MEMORY.md)."))
        public var output: String?
        public init() {}
        public func run() throws {
            let store = EnvironmentStore.default
            let memoryFile = store.userMemoryDir().appendingPathComponent("MEMORY.md")
            guard FileManager.default.fileExists(atPath: memoryFile.path) else {
                print("No user memory to export.")
                return
            }
            let content = try String(contentsOf: memoryFile, encoding: .utf8)
            let outputPath = output ?? "USER_MEMORY.md"
            let outputURL = URL(fileURLWithPath: outputPath)
            try content.write(to: outputURL, atomically: true, encoding: .utf8)
            print("Exported to \(outputURL.path)")
        }
    }

    // Filled in by Task 15.
    public struct EnableSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "enable",
            abstract: "Enable user memory in the current env (installs hooks)."
        )
        public init() {}
        public func run() throws {
            throw ValidationError("not yet implemented")
        }
    }

    public struct DisableSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "disable",
            abstract: "Disable user memory in the current env (removes hooks)."
        )
        public init() {}
        public func run() throws {
            throw ValidationError("not yet implemented")
        }
    }
}
