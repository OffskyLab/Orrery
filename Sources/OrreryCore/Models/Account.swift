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

    public init(
        id: AccountID = UUID().uuidString,
        tool: Tool,
        displayName: String,
        createdAt: Date = Date(),
        keychainItem: String? = nil,
        email: String? = nil,
        plan: String? = nil
    ) {
        self.id = id
        self.tool = tool
        self.displayName = displayName
        self.createdAt = createdAt
        self.keychainItem = keychainItem
        self.email = email
        self.plan = plan
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
    }
}

extension Account {
    /// 從憑證來源（Keychain / `auth.json` / `oauth_creds.json` / `.claude.json`）刷新
    /// `email` / `plan`。回傳是否有任何欄位實際變動（避免無謂的 save）。
    ///
    /// - Parameters:
    ///   - accountStore: 用來解析 pool 內 account dir 的 store。
    ///   - claudeJSONURL: Claude 專屬。`.claude.json` 的位置（email 的唯一來源，
    ///     Claude 的憑證本體不帶 email）。codex / gemini 可忽略。
    ///
    /// 任何來源讀不到就「保留原值」，永遠不 throw。
    @discardableResult
    public mutating func refreshInfo(
        accountStore: AccountStore,
        claudeJSONURL: URL? = nil
    ) -> Bool {
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
            // PLAN — read the OAuth credential blob (macOS Keychain or Linux file).
            let info = ToolAuth.accountInfo(forPoolAccount: self, accountStore: accountStore)
            if let p = info.plan, p != plan { plan = p; changed = true }
            // EMAIL from the credential's JWT (best-effort).
            if let e = info.email, e != email { email = e; changed = true }
            // EMAIL from `.claude.json` if provided — this is the canonical source.
            if let url = claudeJSONURL, let e = Self.parseClaudeJSONEmail(at: url), e != email {
                email = e; changed = true
            }
        }

        return changed
    }

    /// 解析 `.claude.json` 裡 `oauthAccount.emailAddress`。讀不到就 nil。
    private static func parseClaudeJSONEmail(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauthAccount = obj["oauthAccount"] as? [String: Any]
        else { return nil }
        return oauthAccount["emailAddress"] as? String
    }
}
