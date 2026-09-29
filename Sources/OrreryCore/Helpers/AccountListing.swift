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
enum AccountListingError: Error, CustomStringConvertible {
    case noSuchAccount(id: AccountID, tool: Tool)

    var description: String {
        switch self {
        case .noSuchAccount(let id, let tool):
            return "\(tool.rawValue) has no account '\(id)'"
        }
    }
}

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

    // MARK: - Writing

    /// Create an account and return the id it was given.
    ///
    /// The host chooses the id either way, so the two paths agree on what an
    /// account is called even while they disagree on where it lives.
    ///
    /// - Returns: nil when this tool has no plugin, meaning the caller keeps its
    ///   existing path. Deliberately not a fallback that writes to the pool:
    ///   `AccountListing` knowing how to create an orrery-side account would put
    ///   a second creation path behind one call, and the two would drift.
    func addIfPluginOwned(tool: Tool, id: AccountID, displayName: String) async throws -> Row? {
        guard let accounts = accountsCapability(tool) else { return nil }
        let account = try await accounts.addAccount(id: id, name: displayName)
        return Row(id: account.id, displayName: account.name,
                   email: account.email, plan: account.plan)
    }

    /// Delete an account through whichever side owns it.
    ///
    /// - Returns: false when this tool has no plugin, so the caller does its own
    ///   removal.
    /// - Throws: when the account is plugin-owned but not there. A delete that
    ///   removed nothing must not be reported as done.
    func deleteIfPluginOwned(tool: Tool, id: AccountID) async throws -> Bool {
        guard let account = try await pluginAccount(tool: tool, id: id) else { return false }
        try await account.delete()
        return true
    }

    /// Designate an account as the tool's current one.
    ///
    /// Separate from ``pinIfPluginOwned(tool:id:workspace:)`` because orrery has
    /// them separate too: `_pin-current` records a global current, `orrery pin`
    /// binds an account to a workspace, and the two survive each other changing.
    ///
    /// - Returns: false when this tool has no plugin.
    func makeCurrentIfPluginOwned(tool: Tool, id: AccountID) async throws -> Bool {
        guard let account = try await pluginAccount(tool: tool, id: id) else { return false }
        try await account.makeCurrent()
        return true
    }

    /// Record which workspace an account belongs to.
    ///
    /// - Returns: false when this tool has no plugin.
    func pinIfPluginOwned(tool: Tool, id: AccountID, workspace: String) async throws -> Bool {
        guard let account = try await pluginAccount(tool: tool, id: id) else { return false }
        try await account.pin(to: workspace)
        return true
    }

    /// The plugin's own account, if this tool has one.
    ///
    /// - Returns: nil when the tool has no plugin — the caller keeps its own path.
    /// - Throws: when the tool is plugin-owned but has no such account, because
    ///   then an operation reported as done would have done nothing.
    private func pluginAccount(tool: Tool, id: AccountID) async throws -> (any AIToolKit.Account)? {
        guard let accounts = accountsCapability(tool) else { return nil }
        guard let account = try await accounts.list().first(where: { $0.id == id }) else {
            throw AccountListingError.noSuchAccount(id: id, tool: tool)
        }
        return account
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
