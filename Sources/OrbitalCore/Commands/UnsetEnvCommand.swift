import ArgumentParser
import Foundation

public struct UnsetEnvCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "unset",
        abstract: "Remove configuration values from an environment",
        subcommands: [EnvSubcommand.self]
    )

    public struct EnvSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(commandName: "env")
        @Argument public var key: String
        @Option(name: .shortAndLong, help: "Environment name (defaults to ORBITAL_ACTIVE_ENV)") public var environment: String?
        public init() {}

        public func run() throws {
            guard let envName = environment ?? ProcessInfo.processInfo.environment["ORBITAL_ACTIVE_ENV"] else {
                throw ValidationError("No active environment. Run 'orbital use <name>' first, or use -e <name>.")
            }
            let store = EnvironmentStore.default
            try UnsetEnvCommand.unsetEnvVar(key: key, environmentName: envName, store: store)
            print("Unset \(key) from environment '\(envName)'")
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
