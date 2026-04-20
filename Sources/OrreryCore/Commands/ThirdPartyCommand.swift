import ArgumentParser
import Foundation

public struct ThirdPartyCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "thirdparty",
        abstract: L10n.Thirdparty.abstract,
        subcommands: [Install.self, Uninstall.self, List.self, Available.self]
    )
    public init() {}

    public struct Install: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: L10n.Thirdparty.installAbstract
        )

        @Argument(help: ArgumentHelp(L10n.Thirdparty.installIdHelp))
        public var id: String

        @Option(name: .long, help: ArgumentHelp(L10n.Thirdparty.installEnvHelp))
        public var env: String?

        @Option(name: .long, help: ArgumentHelp(L10n.Thirdparty.installRefHelp))
        public var ref: String?

        @Flag(name: .long, help: ArgumentHelp(L10n.Thirdparty.installForceRefreshHelp))
        public var forceRefresh: Bool = false

        public init() {}

        public func run() throws {
            let resolvedEnv = try env ?? currentEnvOrThrow()
            let registry = try ThirdPartyRuntime.registry()
            let runner = try ThirdPartyRuntime.runner()
            let pkg = try registry.lookup(id)
            let record = try runner.install(pkg, into: resolvedEnv,
                                            refOverride: ref, forceRefresh: forceRefresh)
            print(L10n.Thirdparty.installSuccess(
                record.packageID,
                String(record.resolvedRef.prefix(7)),
                record.copiedFiles.count,
                resolvedEnv
            ))
        }
    }

    public struct Uninstall: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "uninstall",
            abstract: L10n.Thirdparty.uninstallAbstract
        )

        @Argument(help: ArgumentHelp(L10n.Thirdparty.installIdHelp))
        public var id: String

        @Option(name: .long, help: ArgumentHelp(L10n.Thirdparty.installEnvHelp))
        public var env: String?

        public init() {}

        public func run() throws {
            let resolvedEnv = try env ?? currentEnvOrThrow()
            let runner = try ThirdPartyRuntime.runner()
            try runner.uninstall(packageID: id, from: resolvedEnv)
            print(L10n.Thirdparty.uninstallSuccess(id, resolvedEnv))
        }
    }

    public struct List: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: L10n.Thirdparty.listAbstract
        )

        @Option(name: .long, help: ArgumentHelp(L10n.Thirdparty.installEnvHelp))
        public var env: String?

        public init() {}

        public func run() throws {
            let resolvedEnv = try env ?? currentEnvOrThrow()
            let runner = try ThirdPartyRuntime.runner()
            let records = try runner.listInstalled(in: resolvedEnv)
            if records.isEmpty {
                print(L10n.Thirdparty.listNone(resolvedEnv))
                return
            }
            let fmt = ISO8601DateFormatter()
            for r in records {
                print(L10n.Thirdparty.listItem(
                    r.packageID, String(r.resolvedRef.prefix(7)),
                    fmt.string(from: r.installedAt)))
            }
        }
    }

    public struct Available: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "available",
            abstract: L10n.Thirdparty.availableAbstract
        )
        public init() {}
        public func run() throws {
            let registry = try ThirdPartyRuntime.registry()
            for id in registry.listAvailable() { print(id) }
        }
    }
}

private func currentEnvOrThrow() throws -> String {
    guard let env = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"] else {
        throw ValidationError("No active environment. Use --env <env> or switch with `orrery use <env>`.")
    }
    return env
}
