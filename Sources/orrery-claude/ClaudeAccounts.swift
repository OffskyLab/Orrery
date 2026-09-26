import Foundation
import AIToolKit

/// Claude's accounts, answered by claude's own process.
///
/// Every method here is a host feature reaching a tool that owns the answer:
/// `orrery list` reaches `list()`, `orrery use` reaches `setCurrent(id:)`,
/// `orrery add` reaches `addAccount(id:name:)`. The host decides which account
/// and when; where it lives and what is in it never leaves this side.
///
/// ## Identity is filled in here, not by the host
///
/// `list()` returns accounts already carrying email and plan, read from each
/// account's own directory. The host does not fetch identities separately and
/// stitch them onto rows — it asked one question and got whole accounts back.
/// This is also why the listing stays cheap: identities come from files, with the
/// credential store left alone, exactly as `listIdentities` does.
extension ClaudeTool: AIToolAccounts {

    func list() async throws -> [Account] {
        let store = try ClaudeAccountStore()
        return try store.list().map { account in
            enriched(account, in: store.configDir(for: account.id))
        }
    }

    func current() async throws -> Account? {
        let store = try ClaudeAccountStore()
        guard let account = try store.current() else { return nil }
        // A detail view, so the credential store is worth one spawn: an
        // in-session `/login` lands there before it lands anywhere else.
        let record = ClaudeIdentity.fresh(in: store.configDir(for: account.id))
        return Account(id: account.id, name: account.name,
                       email: record.email ?? account.email,
                       plan: record.plan ?? account.plan)
    }

    func setCurrent(id: AccountID) async throws {
        try ClaudeAccountStore().setCurrent(id: id)
    }

    func addAccount(id: AccountID, name: String) async throws -> Account {
        let store = try ClaudeAccountStore()
        let account = try store.add(id: id, name: name)
        // The config directory is created here because the account is not usable
        // without one, and the host must not be the thing that knows claude keeps
        // its state in a directory called `.claude`.
        try store.prepareConfigDir(for: id)
        return account
    }

    func deleteAccount(id: AccountID) async throws {
        try ClaudeAccountStore().delete(id: id)
    }

    /// An account with whatever its directory can say about who it belongs to.
    ///
    /// Missing identity is not an error and not an absent account: a directory
    /// that was created but never logged into is a real account with no user yet.
    private func enriched(_ account: Account, in configDir: URL) -> Account {
        let record = ClaudeIdentity.fromFiles(in: configDir)
        return Account(id: account.id, name: account.name,
                       email: record.email ?? account.email,
                       plan: record.plan ?? account.plan)
    }
}
