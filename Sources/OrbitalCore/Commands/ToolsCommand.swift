import ArgumentParser
import Foundation

public struct ToolsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tools",
        abstract: L10n.Tools.abstract,
        subcommands: [Add.self, Remove.self],
        defaultSubcommand: Add.self
    )
    public init() {}

    // MARK: - tools add

    public struct Add: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: L10n.Tools.addAbstract
        )

        @Option(name: .shortAndLong, help: ArgumentHelp(L10n.Tools.envHelp))
        public var environment: String?

        public init() {}

        public func run() throws {
            let store = EnvironmentStore.default
            let envName = try resolveEnv(environment: environment)
            _ = try store.load(named: envName)

            let env = try store.load(named: envName)
            let available = Tool.allCases.filter { !env.tools.contains($0) }
            guard !available.isEmpty else {
                print(L10n.Tools.noToolsToAdd(envName))
                return
            }

            let selector = SingleSelect(
                title: L10n.Tools.addWizardTitle(envName),
                options: available.map(\.rawValue),
                selected: 0
            )
            let tool = available[selector.run()]

            let config = ToolSetupRunner.runWizard(for: tool, store: store)
            try ToolSetupRunner.apply(config, to: envName, store: store)
            print(L10n.Tools.added(tool.rawValue))

            // Offer interactive login only if user skipped the copy step.
            if config.loginSource == nil {
                ToolSetup.execLoginIfNeeded(tools: [tool], store: store, envName: envName)
            }
        }
    }

    // MARK: - tools remove

    public struct Remove: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: L10n.Tools.removeAbstract
        )

        @Option(name: .shortAndLong, help: ArgumentHelp(L10n.Tools.envHelp))
        public var environment: String?

        public init() {}

        public func run() throws {
            let store = EnvironmentStore.default
            let envName = try resolveEnv(environment: environment)
            let env = try store.load(named: envName)

            guard !env.tools.isEmpty else {
                print(L10n.Tools.noToolsToRemove(envName))
                return
            }

            let selector = SingleSelect(
                title: L10n.Tools.removeWizardTitle(envName),
                options: env.tools.map(\.rawValue),
                selected: 0
            )
            let tool = env.tools[selector.run()]
            try store.removeTool(tool, from: envName)
            print(L10n.Tools.removed(tool.rawValue))
        }
    }
}

/// Resolve the env name from `--environment` or `ORBITAL_ACTIVE_ENV`. Shared by both subcommands.
private func resolveEnv(environment: String?) throws -> String {
    guard let envName = environment ?? ProcessInfo.processInfo.environment["ORBITAL_ACTIVE_ENV"] else {
        throw ValidationError(L10n.Tools.noActive)
    }
    guard envName != ReservedEnvironment.defaultName else {
        throw ValidationError(L10n.Tools.defaultNotSupported)
    }
    return envName
}
