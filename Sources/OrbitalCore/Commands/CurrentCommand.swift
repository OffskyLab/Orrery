import ArgumentParser
import Foundation

public struct CurrentCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "current",
        abstract: "Print the name of the active environment"
    )
    public init() {}

    public func run() throws {
        if let active = ProcessInfo.processInfo.environment["ORBITAL_ACTIVE_ENV"] {
            print(active)
        } else {
            print("(no active environment)")
        }
    }
}
