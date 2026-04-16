import Foundation

public enum ReservedEnvironment {
    public static let defaultName = "origin"
}

/// Persisted settings for the reserved `origin` environment.
/// Stored at `~/.orrery/origin/config.json`.
public struct OriginConfig: Codable, Sendable {
    public var isolateMemory: Bool
    public var memoryStoragePath: String?

    public init(isolateMemory: Bool = false, memoryStoragePath: String? = nil) {
        self.isolateMemory = isolateMemory
        self.memoryStoragePath = memoryStoragePath
    }
}

public struct OrreryEnvironment: Codable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var createdAt: Date
    public var lastUsed: Date
    public var tools: [Tool]
    public var env: [String: String]
    /// Tools in this env whose sessions are isolated (not symlinked to shared).
    /// Tools NOT in this set share sessions across envs (the default).
    public var isolatedSessionTools: Set<Tool>
    public var isolateMemory: Bool
    /// Custom storage root for memory. When set, MEMORY.md and fragments/ live here
    /// instead of the default ~/.orrery path. Useful for external wikis (e.g. Obsidian).
    public var memoryStoragePath: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        createdAt: Date = Date(),
        lastUsed: Date = Date(),
        tools: [Tool] = [],
        env: [String: String] = [:],
        isolatedSessionTools: Set<Tool> = [],
        isolateMemory: Bool = true,
        memoryStoragePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.lastUsed = lastUsed
        self.tools = tools
        self.env = env
        self.isolatedSessionTools = isolatedSessionTools
        self.isolateMemory = isolateMemory
        self.memoryStoragePath = memoryStoragePath
    }

    /// Whether sessions for `tool` are isolated in this env.
    public func isolateSessions(for tool: Tool) -> Bool {
        isolatedSessionTools.contains(tool)
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, name, description, createdAt, lastUsed, tools, env
        case isolatedSessionTools
        case isolateSessions  // legacy — decode only
        case isolateMemory, memoryStoragePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastUsed = try c.decode(Date.self, forKey: .lastUsed)
        tools = try c.decode([Tool].self, forKey: .tools)
        env = try c.decode([String: String].self, forKey: .env)

        if let newField = try c.decodeIfPresent(Set<Tool>.self, forKey: .isolatedSessionTools) {
            isolatedSessionTools = newField
        } else if (try c.decodeIfPresent(Bool.self, forKey: .isolateSessions)) == true {
            // Legacy: old `isolateSessions: true` → isolate all current tools.
            isolatedSessionTools = Set(tools)
        } else {
            isolatedSessionTools = []
        }

        isolateMemory = try c.decodeIfPresent(Bool.self, forKey: .isolateMemory) ?? false
        memoryStoragePath = try c.decodeIfPresent(String.self, forKey: .memoryStoragePath)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(lastUsed, forKey: .lastUsed)
        try c.encode(tools, forKey: .tools)
        try c.encode(env, forKey: .env)
        try c.encode(isolatedSessionTools, forKey: .isolatedSessionTools)
        try c.encode(isolateMemory, forKey: .isolateMemory)
        try c.encodeIfPresent(memoryStoragePath, forKey: .memoryStoragePath)
    }
}
