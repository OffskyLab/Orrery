import ArgumentParser
import Foundation

public struct RemoveCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: L10n.Account.removeAbstract
    )

    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagClaudeHelp))
    public var claude: Bool = false
    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagCodexHelp))
    public var codex: Bool = false
    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagGeminiHelp))
    public var gemini: Bool = false

    @Flag(name: .long, help: ArgumentHelp(L10n.Account.removeForceHelp))
    public var force: Bool = false

    @Argument(help: ArgumentHelp(L10n.Account.removeNameHelp))
    public var name: String?

    public init() {}

    public func run() async throws {
        let tool = try AddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)
        let acctStore = AccountStore.default
        if let name {
            try await Self.removeOne(name: name, tool: tool, acctStore: acctStore)
        } else {
            try await Self.removeInteractive(tool: tool, force: force, acctStore: acctStore)
        }
    }

    // MARK: - Single-target

    static func removeOne(name: String, tool: Tool, acctStore: AccountStore) async throws {
        // Looked up through the listing, because for a plugin-owned tool
        // orrery's own pool holds nothing to find.
        let listing = AccountListing(store: acctStore)
        guard let row = try await listing.rows(for: tool, liveAccountID: nil)
            .first(where: { $0.displayName == name })
        else {
            throw ValidationError(L10n.Account.removeNotFound(name, tool.rawValue))
        }

        if try await listing.deleteIfPluginOwned(tool: tool, id: row.id) {
            print(L10n.Account.removeRemoved(tool.rawValue, name))
            return
        }

        guard let acct = try acctStore.findByDisplayName(name, tool: tool) else {
            throw ValidationError(L10n.Account.removeNotFound(name, tool.rawValue))
        }
        try removeAccount(acct, tool: tool, acctStore: acctStore)
        print(L10n.Account.removeRemoved(tool.rawValue, name))
    }

    // MARK: - Multi-select

    static func removeInteractive(tool: Tool, force: Bool, acctStore: AccountStore) async throws {
        let accounts = try acctStore.list(tool: tool)
        guard !accounts.isEmpty else {
            print(L10n.Account.removeNoAccounts(tool.rawValue))
            return
        }

        let selector = MultiSelect(title: L10n.Account.removeMultiSelectTitle, options: accounts.map(\.displayName))
        let indices = selector.run()
        let selected = indices.map { accounts[$0] }
        guard !selected.isEmpty else {
            print(L10n.Account.removeNothingSelected)
            return
        }

        if !force {
            for acct in selected { print("  - \(acct.displayName)") }
            print(L10n.Account.removeConfirmBatch(selected.count), terminator: "")
            let input = readLine()?.lowercased().trimmingCharacters(in: .whitespaces)
            guard input == "y" || input == "yes" else {
                print(L10n.Account.removeAborted)
                return
            }
        }

        for acct in selected {
            do {
                if try await AccountListing(store: acctStore)
                    .deleteIfPluginOwned(tool: tool, id: acct.id) == false {
                    try removeAccount(acct, tool: tool, acctStore: acctStore)
                }
                print(L10n.Account.removeRemoved(tool.rawValue, acct.displayName))
            } catch {
                FileHandle.standardError.write(Data("⚠️  \(acct.displayName): \(error.localizedDescription)\n".utf8))
            }
        }
    }

    // MARK: - Shared

    private static func removeAccount(_ acct: Account, tool: Tool, acctStore: AccountStore) throws {
        let refs = try EnvironmentStore.default.envsReferencing(accountID: acct.id, tool: tool)
        if !refs.isEmpty {
            throw ValidationError(
                L10n.Account.removeStillReferenced(acct.displayName, refs.joined(separator: ", "))
            )
        }

        try acctStore.delete(id: acct.id, tool: tool)

        #if os(macOS)
        if tool == .claude, let kc = acct.keychainItem {
            ClaudeKeychain.deleteKeychainItem(service: kc)  // best effort cleanup
        }
        #endif
    }
}
