import ArgumentParser
import Foundation

public struct RenameCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename an orbital environment"
    )

    @Argument(help: "Current environment name")
    public var name: String

    @Argument(help: "New environment name")
    public var newName: String

    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default
        try Self.renameEnvironment(from: name, to: newName, store: store)
        print("Renamed environment '\(name)' to '\(newName)'")
    }

    public static func renameEnvironment(from oldName: String, to newName: String, store: EnvironmentStore) throws {
        try store.rename(from: oldName, to: newName)
    }
}
