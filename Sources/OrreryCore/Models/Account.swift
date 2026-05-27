import Foundation

public typealias AccountID = String

/// 跨 env 共用的工具憑證 pool 中的一筆。
/// 持久化於 `~/.orrery/accounts/<tool>/<id>/metadata.json`。
public struct Account: Codable, Sendable, Equatable {
    public let id: AccountID
    public var tool: Tool
    public var displayName: String
    public let createdAt: Date

    /// macOS Claude 專用：對應的 Keychain item 名稱。
    /// 其他工具 / 平台組合為 nil。
    public var keychainItem: String?

    /// 帳號的 email，從憑證來源擷取後快取在這。
    /// `list` / `show` 直接顯示此欄位，不再每次重讀 Keychain / JSON。
    /// 新增帳號、migrate、sync-back 後自動刷新（透過 `refreshInfo(...)`）。
    public var email: String?

    /// 帳號的訂閱方案（Claude `subscriptionType` / Codex `chatgpt_plan_type` 等）。
    /// 與 `email` 同樣由 `refreshInfo(...)` 自動填入。
    public var plan: String?

    /// 這個 Account 被 pin 到哪個 Workspace（v3.1 之後啟用）。預設 "origin"。
    /// 決定 Account dir 內的 `projects/`、`memory/`、`agents/`、`commands/`、`todos/`
    /// symlink 指向哪個 workspace 的 claude-workspace dir。
    public var workspace: String

    public init(
        id: AccountID = UUID().uuidString,
        tool: Tool,
        displayName: String,
        createdAt: Date = Date(),
        keychainItem: String? = nil,
        email: String? = nil,
        plan: String? = nil,
        workspace: String = "origin"
    ) {
        self.id = id
        self.tool = tool
        self.displayName = displayName
        self.createdAt = createdAt
        self.keychainItem = keychainItem
        self.email = email
        self.plan = plan
        self.workspace = workspace
    }

    // MARK: - Codable
    //
    // Custom decoding so OLD `metadata.json` files written before `email`/`plan`
    // existed still decode cleanly (the new keys are simply absent → nil).
    // Encoding uses the synthesized behavior (optionals serialize naturally).

    private enum CodingKeys: String, CodingKey {
        case id
        case tool
        case displayName
        case createdAt
        case keychainItem
        case email
        case plan
        case workspace
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(AccountID.self, forKey: .id)
        self.tool = try c.decode(Tool.self, forKey: .tool)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.keychainItem = try c.decodeIfPresent(String.self, forKey: .keychainItem)
        self.email = try c.decodeIfPresent(String.self, forKey: .email)
        self.plan = try c.decodeIfPresent(String.self, forKey: .plan)
        self.workspace = try c.decodeIfPresent(String.self, forKey: .workspace) ?? "origin"
    }
}

extension Account {
    /// 從 pool-side 來源刷新 `email` / `plan`。回傳是否有任何欄位實際變動
    /// （避免無謂的 save）。
    ///
    /// 對 Claude：email 優先取 pool snapshot（`<poolDir>/oauthAccount.json`，
    /// 由 `prepareSyncBack` / `AccountLoginFlow.importFrom` 捕入），讀不到才退
    /// 而求其次用 credential JWT 的 email claim。plan 一律從 credential JWT
    /// 的 `subscriptionType` 取。**不再讀 active `.claude.json`** — 那個檔案
    /// 跟 pool 不一定同步，過去把它當成 email canonical source 是 stored 欄位
    /// 被 email/plan 不同身份混雜汙染的根因。
    ///
    /// 任何來源讀不到就「保留原值」，永遠不 throw。
    @discardableResult
    public mutating func refreshInfo(accountStore: AccountStore) -> Bool {
        var changed = false

        switch tool {
        case .codex:
            let info = ToolAuth.accountInfo(forPoolAccount: self, accountStore: accountStore)
            if let e = info.email, e != email { email = e; changed = true }
            if let p = info.plan, p != plan { plan = p; changed = true }

        case .gemini:
            let info = ToolAuth.accountInfo(forPoolAccount: self, accountStore: accountStore)
            if let e = info.email, e != email { email = e; changed = true }
            // OAuth gemini has no plan; if a future code path surfaces one (e.g. api key),
            // pick it up too.
            if let p = info.plan, p != plan { plan = p; changed = true }

        case .claude:
            let info = ToolAuth.accountInfo(forPoolAccount: self, accountStore: accountStore)
            if let p = info.plan, p != plan { plan = p; changed = true }

            let poolDir = accountStore.accountDir(id: id, tool: .claude)
            if let snap = ClaudeOAuthSnapshot.loadSnapshot(poolDir: poolDir),
               let e = snap["emailAddress"] as? String, e != email {
                email = e; changed = true
            } else if let e = info.email, e != email {
                email = e; changed = true
            }
        }

        return changed
    }
}
