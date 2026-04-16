import ArgumentParser
import Foundation

public struct MemoryCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "memory",
        abstract: L10n.Memory.abstract,
        subcommands: [InfoSubcommand.self, ExportSubcommand.self, IsolateSubcommand.self, ShareSubcommand.self, StorageSubcommand.self]
    )

    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default
        let projectKey = FileManager.default.currentDirectoryPath
            .replacingOccurrences(of: "/", with: "-")
        let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
        let memoryDir = store.memoryDir(projectKey: projectKey, envName: envName)

        let isIsolated: Bool
        let storagePath: String?
        if let envName, envName == ReservedEnvironment.defaultName {
            let config = store.loadOriginConfig()
            isIsolated = config.isolateMemory
            storagePath = config.memoryStoragePath
        } else if let envName, let env = try? store.load(named: envName) {
            isIsolated = env.isolateMemory
            storagePath = env.memoryStoragePath
        } else {
            isIsolated = false
            storagePath = nil
        }

        // Show current status
        print(L10n.Memory.statusMode(isIsolated))
        print(L10n.Memory.statusPath(memoryDir.path))
        print(L10n.Memory.storageStatus(storagePath))
        print("")

        // Build action menu based on current state
        var options: [String] = [L10n.Memory.actionInfo, L10n.Memory.actionExport]
        var canToggle = false
        var canStorage = false
        if envName != nil {
            options.append(isIsolated ? L10n.Memory.actionShare : L10n.Memory.actionIsolate)
            options.append(L10n.Memory.actionStorage)
            canToggle = true
            canStorage = true
        }

        let selector = SingleSelect(title: L10n.Memory.settingsPrompt, options: options, selected: 0)
        let choice = selector.run()

        switch choice {
        case 0:
            var info = InfoSubcommand()
            try info.run()
        case 1:
            var export = ExportSubcommand()
            try export.run()
        case 2 where canToggle:
            if isIsolated {
                var share = ShareSubcommand()
                try share.run()
            } else {
                var isolate = IsolateSubcommand()
                try isolate.run()
            }
        case 3 where canStorage:
            var storage = StorageSubcommand()
            try storage.run()
        default:
            break
        }
    }

    // MARK: - Info

    public struct InfoSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: L10n.Memory.infoAbstract
        )

        @Option(name: .shortAndLong, help: "Environment name (defaults to ORRERY_ACTIVE_ENV)")
        public var environment: String?

        public init() {}

        public func run() throws {
            let store = EnvironmentStore.default
            let projectKey = FileManager.default.currentDirectoryPath
                .replacingOccurrences(of: "/", with: "-")
            let envName = environment ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
            let memoryDir = store.memoryDir(projectKey: projectKey, envName: envName)
            let memoryFile = memoryDir.appendingPathComponent("MEMORY.md")

            let isIsolated: Bool
            if let envName, envName != ReservedEnvironment.defaultName,
               let env = try? store.load(named: envName) {
                isIsolated = env.isolateMemory
            } else {
                isIsolated = false
            }

            let fm = FileManager.default
            let exists = fm.fileExists(atPath: memoryFile.path)
            let size = (try? fm.attributesOfItem(atPath: memoryFile.path)[.size] as? Int) ?? 0

            print(L10n.Memory.statusMode(isIsolated))
            print(L10n.Memory.statusPath(memoryDir.path))
            print(L10n.Memory.statusExists(exists, size))
        }
    }

    // MARK: - Export

    public struct ExportSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: L10n.Memory.exportAbstract
        )

        @Option(name: .shortAndLong, help: ArgumentHelp(L10n.Memory.outputHelp))
        public var output: String?

        public init() {}

        public func run() throws {
            let store = EnvironmentStore.default
            let projectKey = FileManager.default.currentDirectoryPath
                .replacingOccurrences(of: "/", with: "-")
            let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
            let memoryFile = store.memoryDir(projectKey: projectKey, envName: envName)
                .appendingPathComponent("MEMORY.md")

            guard FileManager.default.fileExists(atPath: memoryFile.path) else {
                print(L10n.Memory.noMemory)
                return
            }

            let content = try String(contentsOf: memoryFile, encoding: .utf8)
            let outputPath = output ?? "MEMORY.md"
            let outputURL = URL(fileURLWithPath: outputPath)
            try content.write(to: outputURL, atomically: true, encoding: .utf8)
            print(L10n.Memory.exported(outputURL.path))
        }
    }

    // MARK: - Isolate

    public struct IsolateSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "isolate",
            abstract: L10n.Memory.isolateAbstract
        )

        @Option(name: .shortAndLong, help: "Environment name (defaults to ORRERY_ACTIVE_ENV)")
        public var environment: String?

        public init() {}

        public func run() throws {
            let envName = environment
                ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
            guard let envName else {
                throw ValidationError(L10n.Memory.noActiveEnv)
            }

            let store = EnvironmentStore.default
            let projectKey = FileManager.default.currentDirectoryPath
                .replacingOccurrences(of: "/", with: "-")

            if envName == ReservedEnvironment.defaultName {
                var config = store.loadOriginConfig()
                guard !config.isolateMemory else {
                    print(L10n.Memory.alreadyIsolated)
                    return
                }
                let sharedDir = store.sharedMemoryDir(projectKey: projectKey)
                let isolatedDir = store.isolatedMemoryDir(projectKey: projectKey, envName: envName)
                print(L10n.Memory.migrationWarning(sharedDir.path, isolatedDir.path))
                print("")
                let choice = askMigrationChoiceToIsolated()
                if choice == 1 {
                    stdoutWrite(L10n.Memory.discardConfirm)
                    let confirm = readLine()?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
                    guard confirm == "y" || confirm == "yes" else {
                        print(L10n.Memory.aborted)
                        return
                    }
                }
                try applyMigration(merge: choice == 0, fromDir: sharedDir, toDir: isolatedDir)
                config.isolateMemory = true
                try store.saveOriginConfig(config)
                print(L10n.Memory.migrationDone(envName, true))
                return
            }

            var env = try store.load(named: envName)

            guard !env.isolateMemory else {
                print(L10n.Memory.alreadyIsolated)
                return
            }

            let sharedDir = store.memoryDir(projectKey: projectKey, envName: nil)
            let isolatedDir = store.isolatedMemoryDir(projectKey: projectKey, envName: envName)

            print(L10n.Memory.migrationWarning(sharedDir.path, isolatedDir.path))
            print("")

            let choice = askMigrationChoiceToIsolated()
            if choice == 1 {
                stdoutWrite(L10n.Memory.discardConfirm)
                let confirm = readLine()?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
                guard confirm == "y" || confirm == "yes" else {
                    print(L10n.Memory.aborted)
                    return
                }
            }

            try applyMigration(merge: choice == 0, fromDir: sharedDir, toDir: isolatedDir)

            env.isolateMemory = true
            try store.save(env)
            print(L10n.Memory.migrationDone(envName, true))
        }
    }

    // MARK: - Share

    public struct ShareSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "share",
            abstract: L10n.Memory.shareAbstract
        )

        @Option(name: .shortAndLong, help: "Environment name (defaults to ORRERY_ACTIVE_ENV)")
        public var environment: String?

        public init() {}

        public func run() throws {
            let envName = environment
                ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
            guard let envName else {
                throw ValidationError(L10n.Memory.noActiveEnv)
            }

            let store = EnvironmentStore.default
            let projectKey = FileManager.default.currentDirectoryPath
                .replacingOccurrences(of: "/", with: "-")

            if envName == ReservedEnvironment.defaultName {
                var config = store.loadOriginConfig()
                guard config.isolateMemory else {
                    print(L10n.Memory.alreadyShared)
                    return
                }
                let isolatedDir = store.isolatedMemoryDir(projectKey: projectKey, envName: envName)
                let sharedDir = store.sharedMemoryDir(projectKey: projectKey)
                print(L10n.Memory.migrationWarning(isolatedDir.path, sharedDir.path))
                print("")
                let choice = askMigrationChoiceToShared()
                if choice == 1 {
                    stdoutWrite(L10n.Memory.discardConfirm)
                    let confirm = readLine()?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
                    guard confirm == "y" || confirm == "yes" else {
                        print(L10n.Memory.aborted)
                        return
                    }
                }
                try applyMigration(merge: choice == 0, fromDir: isolatedDir, toDir: sharedDir)
                config.isolateMemory = false
                try store.saveOriginConfig(config)
                print(L10n.Memory.migrationDone(envName, false))
                return
            }

            var env = try store.load(named: envName)

            guard env.isolateMemory else {
                print(L10n.Memory.alreadyShared)
                return
            }

            let isolatedDir = store.memoryDir(projectKey: projectKey, envName: envName)
            let sharedDir = store.sharedMemoryDir(projectKey: projectKey)

            print(L10n.Memory.migrationWarning(isolatedDir.path, sharedDir.path))
            print("")

            let choice = askMigrationChoiceToShared()
            if choice == 1 {
                stdoutWrite(L10n.Memory.discardConfirm)
                let confirm = readLine()?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
                guard confirm == "y" || confirm == "yes" else {
                    print(L10n.Memory.aborted)
                    return
                }
            }

            try applyMigration(merge: choice == 0, fromDir: isolatedDir, toDir: sharedDir)

            env.isolateMemory = false
            try store.save(env)
            print(L10n.Memory.migrationDone(envName, false))
        }
    }

    // MARK: - Storage

    public struct StorageSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "storage",
            abstract: L10n.Memory.storageAbstract
        )

        @Argument(help: ArgumentHelp(L10n.Memory.storagePathHelp))
        public var path: String?

        @Flag(name: .long, help: ArgumentHelp(L10n.Memory.storageResetHelp))
        public var reset: Bool = false

        @Option(name: .shortAndLong, help: "Environment name (defaults to ORRERY_ACTIVE_ENV)")
        public var environment: String?

        public init() {}

        public func run() throws {
            let envName = environment
                ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
            guard let envName else {
                throw ValidationError(L10n.Memory.noActiveEnv)
            }

            let store = EnvironmentStore.default

            if envName == ReservedEnvironment.defaultName {
                var config = store.loadOriginConfig()
                if reset {
                    config.memoryStoragePath = nil
                    try store.saveOriginConfig(config)
                    print(L10n.Memory.storageReset)
                    return
                }
                guard let path else {
                    print(L10n.Memory.storageStatus(config.memoryStoragePath))
                    return
                }
                try applyStoragePath(path, currentEnvName: envName, store: store,
                    getPath: { config.memoryStoragePath },
                    setPath: { config.memoryStoragePath = $0; try store.saveOriginConfig(config) })
                return
            }

            var env = try store.load(named: envName)

            if reset {
                env.memoryStoragePath = nil
                try store.save(env)
                print(L10n.Memory.storageReset)
                return
            }

            guard let path else {
                print(L10n.Memory.storageStatus(env.memoryStoragePath))
                return
            }

            try applyStoragePath(path, currentEnvName: envName, store: store,
                getPath: { env.memoryStoragePath },
                setPath: { env.memoryStoragePath = $0; try store.save(env) })
        }
    }
}

