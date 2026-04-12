import ArgumentParser
import Foundation

public struct CurrentCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "current",
        abstract: L10n.Current.abstract
    )
    public init() {}

    public func run() throws {
        if let active = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"] {
            print(active)
        } else {
            print(L10n.Current.noActive)
        }
    }
}
