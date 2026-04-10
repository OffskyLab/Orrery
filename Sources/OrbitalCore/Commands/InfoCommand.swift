import ArgumentParser
import Foundation

public struct InfoCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: L10n.Info.abstract
    )

    @Argument(help: ArgumentHelp(L10n.Info.nameHelp))
    public var name: String?

    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default
        let resolvedName: String
        if let name {
            resolvedName = name
        } else if let active = ProcessInfo.processInfo.environment["ORBITAL_ACTIVE_ENV"] {
            resolvedName = active
        } else {
            throw ValidationError(L10n.Info.noActive)
        }
        guard resolvedName != ReservedEnvironment.defaultName else {
            print(L10n.Info.defaultInfo)
            return
        }
        let env = try store.load(named: resolvedName)
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium

        let path = try store.envDir(for: resolvedName).path
        let none = L10n.Info.none

        let projectKey = FileManager.default.currentDirectoryPath
            .replacingOccurrences(of: "/", with: "-")
        let memoryFile = store.memoryFile(projectKey: projectKey, envName: resolvedName)

        print("\(L10n.Info.labelName)\(env.name)")
        print("\(L10n.Info.labelID)\(env.id)")
        print("\(L10n.Info.labelPath)\(path)")
        print("\(L10n.Info.labelDescription)\(env.description.isEmpty ? none : env.description)")
        print("\(L10n.Info.labelCreated)\(df.string(from: env.createdAt))")
        print("\(L10n.Info.labelLastUsed)\(df.string(from: env.lastUsed))")
        print("\(L10n.Info.labelTools)\(env.tools.isEmpty ? none : env.tools.map(\.rawValue).joined(separator: ", "))")
        let memoryMode = env.isolateMemory ? L10n.Info.modeIsolated : L10n.Info.modeShared
        print("\(L10n.Info.labelMemoryMode)\(memoryMode)")
        print("\(L10n.Info.labelMemoryPath)\(memoryFile.path)")
        let sessionMode = env.isolateSessions ? L10n.Info.modeIsolated : L10n.Info.modeShared
        print("\(L10n.Info.labelSessionMode)\(sessionMode)")
        if env.env.isEmpty {
            print("\(L10n.Info.labelEnvVars)\(none)")
        } else {
            print("\(L10n.Info.labelEnvVars)")
            for (key, value) in env.env.sorted(by: { $0.key < $1.key }) {
                let masked = value.count > 8 ? String(value.prefix(4)) + "****" : "****"
                print("  \(key)=\(masked)")
            }
        }
    }
}
