import ArgumentParser
import Foundation

public struct SandboxCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sandbox",
        abstract: L10n.Sandbox.abstract,
        subcommands: [SetEnv.self, UnsetEnv.self]
    )

    public init() {}

    // MARK: - SetEnv

    public struct SetEnv: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "set-env",
            abstract: L10n.Sandbox.setEnvAbstract
        )

        @Argument(help: ArgumentHelp(L10n.Sandbox.setEnvKeyHelp)) public var key: String
        @Argument(help: ArgumentHelp(L10n.Sandbox.setEnvValueHelp)) public var value: String
        @Option(name: [.customShort("s"), .customLong("sandbox")],
                help: ArgumentHelp(L10n.Sandbox.setEnvSandboxHelp)) public var sandbox: String?

        public init() {}

        public func run() throws {
            guard let envName = sandbox ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"] else {
                throw ValidationError(L10n.Sandbox.setEnvNoActive)
            }
            guard envName != ReservedEnvironment.defaultName else {
                throw ValidationError(L10n.Sandbox.setEnvOriginNotSupported)
            }
            let store = EnvironmentStore.default
            var env = try store.load(named: envName)
            env.env[key] = value
            try store.save(env)
            print(L10n.Sandbox.setEnvSuccess(key, envName))
        }
    }

    // MARK: - UnsetEnv

    public struct UnsetEnv: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "unset-env",
            abstract: L10n.Sandbox.unsetEnvAbstract
        )

        @Argument(help: ArgumentHelp(L10n.Sandbox.unsetEnvKeyHelp)) public var key: String
        @Option(name: [.customShort("s"), .customLong("sandbox")],
                help: ArgumentHelp(L10n.Sandbox.setEnvSandboxHelp)) public var sandbox: String?

        public init() {}

        public func run() throws {
            guard let envName = sandbox ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"] else {
                throw ValidationError(L10n.Sandbox.setEnvNoActive)
            }
            guard envName != ReservedEnvironment.defaultName else {
                throw ValidationError(L10n.Sandbox.setEnvOriginNotSupported)
            }
            let store = EnvironmentStore.default
            var env = try store.load(named: envName)
            env.env.removeValue(forKey: key)
            try store.save(env)
            print(L10n.Sandbox.unsetEnvSuccess(key, envName))
        }
    }
}
