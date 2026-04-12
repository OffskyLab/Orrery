import ArgumentParser
import Foundation

public struct WhichCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "which",
        abstract: L10n.Which.abstract
    )

    @Argument(help: ArgumentHelp(L10n.Which.toolHelp))
    public var tool: String

    public init() {}

    public func run() throws {
        guard let t = Tool(rawValue: tool) else {
            throw ValidationError(L10n.Which.unknownTool(tool))
        }
        guard let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"] else {
            throw ValidationError(L10n.Which.noActive)
        }
        let store = EnvironmentStore.default
        let path = store.toolConfigDir(tool: t, environment: envName).path
        print(path)
    }
}
