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

    // MARK: - Tools that have no plugin yet

    /// What a tool's identity is when nothing can be asked.
    ///
    /// Two different situations land here and they deserve different names, so
    /// this only covers one of them: a tool orrery still reads for itself,
    /// because no plugin exists to hand the reading to. codex and gemini are
    /// both in that position.
    ///
    /// The other situation — a tool that *has* a plugin which did not load —
    /// deliberately falls through to the account's own recorded fields and
    /// nothing else. Reading claude's files here anyway is what made the plugin
    /// unobservable: delete `orrery-claude` and every answer stayed identical,
    /// which is indistinguishable from never having consulted it. The bootstrap
    /// says a missing shipped plugin is a broken install, and an answer produced
    /// behind its back contradicts that one call site at a time.
    static func legacyResolve(
        for account: Account, isLiveInThisShell: Bool, store: AccountStore
    ) -> (email: String?, plan: String?) {
        switch account.tool {
        case .claude:
            // Answered by the plugin, or not at all. What remains is orrery's
            // own record — a cache it wrote itself, not claude knowledge.
            return (account.email, account.plan)

        case .codex, .gemini:
            // No plugin to ask yet, so orrery still reads the pool directly.
            // This goes the same way claude's did, once those plugins exist.
            let freshInfo = ToolAuth.accountInfo(forPoolAccount: account, accountStore: store)
            return (freshInfo.email ?? account.email, freshInfo.plan ?? account.plan)
        }
    }

}
