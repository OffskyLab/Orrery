import ArgumentParser
import Foundation

public struct AccountListCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: L10n.Account.listAbstract
    )

    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagClaudeHelp))
    public var claude: Bool = false
    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagCodexHelp))
    public var codex: Bool = false
    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagGeminiHelp))
    public var gemini: Bool = false

    public init() {}

    public func run() throws {
        let store = AccountStore.default

        // 只有「剛好一個」flag 才視為過濾；0 或 >1 → 顯示全部。
        let selected: [Tool] = [claude ? Tool.claude : nil,
                                codex ? Tool.codex : nil,
                                gemini ? Tool.gemini : nil].compactMap { $0 }
        let filter: Tool? = selected.count == 1 ? selected[0] : nil

        let grouped: [Tool: [Account]]
        if let f = filter {
            let xs = try store.list(tool: f)
            grouped = xs.isEmpty ? [:] : [f: xs]
        } else {
            grouped = try store.listAll()
        }

        if grouped.isEmpty {
            print(L10n.Account.listEmpty)
            return
        }

        for tool in Tool.allCases {
            guard let accts = grouped[tool], !accts.isEmpty else { continue }
            print(L10n.Account.listToolHeader(tool.rawValue))
            for acct in accts {
                print(L10n.Account.listRow(acct.displayName, acct.id))
            }
        }
    }
}
