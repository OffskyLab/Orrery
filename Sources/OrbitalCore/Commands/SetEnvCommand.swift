import ArgumentParser
import Foundation

public struct SetEnvCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set configuration values in an environment",
        subcommands: [EnvSubcommand.self]
    )

    public struct EnvSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(commandName: "env")

        @Argument public var key: String
        @Argument public var value: String
        @Option(name: .shortAndLong, help: "Environment name (defaults to ORBITAL_ACTIVE_ENV)") public var environment: String?
        public init() {}

        public func run() throws {
            guard let envName = environment ?? ProcessInfo.processInfo.environment["ORBITAL_ACTIVE_ENV"] else {
                throw ValidationError("No active environment. Run 'orbital use <name>' first, or use -e <name>.")
            }
            let store = EnvironmentStore.default
            try SetEnvCommand.setEnvVar(key: key, value: value, environmentName: envName, store: store)
            print("Set \(key) in environment '\(envName)'")
        }
    }

    public init() {}

    public static func setEnvVar(key: String, value: String, environmentName: String, store: EnvironmentStore) throws {
        var env = try store.load(named: environmentName)
        env.env[key] = value
        try store.save(env)
    }
}
