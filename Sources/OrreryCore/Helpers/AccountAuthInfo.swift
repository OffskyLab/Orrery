import Foundation
import AIToolKit

/// Who an account is logged in as.
///
/// Two entry points, matching the two features that ask: `identities(for:…)` for
/// a listing and `identity(for:…)` for a detail view. Both prefer the tool's own
/// answer and fall back to `legacyResolve` below.
///
/// **`legacyResolve` is transitional.** It is claude's identity knowledge —
/// where the live config dir is, what `claude-identity.json` holds, which
/// Claude versions stopped writing `emailAddress` — sitting in the host, and it
/// leaves when claude's plugin implements `AIToolIdentityReporting`. Until then
/// it is the branch production actually takes.
enum AccountAuthInfo {

    // MARK: - Routed through the tool, when the tool can answer

    /// Identities for a listing: one answer per account, positionally.
    ///
    /// Asks the tool once for every directory rather than once per account. The
    /// per-account loop was never a requirement — it was the shape the `switch`
    /// below happened to have — and a listing is exactly the case a tool should
    /// be allowed to answer cheaply in bulk.
    ///
    /// - Parameter liveAccountID: the account this shell is actually pointed at,
    ///   if any. That decision is orrery's — it is about pins and this shell, not
    ///   about the tool — so it stays here and only decides *which directory* is
    ///   handed over.
    static func identities(
        for accounts: [Account],
        liveAccountID: AccountID?,
        store: AccountStore,
        registry: AIToolRegistry = .shared
    ) async -> [(email: String?, plan: String?)] {
        guard !accounts.isEmpty else { return [] }

        // Grouped by tool because one call per tool is the point; accounts of
        // different tools cannot share a reply.
        var answers = [(email: String?, plan: String?)](
            repeating: (nil, nil), count: accounts.count)
        let byTool = Dictionary(grouping: accounts.indices) { accounts[$0].tool }

        for (tool, indices) in byTool {
            guard let reporter = registry.tool(id: tool.rawValue)
                    .flatMap(ToolCapability.identityReporting) else {
                // No tool-side answer available. Today this is every tool; see
                // the type's note.
                for i in indices {
                    answers[i] = legacyResolve(
                        for: accounts[i],
                        isLiveInThisShell: accounts[i].id == liveAccountID,
                        store: store)
                }
                continue
            }

            let dirs = indices.map {
                configDirToInspect(for: accounts[$0],
                                   isLiveInThisShell: accounts[$0].id == liveAccountID,
                                   store: store)
            }
            guard let found = try? await reporter.listIdentities(in: dirs),
                  found.count == dirs.count else {
                // A read that failed degrades to the persisted fields rather than
                // to nothing: a listing with blank columns is worse than a
                // listing showing what orrery last recorded.
                for i in indices {
                    answers[i] = (accounts[i].email, accounts[i].plan)
                }
                continue
            }
            for (slot, i) in indices.enumerated() {
                answers[i] = (found[slot]?.email ?? accounts[i].email,
                              found[slot]?.plan ?? accounts[i].plan)
            }
        }
        return answers
    }

    /// The freshest identity for one account, for a detail view.
    static func identity(
        for account: Account,
        isLiveInThisShell: Bool,
        store: AccountStore,
        registry: AIToolRegistry = .shared
    ) async -> (email: String?, plan: String?) {
        guard let reporter = registry.tool(id: account.tool.rawValue)
                .flatMap(ToolCapability.identityReporting) else {
            return legacyResolve(for: account, isLiveInThisShell: isLiveInThisShell, store: store)
        }
        let dir = configDirToInspect(
            for: account, isLiveInThisShell: isLiveInThisShell, store: store)
        // Explicit do/catch rather than `try?`: this call returns an optional and
        // `try?` would flatten both levels, collapsing "the lookup threw" into
        // "there is no login here" — the very distinction the protocol draws.
        let found: LoginIdentity?
        do {
            found = try await reporter.showIdentity(in: dir)
        } catch {
            return (account.email, account.plan)
        }
        return (found?.email ?? account.email, found?.plan ?? account.plan)
    }

    /// Which directory the tool is asked about.
    ///
    /// The live config dir when this shell is pointed at that account — an
    /// in-session `/login` shows up there first — and the pooled account
    /// directory otherwise. Reading the shell's dir for an account that is *not*
    /// live would report some other account's identity under this one's name.
    private static func configDirToInspect(
        for account: Account, isLiveInThisShell: Bool, store: AccountStore
    ) -> URL {
        if isLiveInThisShell,
           let live = ProcessInfo.processInfo.environment[account.tool.envVarName],
           !live.isEmpty {
            return URL(fileURLWithPath: live)
        }
        return store.accountDir(id: account.id, tool: account.tool)
    }

    // MARK: - The implementation that has not moved yet

    /// - Parameter isLiveInThisShell: whether `account` is the one this shell would
    ///   actually use right now (e.g. `CLAUDE_CONFIG_DIR` points at it). Only then is
    ///   a live credential-source read attempted; otherwise persisted/cached info is used.
    /// The name the two commands still call.
    ///
    /// They keep calling it because routing them through the async entry points
    /// above makes `run()` async, which makes `withIsolatedHome` async, which
    /// reaches 160 call sites across 30 test files. That migration is real and
    /// coming; it is not this change.
    static func resolve(
        for account: Account, isLiveInThisShell: Bool, store: AccountStore
    ) -> (email: String?, plan: String?) {
        legacyResolve(for: account, isLiveInThisShell: isLiveInThisShell, store: store)
    }

    static func legacyResolve(
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
