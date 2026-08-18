import ArgumentParser
import Foundation

/// `orrery current` — show which account is globally pinned per tool, i.e.
/// the account `_current-export` will restore in a brand-new shell after
/// `orrery use`. Unlike `orrery show`, this never reflects a shell-only
/// override — it always reads the persisted pin.
public struct CurrentCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "current",
        abstract: L10n.CurrentAccount.abstract
    )

    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagClaudeHelp))
    public var claude: Bool = false
    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagCodexHelp))
    public var codex: Bool = false
    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagGeminiHelp))
    public var gemini: Bool = false

    public init() {}

    public func run() throws {
        let selected: [Tool] = [claude ? Tool.claude : nil,
                                codex ? Tool.codex : nil,
                                gemini ? Tool.gemini : nil].compactMap { $0 }
        guard selected.count <= 1 else {
            throw ValidationError("Pass at most one of --claude, --codex, --gemini.")
        }
        let tools = selected.isEmpty ? Tool.allCases : selected

        let acctStore = AccountStore.default
        let origin = EnvironmentStore.default.loadOriginWorkspace()

        for tool in tools {
            if let id = origin.account(for: tool),
               let acct = try? acctStore.load(id: id, tool: tool) {
                print(L10n.Account.showRowHeader(tool.rawValue, acct.displayName))
            } else {
                print(L10n.Account.showRowUnpinned(tool.rawValue))
            }
        }
    }
}
