import Foundation
import AIToolKit

/// One of claude's accounts, able to act on itself.
///
/// A view onto the store rather than a value pulled out of it. That is what the
/// protocol asks for: an account can be pinned, designated and deleted, and a
/// detached copy would have nothing to do those *with* — which is why
/// `AccountRecord` deliberately does not conform.
///
/// The store is a value holding a root directory and no state of its own, so
/// carrying one costs nothing and every operation lands on disk where the next
/// process will find it.
struct ClaudeAccount: Account {
    let record: AccountRecord
    let store: ClaudeAccountStore

    var id: AccountID { record.id }
    var name: String { record.name }
    var email: String? { record.email }
    var plan: String? { record.plan }
    var workspace: String? { record.workspace }

    /// Written into this account's own metadata, so deleting the account takes
    /// the relation with it and no table is left holding a name for something
    /// that is gone.
    func pin(to workspace: String) async throws {
        try store.setWorkspace(workspace, for: record.id)
    }

    func makeCurrent() async throws {
        try store.setCurrent(id: record.id)
    }

    func delete() async throws {
        try store.delete(id: record.id)
    }

    /// The same account with whatever its config directory can say about who it
    /// belongs to.
    ///
    /// Identity is read here rather than stored, because claude writes it and
    /// this plugin only reports it. A recorded copy would be one more thing that
    /// can disagree with the file it came from.
    func withIdentity(_ record: ClaudeIdentity.Record) -> ClaudeAccount {
        ClaudeAccount(
            record: AccountRecord(
                id: self.record.id,
                name: self.record.name,
                email: record.email ?? self.record.email,
                plan: record.plan ?? self.record.plan,
                workspace: self.record.workspace),
            store: store)
    }
}
