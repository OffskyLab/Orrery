import Foundation
import AIToolKit

/// The account half of a remote tool, present only when its plugin advertised
/// every account method.
///
/// All of them or none. A plugin that could list accounts but not delete one
/// would leave the host with a pool it can fill and never empty, and discovering
/// that at the first delete is worse than not offering the capability.
///
/// What is here is what only the tool can answer. Pinning, designating and
/// deleting are on ``RemoteAccount``, which carries the connection, because they
/// are things done to an account the caller is already holding.
struct RemoteAccounts: AIToolAccounts {
    let description: ToolDescription
    let connection: JSONRPCConnection

    /// The methods a plugin must advertise for this capability to be present.
    static let requiredMethods: Set<String> = [
        "tool/list", "tool/current", "tool/setCurrent",
        "tool/addAccount", "tool/deleteAccount", "tool/pin", "tool/adoptLogin",
    ]

    var id: String { description.id }
    var displayName: String { description.displayName }
    var configDirectoryName: String { description.configDirectoryName }
    var configDirEnvVar: String? { description.configDirEnvVar }
    var authLoginCommand: [String]? { description.authLoginCommand }
    var installCommand: [String]? { description.installCommand }
    var sessionSubdirectories: [String] { description.sessionSubdirectories }
    var ansiColor: String { description.ansiColor }

    func list() async throws -> [any AIToolKit.Account] {
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
            guard let record = Self.decode(row) else {
                throw RemoteAIToolError.describeMalformed("tool/list returned an undecodable account")
            }
            return RemoteAccount(record: record, connection: connection)
        }
    }

    func current() async throws -> (any AIToolKit.Account)? {
        let result = try await connection.call("tool/current", nil)
        guard case .object(let obj) = result, let value = obj["account"] else {
            throw RemoteAIToolError.describeMalformed("tool/current returned no 'account' key")
        }
        // `.null` is "nothing designated" — an answer a fresh install gives — so
        // it decodes to nil rather than throwing.
        guard let record = Self.decode(value) else { return nil }
        return RemoteAccount(record: record, connection: connection)
    }

    func addAccount(id: AccountID, name: String) async throws -> any AIToolKit.Account {
        let result = try await connection.call("tool/addAccount", [
            "id": .string(id),
            "name": .string(name),
        ])
        guard case .object(let obj) = result,
              let value = obj["account"],
              let record = Self.decode(value)
        else {
            throw RemoteAIToolError.describeMalformed("tool/addAccount returned no account")
        }
        return RemoteAccount(record: record, connection: connection)
    }

    /// - Returns: nil for `.null`, which is an answer rather than a malformed
    ///   reply. A missing `id` or `name` is malformed: those two are what the
    ///   host asked for and cannot do without.
    private static func decode(_ value: RPCValue) -> AccountRecord? {
        guard case .object(let fields) = value else { return nil }
        func string(_ key: String) -> String? {
            if case .string(let s)? = fields[key] { return s }
            return nil
        }
        guard let id = string("id"), let name = string("name") else { return nil }
        return AccountRecord(id: id, name: name, email: string("email"),
                             plan: string("plan"), workspace: string("workspace"))
    }
}
