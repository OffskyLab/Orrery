import Foundation

public struct OrbitalEnvironment: Codable, Sendable {
    public var name: String
    public var description: String
    public var createdAt: Date
    public var lastUsed: Date
    public var tools: [Tool]
    public var env: [String: String]

    public init(
        name: String,
        description: String = "",
        createdAt: Date = Date(),
        lastUsed: Date = Date(),
        tools: [Tool] = [],
        env: [String: String] = [:]
    ) {
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.lastUsed = lastUsed
        self.tools = tools
        self.env = env
    }
}