private func applyStoragePath(
    _ path: String,
    currentEnvName: String,
    store: EnvironmentStore,
    getPath: () -> String?,
    setPath: (String) throws -> Void
) throws {
    let expanded = (path as NSString).expandingTildeInPath
    let fm = FileManager.default
    var isDir: ObjCBool = false
    let exists = fm.fileExists(atPath: expanded, isDirectory: &isDir)
    if exists && !isDir.boolValue {
        throw ValidationError(L10n.Memory.storageNotDirectory(expanded))
    }
    if !exists {
        try fm.createDirectory(atPath: expanded, withIntermediateDirectories: true, attributes: nil)
    }

    let newMemoryFile = URL(fileURLWithPath: expanded).appendingPathComponent("MEMORY.md")
    let newIsEmpty = !fm.fileExists(atPath: newMemoryFile.path)

    if newIsEmpty {
        let projectKey = FileManager.default.currentDirectoryPath
            .replacingOccurrences(of: "/", with: "-")
        let currentMemoryFile = store.memoryDir(projectKey: projectKey, envName: currentEnvName)
            .appendingPathComponent("MEMORY.md")
        if fm.fileExists(atPath: currentMemoryFile.path) {
            let selector = SingleSelect(
                title: L10n.Memory.storageCopyPrompt,
                options: [L10n.Memory.storageCopyYes, L10n.Memory.storageCopyNo],
                selected: 0
            )
            if selector.run() == 0 {
                try fm.copyItem(at: currentMemoryFile, to: newMemoryFile)
                print(L10n.Memory.storageCopied)
            }
        }
    }

    try setPath(expanded)
    print(L10n.Memory.storageSet(expanded))
}

