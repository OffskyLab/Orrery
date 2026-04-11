import Foundation

public enum ReservedEnvironment {
    public static let defaultName = "origin"
}

public struct OrbitalEnvironment: Codable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var createdAt: Date
    public var lastUsed: Date
    public var tools: [Tool]
    public var env: [String: String]
    public var isolateSessions: Bool
    public var isolateMemory: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        createdAt: Date = Date(),
        lastUsed: Date = Date(),
        tools: [Tool] = [],
        env: [String: String] = [:],
        isolateSessions: Bool = false,
        isolateMemory: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.lastUsed = lastUsed
        self.tools = tools
        self.env = env
        self.isolateSessions = isolateSessions
        self.isolateMemory = isolateMemory
    }

    // Custom decoding for backward compatibility with existing env.json files
    enum CodingKeys: String, CodingKey {
        case id, name, description, createdAt, lastUsed, tools, env, isolateSessions, isolateMemory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastUsed = try container.decode(Date.self, forKey: .lastUsed)
        tools = try container.decode([Tool].self, forKey: .tools)
        env = try container.decode([String: String].self, forKey: .env)
        isolateSessions = try container.decodeIfPresent(Bool.self, forKey: .isolateSessions) ?? false
        isolateMemory = try container.decodeIfPresent(Bool.self, forKey: .isolateMemory) ?? false
    }
}
