import Foundation
import AIToolKit

/// Where a command gets its accounts.
///
/// One seam, deliberately, rather than the same branch written into every
/// command that lists or shows accounts. A tool whose plugin owns its accounts
/// is asked; one that does not is read out of orrery's own pool. Both paths
/// produce the same rows, so a caller never learns which it got.
///
/// ## Why the fork exists and when it goes
///
/// claude's accounts live in `orrery-claude`. codex and gemini still live in
/// `AccountStore`. That split is a transition, not a design — and the way out is
/// not to migrate the other two but to replace them: codex is to be reimplemented
/// against the framework, gemini is dropped for now. When the last tool has
/// moved, the `store` half of this type goes and what remains is a registry
/// lookup.
///
/// Keeping the branch here means that removal is one file, not fourteen.
struct AccountListing {

    /// One account as a command needs to render it.
    ///
    /// Flattened on purpose: the plugin path returns an `AIToolKit.Account`
    /// carrying identity already, while the store path has to fetch identity
    /// separately. A caller that saw the difference would have to care.
    struct Row: Equatable {
        let id: AccountID
        let displayName: String
        let email: String?
        let plan: String?
    }

    let store: AccountStore
    let registry: AIToolRegistry

    init(store: AccountStore, registry: AIToolRegistry = .shared) {
        self.store = store
        self.registry = registry
    }

    /// Whether this tool's accounts come from its plugin.
    ///
    /// Exposed because a command sometimes has to know — `orrery add` cannot
    /// create an account in a pool it does not own — even though listing and
    /// showing do not.
    func isPluginOwned(_ tool: Tool) -> Bool {
        accountsCapability(tool) != nil
    }

    private func accountsCapability(_ tool: Tool) -> (any AIToolAccounts)? {
        registry.tool(id: tool.rawValue).flatMap(ToolCapability.accounts)
    }

    /// Every account for one tool, with whatever identity is available.
    ///
    /// - Throws: only from the plugin path. A plugin that cannot answer is a
    ///   failure worth surfacing: it owns the accounts, so "I cannot say" and
    ///   "there are none" are different, and rendering an empty list for the
    ///   first would tell someone their accounts are gone.
    func rows(for tool: Tool, liveAccountID: AccountID?) async throws -> [Row] {
        if let accounts = accountsCapability(tool) {
            return try await accounts.list().map {
                Row(id: $0.id, displayName: $0.name, email: $0.email, plan: $0.plan)
            }
        }

        let stored = try store.list(tool: tool)
        guard !stored.isEmpty else { return [] }
        let infos = await AccountAuthInfo.identities(
            for: stored, liveAccountID: liveAccountID, store: store, registry: registry)
        return zip(stored, infos).map { account, info in
            Row(id: account.id, displayName: account.displayName,
                email: info.email, plan: info.plan)
        }
    }

    /// One account's freshest identity, for a detail view.
    ///
    /// - Returns: nil when there is no such account. Distinct from an account
    ///   whose identity is unknown, which comes back with nil fields.
    func row(for tool: Tool, id: AccountID, isLiveInThisShell: Bool) async throws -> Row? {
        if isPluginOwned(tool) {
            // The plugin's detail view is `current()`, which answers about the
            // account *it* has pinned. Asking it about an arbitrary id is not in
            // the surface yet, so a listing is filtered instead — still one
            // question, and still the plugin's own answer.
            return try await rows(for: tool, liveAccountID: nil).first { $0.id == id }
        }

        guard let account = try? store.load(id: id, tool: tool) else { return nil }
        let info = await AccountAuthInfo.identity(
            for: account, isLiveInThisShell: isLiveInThisShell,
            store: store, registry: registry)
        return Row(id: account.id, displayName: account.displayName,
                   email: info.email, plan: info.plan)
    }
}