// MARK: - Migration helpers

private func askMigrationChoiceToShared() -> Int {
    let selector = SingleSelect(
        title: L10n.Memory.migrationPrompt,
        options: [
            L10n.Memory.migrationMergeToShared,
            L10n.Memory.migrationDiscardToShared,
        ],
        selected: 0
    )
    return selector.run()
}

private func askMigrationChoiceToIsolated() -> Int {
    let selector = SingleSelect(
        title: L10n.Memory.migrationPrompt,
        options: [
            L10n.Memory.migrationMergeToIsolated,
            L10n.Memory.migrationDiscardToIsolated,
        ],
        selected: 0
    )
    return selector.run()
}

private func applyMigration(merge: Bool, fromDir sourceDir: URL, toDir destDir: URL) throws {
    guard merge else { return }

    let fm = FileManager.default
    let sourceFile = sourceDir.appendingPathComponent("MEMORY.md")
    guard fm.fileExists(atPath: sourceFile.path),
          let content = try? String(contentsOf: sourceFile, encoding: .utf8) else {
        return
    }

    let fragmentsDir = destDir.appendingPathComponent("fragments")
    try fm.createDirectory(at: fragmentsDir, withIntermediateDirectories: true)

    let timestamp = ISO8601DateFormatter().string(from: Date())
    let peer = ProcessInfo.processInfo.hostName
        .replacingOccurrences(of: ".local", with: "")
    let id = String(UUID().uuidString.prefix(8).lowercased())
    let filename = "f-\(id)-\(peer).md"

    let fragment = """
    ---
    id: f-\(id)
    peer: \(peer)
    timestamp: \(timestamp)
    action: migrate
    ---

    \(content)
    """
    try fragment.write(
        to: fragmentsDir.appendingPathComponent(filename),
        atomically: true, encoding: .utf8
    )
}
