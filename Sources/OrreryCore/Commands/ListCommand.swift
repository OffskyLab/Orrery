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

                // Resolve email/plan. The authoritative current login lives in the
                // account's identity store, which `_capture-claude-exit` refreshes
                // after every session — newer Claude versions stopped writing
                // `emailAddress` anywhere `refreshInfo` can re-derive it, so the
                // `metadata.json` cache (acct.email/plan) drifts and is only a
                // last-resort fallback.
                let email: String?
                let plan: String?
                if tool == .claude {
                    // Prefer the live CLAUDE_CONFIG_DIR for the active account (reflects an
                    // in-session `/login` immediately), then the persisted identity store
                    // (fresh as of the last session exit), then the metadata cache.
                    var liveEmail: String?
                    var livePlan: String?
                    if isActive {
                        let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
                        let freshInfo = ClaudeKeychain.accountInfo(for: configDir)
                        liveEmail = freshInfo.email
                        livePlan = freshInfo.plan
                    }
                    let idInfo = ListCommand.claudeIdentityInfo(for: acct, store: store)
                    email = liveEmail ?? idInfo.email ?? acct.email
                    plan = livePlan ?? idInfo.plan ?? acct.plan
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

    /// Read email + plan for a claude account from its persisted identity store
    /// (`claude-identity.json` → `oauthAccount.emailAddress` / `subscriptionType`).
    /// `_capture-claude-exit` refreshes this after every session, so it is the
    /// authoritative local source for the account's current login. Returns nils
    /// when the file or fields are absent (callers fall back to the metadata cache).
    private static func claudeIdentityInfo(
        for account: Account, store: AccountStore
    ) -> (email: String?, plan: String?) {
        let accountDir = store.accountDir(id: account.id, tool: .claude)
        let identityURL = ClaudeJsonMerge.identityFileURL(accountDir: accountDir)
        guard let identity = ClaudeJsonMerge.loadJSON(at: identityURL),
              let oauth = identity["oauthAccount"] as? [String: Any] else {
            return (nil, nil)
        }
        return (oauth["emailAddress"] as? String, oauth["subscriptionType"] as? String)
    }
}
