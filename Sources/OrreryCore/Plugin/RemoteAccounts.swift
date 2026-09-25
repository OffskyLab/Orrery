import Foundation
import AIToolKit

/// The account half of a remote tool, present only when its plugin advertised
/// every account method.
///
/// All five or none. A plugin that could list accounts but not delete one would
/// leave the host with a pool it can fill and never empty, and discovering that
/// at the first delete is worse than not offering the capability.
///
/// `AIToolKit.Account` is spelled out at every use because OrreryCore still has
/// an `Account` of its own — the one carrying `tool`, `displayName` and
/// `workspace`. Two types with one name is a transition state, not a design: the
/// host's copy goes when the `Tool` enum does. Until then the qualification is
/// what keeps it obvious which side of the boundary a value came from.
struct RemoteAccounts: AIToolAccounts {
    let description: ToolDescription
    let connection: JSONRPCConnection

    /// The methods a plugin must advertise for this capability to be present.
    static let requiredMethods: Set<String> = [
        "tool/list", "tool/current", "tool/setCurrent",
        "tool/addAccount", "tool/deleteAccount",
    ]

    var id: String { description.id }
    var displayName: String { description.displayName }
    var configDirectoryName: String { description.configDirectoryName }
    var configDirEnvVar: String? { description.configDirEnvVar }
    var authLoginCommand: [String]? { description.authLoginCommand }
    var installCommand: [String]? { description.installCommand }
    var sessionSubdirectories: [String] { description.sessionSubdirectories }
    var ansiColor: String { description.ansiColor }

    func list() async throws -> [AIToolKit.Account] {
        let result = try await connection.call("tool/list", nil)
        guard case .object(let obj) = result,
              case .array(let rows)? = obj["accounts"]
        else {
            throw RemoteAIToolError.describeMalformed("tool/list returned no 'accounts' array")
        }
        // An account that cannot be decoded is not skipped. A listing missing a
        // row looks complete, and the host would go on to offer a pool that is
        // quietly short of what the plugin holds.
        return try rows.map { row in
            guard let account = Self.decode(row) else {
                throw RemoteAIToolError.describeMalformed("tool/list returned an undecodable account")
            }
            return account
        }
    }

    func current() async throws -> AIToolKit.Account? {
        let result = try await connection.call("tool/current", nil)
        guard case .object(let obj) = result, let value = obj["account"] else {
            throw RemoteAIToolError.describeMalformed("tool/current returned no 'account' key")
        }
        // `.null` is "nothing pinned" — an answer a fresh install gives — so it
        // decodes to nil rather than throwing.
        return Self.decode(value)
    }

    func setCurrent(id: AccountID) async throws {
        _ = try await connection.call("tool/setCurrent", ["id": .string(id)])
    }

    func addAccount(id: AccountID, name: String) async throws -> AIToolKit.Account {
        let result = try await connection.call("tool/addAccount", [
            "id": .string(id),
            "name": .string(name),
        ])
        guard case .object(let obj) = result,
              let value = obj["account"],
              let account = Self.decode(value)
        else {
            throw RemoteAIToolError.describeMalformed("tool/addAccount returned no account")
        }
        return account
    }

    func deleteAccount(id: AccountID) async throws {
        _ = try await connection.call("tool/deleteAccount", ["id": .string(id)])
    }

    /// - Returns: nil for `.null`, which is an answer rather than a malformed
    ///   reply. A missing `id` or `name` is malformed: those two are what the
    ///   host asked for and cannot do without.
    private static func decode(_ value: RPCValue) -> AIToolKit.Account? {
        guard case .object(let fields) = value else { return nil }
        func string(_ key: String) -> String? {
            if case .string(let s)? = fields[key] { return s }
            return nil
        }
        guard let id = string("id"), let name = string("name") else { return nil }
        return AIToolKit.Account(id: id, name: name, email: string("email"), plan: string("plan"))
    }
}
