import ArgumentParser
import Foundation

public struct EnvCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "env",
        abstract: L10n.EnvVar.abstract,
        subcommands: [SetSubcommand.self, UnsetSubcommand.self]
    )

    public init() {}

    // MARK: - Set

    public struct SetSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: L10n.EnvVar.setAbstract
        )

        @Argument public var key: String
        @Argument public var value: String
        @Option(name: .shortAndLong, help: ArgumentHelp(L10n.EnvVar.envHelp)) public var environment: String?

        public init() {}

        public func run() throws {
            guard let envName = environment ?? ProcessInfo.processInfo.environment["ORBITAL_ACTIVE_ENV"] else {
                throw ValidationError(L10n.EnvVar.noActive)
            }
            guard envName != ReservedEnvironment.defaultName else {
                throw ValidationError(L10n.EnvVar.defaultNotSupported)
            }
            let store = EnvironmentStore.default
            var env = try store.load(named: envName)
            env.env[key] = value
            try store.save(env)
            print(L10n.EnvVar.set(key, envName))
        }
    }

    // MARK: - Unset

    public struct UnsetSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "unset",
            abstract: L10n.EnvVar.unsetAbstract
        )

        @Argument public var key: String
        @Option(name: .shortAndLong, help: ArgumentHelp(L10n.EnvVar.envHelp)) public var environment: String?

        public init() {}

        public func run() throws {
            guard let envName = environment ?? ProcessInfo.processInfo.environment["ORBITAL_ACTIVE_ENV"] else {
                throw ValidationError(L10n.EnvVar.noActive)
            }
            guard envName != ReservedEnvironment.defaultName else {
                throw ValidationError(L10n.EnvVar.defaultNotSupported)
            }
            let store = EnvironmentStore.default
            var env = try store.load(named: envName)
            env.env.removeValue(forKey: key)
            try store.save(env)
            print(L10n.EnvVar.unset(key, envName))
        }
    }
}
