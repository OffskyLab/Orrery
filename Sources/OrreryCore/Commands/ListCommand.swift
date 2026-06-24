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
        var activePins: [String: AccountID]
        if let activeEnv, activeEnv != Workspace.reservedOriginName {
            activePins = (try? EnvironmentStore.default.load(named: activeEnv).accounts) ?? [:]
            print(L10n.Account.listSandboxHeader(activeEnv))
            print("")
        } else {
            activePins = EnvironmentStore.default.loadOriginWorkspace().accounts
        }

        // In v3.1, claude account selection is handled by the shell function via
        // CLAUDE_CONFIG_DIR. If that env var is set, read the account ID from
        // metadata.json and use it as the active claude account (overriding the
        // pin from workspace metadata).
        if let claudeConfigDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            let metadataURL = URL(fileURLWithPath: claudeConfigDir)
                .appendingPathComponent("metadata.json")
            do {
                let data = try Data(contentsOf: metadataURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let account = try decoder.decode(Account.self, from: data)
                activePins[Tool.claude.rawValue] = account.id
            } catch {
                // Silently fall back to workspace metadata on decode failure
            }
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

            for acct in accts {
                let isActive = acct.id == activeID

                // For the active account, read fresh info from the live config dir
                // (so `/login` changes in Claude Code are reflected immediately).
                // Fall back to cached metadata if dynamic read returns nil.
                // For inactive accounts, use cached metadata to avoid I/O overhead.
                let email: String?
                let plan: String?
                if isActive && tool == .claude {
                    // For claude, read from the live CLAUDE_CONFIG_DIR (not the pool copy)
                    // so `/login` changes are reflected immediately.
                    let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
                    let freshInfo = ClaudeKeychain.accountInfo(for: configDir)
                    email = freshInfo.email ?? acct.email
                    plan = freshInfo.plan ?? acct.plan
                } else if isActive {
                    // For codex/gemini, read from pool (they don't have live config dirs in v3.1)
                    let freshInfo = ToolAuth.accountInfo(forPoolAccount: acct, accountStore: store)
                    email = freshInfo.email ?? acct.email
                    plan = freshInfo.plan ?? acct.plan
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
                let marker = isActive ? "●" : "-"
                print(L10n.Account.listRow(marker, acct.displayName, tail))
            }
        }
    }
}
