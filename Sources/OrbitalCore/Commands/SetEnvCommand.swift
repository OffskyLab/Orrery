import ArgumentParser
import Foundation

public struct SetEnvCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: L10n.EnvVar.setAbstract,
        subcommands: [EnvSubcommand.self]
    )

    public struct EnvSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(commandName: "env")

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
            try SetEnvCommand.setEnvVar(key: key, value: value, environmentName: envName, store: store)
            print(L10n.EnvVar.set(key, envName))
        }
    }

    public init() {}

    public static func setEnvVar(key: String, value: String, environmentName: String, store: EnvironmentStore) throws {
        var env = try store.load(named: environmentName)
        env.env[key] = value
        try store.save(env)
    }
}
