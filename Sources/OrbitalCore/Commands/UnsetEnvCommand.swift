import ArgumentParser
import Foundation

public struct UnsetEnvCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "unset",
        abstract: L10n.EnvVar.unsetAbstract,
        subcommands: [EnvSubcommand.self]
    )

    public struct EnvSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(commandName: "env")
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
            try UnsetEnvCommand.unsetEnvVar(key: key, environmentName: envName, store: store)
            print(L10n.EnvVar.unset(key, envName))
        }
    }

    public init() {}
    public func run() throws {}

    public static func unsetEnvVar(key: String, environmentName: String, store: EnvironmentStore) throws {
        var env = try store.load(named: environmentName)
        env.env.removeValue(forKey: key)
        try store.save(env)
    }
}
