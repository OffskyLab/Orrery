import ArgumentParser
import Foundation

public struct RemoveCommand: ParsableCommand {
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

    @Argument(help: ArgumentHelp(L10n.Account.nameSelectorHelp))
    public var name: String

    public init() {}

    public func run() throws {
        let tool = try AddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)
        let acctStore = AccountStore.default
        guard let acct = try acctStore.findByDisplayName(name, tool: tool) else {
            throw ValidationError(L10n.Account.removeNotFound(name, tool.rawValue))
        }

        let refs = try EnvironmentStore.default.envsReferencing(accountID: acct.id, tool: tool)
        if !refs.isEmpty {
            throw ValidationError(
                L10n.Account.removeStillReferenced(name, refs.joined(separator: ", "))
            )
        }

        try acctStore.delete(id: acct.id, tool: tool)

        #if os(macOS)
        if tool == .claude, let kc = acct.keychainItem {
            ClaudeKeychain.deleteKeychainItem(service: kc)  // best effort cleanup
        }
        #endif

        print(L10n.Account.removeRemoved(tool.rawValue, name))
    }
}
