import ArgumentParser
import Foundation

public struct ListCommand: ParsableCommand {
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

        // Active sandbox + its per-tool account pins (mirrors ShowCommand).
        // ORRERY_ACTIVE_ENV unset or "origin" → origin; the sandbox header
        // is shown only for a non-origin sandbox.
        let activeEnv = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
        let activePins: [String: AccountID]
        if let activeEnv, activeEnv != ReservedEnvironment.defaultName {
            activePins = (try? EnvironmentStore.default.load(named: activeEnv).accounts) ?? [:]
            print(L10n.Account.listSandboxHeader(activeEnv))
            print("")
        } else {
            activePins = EnvironmentStore.default.loadOriginConfig().accounts
        }

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

            // Pad display names to the longest in this group, plus 2 spaces.
            let maxNameLen = accts.map(\.displayName.count).max() ?? 0
            let activeID = activePins[tool.rawValue]

            // For the active pin, read email/plan live from the active config dir
            // so a `/login` (or any other out-of-band credential change) shows up
            // immediately, without waiting for the next sync-back round trip.
            let liveActive: ToolAuth.AccountInfo? = activeID.map { _ in
                ToolAuth.liveActiveInfo(tool: tool, env: activeEnv)
            }

            for acct in accts {
                let email: String?
                let plan: String?
                if acct.id == activeID, let live = liveActive {
                    email = live.email ?? acct.email
                    plan = live.plan ?? acct.plan
                } else {
                    email = acct.email
                    plan = acct.plan
                }
                let suffix = [email, plan].compactMap { $0 }.joined(separator: ", ")
                let tail: String
                if suffix.isEmpty {
                    tail = ""
                } else {
                    let padding = String(repeating: " ", count: max(0, maxNameLen - acct.displayName.count + 2))
                    tail = "\(padding)\(suffix)"
                }
                let marker = acct.id == activeID ? "●" : "-"
                print(L10n.Account.listRow(marker, acct.displayName, tail))
            }
        }
    }
}
