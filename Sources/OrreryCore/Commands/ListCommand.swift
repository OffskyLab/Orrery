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

        // In v3.1, the active claude account is whichever config dir claude
        // itself would read: CLAUDE_CONFIG_DIR when a sandbox/account is selected,
        // otherwise the origin default ~/.claude (which v3.1 points at the origin
        // account dir). Recover the account id from that dir's metadata.json so a
        // fresh shell at origin shows origin as the active default — not blank.
        let isOriginScope = activeEnv == nil || activeEnv == Workspace.reservedOriginName
        let activeClaudeDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? (isOriginScope ? Tool.claude.defaultConfigDir.path : nil)
        if let activeClaudeDir {
            let metadataURL = URL(fileURLWithPath: activeClaudeDir)
                .appendingPathComponent("metadata.json")
            do {
                let data = try Data(contentsOf: metadataURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let account = try decoder.decode(Account.self, from: data)
                activePins[Tool.claude.rawValue] = account.id
            } catch {
                // ~/.claude isn't a v3.1 account dir (legacy layout or broken
                // symlink) — keep the workspace pin already in activePins.
            }
        }

        // Same idea for codex/gemini: `orrery use --codex/--gemini` (the
        // _account-dir fast path) only exports CODEX_HOME/ORRERY_GEMINI_HOME
        // for the current shell — it never touches the persisted pin. Neither
        // tool has claude's ~/.claude-origin-repoint invariant, so there's no
        // defaultConfigDir fallback here, just the live-env-var override.
        for tool in [Tool.codex, .gemini] {
            guard let manager = AccountDirectoryRuntime.manager(ifAvailable: tool),
                  let liveDir = ProcessInfo.processInfo.environment[manager.exportEnvVarName],
                  !liveDir.isEmpty
            else { continue }
            let id = manager.accountID(fromExportPath: URL(fileURLWithPath: liveDir))
            if (try? store.load(id: id, tool: tool)) != nil {
                activePins[tool.rawValue] = id
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

                let info = AccountAuthInfo.resolve(for: acct, isLiveInThisShell: isActive, store: store)
                let suffix = [info.email, info.plan].compactMap { $0 }.joined(separator: ", ")
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
