import Foundation

public struct AccountStore: Sendable {
    public enum Error: Swift.Error {
        case accountNotFound(id: String, tool: Tool)
        case invalidAccountName(String)
    }

    public let homeURL: URL

    public init(homeURL: URL) {
        self.homeURL = homeURL
    }

    public static var `default`: AccountStore {
        AccountStore(homeURL: EnvironmentStore.default.homeURL)
    }

    // MARK: - Paths

    public func accountsRoot() -> URL {
        homeURL.appendingPathComponent("accounts")
    }

    public func toolDir(_ tool: Tool) -> URL {
        accountsRoot().appendingPathComponent(tool.rawValue)
    }

    public func accountDir(id: AccountID, tool: Tool) -> URL {
        toolDir(tool).appendingPathComponent(id)
    }

    private func metadataURL(id: AccountID, tool: Tool) -> URL {
        accountDir(id: id, tool: tool).appendingPathComponent("metadata.json")
    }

    // MARK: - CRUD

    public func save(_ account: Account) throws {
        let dir = accountDir(id: account.id, tool: account.tool)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(account)
        try data.write(to: metadataURL(id: account.id, tool: account.tool), options: .atomic)
    }

    public func load(id: AccountID, tool: Tool) throws -> Account {
        let url = metadataURL(id: id, tool: tool)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.accountNotFound(id: id, tool: tool)
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Account.self, from: data)
    }

    public func list(tool: Tool) throws -> [Account] {
        let dir = toolDir(tool)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let ids = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        return ids.compactMap { try? load(id: $0, tool: tool) }
            .sorted { $0.displayName < $1.displayName }
    }

    public func listAll() throws -> [Tool: [Account]] {
        var result: [Tool: [Account]] = [:]
        for tool in Tool.allCases {
            let accts = try list(tool: tool)
            if !accts.isEmpty {
                result[tool] = accts
            }
        }
        return result
    }

    public func delete(id: AccountID, tool: Tool) throws {
        let dir = accountDir(id: id, tool: tool)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw Error.accountNotFound(id: id, tool: tool)
        }
        try FileManager.default.removeItem(at: dir)
    }

    public func findByDisplayName(_ name: String, tool: Tool) throws -> Account? {
        try list(tool: tool).first { $0.displayName == name }
    }
}
