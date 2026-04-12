import ArgumentParser
import Foundation

public struct DeleteCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: L10n.Delete.abstract
    )

    @Argument(help: ArgumentHelp(L10n.Delete.nameHelp))
    public var name: String

    @Flag(name: .long, help: ArgumentHelp(L10n.Delete.forceHelp))
    public var force: Bool = false

    public init() {}

    public func run() throws {
        if name == ReservedEnvironment.defaultName {
            throw ValidationError(L10n.Delete.reservedName)
        }
        if !force {
            print(L10n.Delete.confirm(name), terminator: "")
            let input = readLine()?.lowercased().trimmingCharacters(in: .whitespaces)
            guard input == "y" || input == "yes" else {
                print(L10n.Delete.aborted)
                return
            }
        }
        let store = EnvironmentStore.default
        try Self.deleteEnvironment(name: name, force: force, store: store)
        print(L10n.Delete.deleted(name))
    }

    public static func deleteEnvironment(name: String, force: Bool, store: EnvironmentStore) throws {
        try store.delete(named: name)
    }
}
