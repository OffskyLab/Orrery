import ArgumentParser
import Foundation

public struct DeleteCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: L10n.Delete.abstract
    )

    @Argument(help: ArgumentHelp(L10n.Delete.nameHelp))
    public var name: String?

    @Flag(name: .long, help: ArgumentHelp(L10n.Delete.forceHelp))
    public var force: Bool = false

    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default
        if let name {
            try Self.deleteOne(name: name, force: force, store: store)
        } else {
            try Self.deleteInteractive(force: force, store: store)
        }
    }

    // MARK: - Single-target

    static func deleteOne(name: String, force: Bool, store: EnvironmentStore) throws {
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
        try store.delete(named: name)
        print(L10n.Delete.deleted(name))
    }

    // MARK: - Multi-select

    static func deleteInteractive(force: Bool, store: EnvironmentStore) throws {
        let names = (try? store.listNames().sorted()) ?? []
        guard !names.isEmpty else {
            print(L10n.Delete.noEnvs)
            return
        }

        let selector = MultiSelect(title: L10n.Delete.multiSelectTitle, options: names)
        let indices = selector.run()
        let selected = indices.map { names[$0] }
        guard !selected.isEmpty else {
            print(L10n.Delete.nothingSelected)
            return
        }

        if !force {
            // Show the selection so the user can confirm what's about to be deleted.
            for n in selected { print("  - \(n)") }
            print(L10n.Delete.confirmBatch(selected.count), terminator: "")
            let input = readLine()?.lowercased().trimmingCharacters(in: .whitespaces)
            guard input == "y" || input == "yes" else {
                print(L10n.Delete.aborted)
                return
            }
        }

        for n in selected {
            do {
                try store.delete(named: n)
                print(L10n.Delete.deleted(n))
            } catch {
                stderrWrite("⚠️  \(n): \(error.localizedDescription)\n")
            }
        }
    }

    // MARK: - Public helper (used by tests)

    public static func deleteEnvironment(name: String, force: Bool, store: EnvironmentStore) throws {
        try deleteOne(name: name, force: force, store: store)
    }
}
