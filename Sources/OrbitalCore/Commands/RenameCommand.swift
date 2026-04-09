import ArgumentParser
import Foundation

public struct RenameCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: L10n.Rename.abstract
    )

    @Argument(help: ArgumentHelp(L10n.Rename.nameHelp))
    public var name: String

    @Argument(help: ArgumentHelp(L10n.Rename.newNameHelp))
    public var newName: String

    public init() {}

    public func run() throws {
        if name == ReservedEnvironment.defaultName || newName == ReservedEnvironment.defaultName {
            throw ValidationError(L10n.Rename.reservedName)
        }
        let store = EnvironmentStore.default
        try Self.renameEnvironment(from: name, to: newName, store: store)
        print(L10n.Rename.renamed(name, newName))
    }

    public static func renameEnvironment(from oldName: String, to newName: String, store: EnvironmentStore) throws {
        try store.rename(from: oldName, to: newName)
    }
}
