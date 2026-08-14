import Foundation

/// Resolves the freshest known email/plan for an account, shared by `list` and `show`
/// so both commands agree on what "currently logged in" means per tool.
enum AccountAuthInfo {
    /// - Parameter isLiveInThisShell: whether `account` is the one this shell would
    ///   actually use right now (e.g. `CLAUDE_CONFIG_DIR` points at it). Only then is
    ///   a live credential-source read attempted; otherwise persisted/cached info is used.
    static func resolve(
        for account: Account, isLiveInThisShell: Bool, store: AccountStore
    ) -> (email: String?, plan: String?) {
        switch account.tool {
        case .claude:
            // Prefer the live CLAUDE_CONFIG_DIR (reflects an in-session `/login`
            // immediately), then the persisted identity store (fresh as of the last
            // session exit — `_capture-claude-exit` refreshes it), then the
            // metadata.json cache, which can drift on newer Claude versions that
            // stopped writing `emailAddress` anywhere `refreshInfo` can re-derive it.
            var liveEmail: String?
            var livePlan: String?
            if isLiveInThisShell {
                let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
                let freshInfo = ClaudeKeychain.accountInfo(for: configDir)
                liveEmail = freshInfo.email
                livePlan = freshInfo.plan
            }
            let idInfo = claudeIdentityInfo(for: account, store: store)
            return (liveEmail ?? idInfo.email ?? account.email, livePlan ?? idInfo.plan ?? account.plan)

        case .codex, .gemini:
            // codex/gemini don't have live config dirs in v3.1 — read from the pool.
            let freshInfo = ToolAuth.accountInfo(forPoolAccount: account, accountStore: store)
            return (freshInfo.email ?? account.email, freshInfo.plan ?? account.plan)
        }
    }

    /// Read email + plan for a claude account from its persisted identity store
    /// (`claude-identity.json` → `oauthAccount.emailAddress` / `subscriptionType`).
    /// Returns nils when the file or fields are absent (callers fall back further).
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
