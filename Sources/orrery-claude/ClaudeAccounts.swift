import Foundation
import AIToolKit

/// Claude's accounts, answered by claude's own process.
///
/// What is here is what only the tool can answer: which accounts exist, which one
/// is designated, and making a new one. Everything done *to* an account —
/// pinning, designating, deleting — is on ``ClaudeAccount``, because a caller
/// doing one of those is already holding the account.
///
/// ## Identity is filled in here, not by the host
///
/// The accounts returned already carry email and plan, read from each account's
/// own directory. The host does not fetch identities separately and stitch them
/// onto rows — it asked one question and got whole accounts back. The listing
/// stays cheap because it reads files only, exactly as `listIdentities` does; the
/// credential store is worth a spawn for a single account and not for a table.
extension ClaudeTool: AIToolAccounts {

    func list() async throws -> [any Account] {
        let store = try ClaudeAccountStore()
        return try store.list().map { record in
            let account = ClaudeAccount(record: record, store: store)
            return account.withIdentity(
                ClaudeIdentity.fromFiles(in: store.configDir(for: record.id)))
        }
    }

    func current() async throws -> (any Account)? {
        let store = try ClaudeAccountStore()
        guard let record = try store.current() else { return nil }
        let account = ClaudeAccount(record: record, store: store)
        // A detail view, so the credential store is worth one spawn: an
        // in-session `/login` lands there before it lands anywhere else.
        return account.withIdentity(
            ClaudeIdentity.fresh(in: store.configDir(for: record.id)))
    }

    func addAccount(id: AccountID, name: String) async throws -> any Account {
        let store = try ClaudeAccountStore()
        let record = try store.add(id: id, name: name)
        // The config directory is created here because the account is not usable
        // without one, and the host must not be the thing that knows claude keeps
        // its state in a directory called `.claude`.
        try store.prepareConfigDir(for: id)
        return ClaudeAccount(record: record, store: store)
    }
}
