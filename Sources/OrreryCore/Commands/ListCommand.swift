import ArgumentParser
import Foundation

public struct ListCommand: AsyncParsableCommand {
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

    public func run() async throws {
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
        // `configDir` rather than the enum's `defaultConfigDir`: claude is
        // described by its plugin, so this is the answer that crossed the pipe.
        // It is nil when that plugin did not load, and nil flows to the same
        // place an unset CLAUDE_CONFIG_DIR does — the active-account line is
        // left blank rather than filled in from a tool orrery cannot describe.
        // A read degrading to "missing" is exactly what the spec asks for here.
        let activeClaudeDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? (isOriginScope ? Tool.claude.configDir()?.path : nil)
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

        // Rows come from `AccountListing`, which asks a tool's plugin when the
        // tool has one and reads orrery's pool when it does not. This command
        // does not know which it got, and must not: the difference is exactly
        // what is being removed.
        let listing = AccountListing(store: store)
        let tools = filter.map { [$0] } ?? Tool.allCases

        var groups: [(tool: Tool, rows: [AccountListing.Row])] = []
        for tool in tools {
            let rows = try await listing.rows(
                for: tool, liveAccountID: activePins[tool.rawValue])
            if !rows.isEmpty { groups.append((tool, rows)) }
        }

        if groups.isEmpty {
            print(L10n.Account.listEmpty)
            return
        }

        for (tool, rows) in groups {
            print(L10n.Account.listToolHeader(tool.rawValue))

            // Pad display names to the longest in this group, plus 2 spaces.
            let maxNameLen = rows.map(\.displayName.count).max() ?? 0
            let activeID = activePins[tool.rawValue]

            for row in rows {
                let suffix = [row.email, row.plan].compactMap { $0 }.joined(separator: ", ")
                let tail: String
                if suffix.isEmpty {
                    tail = ""
                } else {
                    let padding = String(repeating: " ", count: max(0, maxNameLen - row.displayName.count + 2))
                    tail = "\(padding)\(suffix)"
                }
                let marker = row.id == activeID ? "●" : "-"
                print(L10n.Account.listRow(marker, row.displayName, tail))
            }
        }
    }
}
