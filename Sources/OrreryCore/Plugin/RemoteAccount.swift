import Foundation
import AIToolKit

/// One of a remote tool's accounts, holding the connection back to it.
///
/// A decoded reply is an `AccountRecord` and stops there — a value has nothing to
/// pin, designate or delete *with*, which is why the record deliberately does not
/// conform to `Account`. This is the type that does: the same fields, plus the
/// pipe the operations travel down.
///
/// So a call site holding `any Account` cannot tell whether the account came from
/// a plugin process or from a tool compiled in, which is the same claim
/// `RemoteAITool` makes one level up.
///
/// `AIToolKit.Account` is spelled out because OrreryCore still has an `Account`
/// of its own — the one with `tool`, `displayName` and `workspace`. Two types
/// with one name is a transition state: the host's copy goes when the `Tool` enum
/// does, and until then the qualification says which side a value came from.
struct RemoteAccount: AIToolKit.Account {
    let record: AccountRecord
    let connection: JSONRPCConnection

    var id: AccountID { record.id }
    var name: String { record.name }
    var email: String? { record.email }
    var plan: String? { record.plan }
    var workspace: String? { record.workspace }

    /// The wire still names the account, because a request has to say which one.
    /// The protocol does not, because the caller is holding it — so the id comes
    /// off `self` rather than out of a parameter nobody could get wrong.
    func pin(to workspace: String) async throws {
        _ = try await connection.call("tool/pin", [
            "id": .string(record.id),
            "workspace": .string(workspace),
        ])
    }

    func makeCurrent() async throws {
        _ = try await connection.call("tool/setCurrent", ["id": .string(record.id)])
    }

    func delete() async throws {
        _ = try await connection.call("tool/deleteAccount", ["id": .string(record.id)])
    }

    /// The directory is sent as a path because that is all it is to this side.
    /// What the plugin finds in it — a file, an entry in a keychain the path only
    /// names — is not orrery's to know, which is why nothing is read here first.
    func adoptLogin(from directory: URL) async throws {
        _ = try await connection.call("tool/adoptLogin", [
            "id": .string(record.id),
            "directory": .string(directory.path),
        ])
    }
}
