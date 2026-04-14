import Foundation

public struct SessionMappingEntry: Codable {
    public let tool: String
    public let nativeSessionId: String?
    public let lastUsed: String

    public init(tool: String, nativeSessionId: String?, lastUsed: String) {
        self.tool = tool
        self.nativeSessionId = nativeSessionId
        self.lastUsed = lastUsed
    }
}

public struct SessionTurn: Codable {
    public let role: String
    public let content: String
    public let timestamp: String
    public let tokenEstimate: Int

    enum CodingKeys: String, CodingKey {
        case role, content, timestamp
        case tokenEstimate = "token_estimate"
    }

    public init(role: String, content: String, timestamp: String, tokenEstimate: Int) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.tokenEstimate = tokenEstimate
    }
}

public struct SessionMapping {
    public let baseDir: URL

    public init(store: EnvironmentStore) {
        self.baseDir = store.homeURL.appendingPathComponent("sessions")
    }

    public func mappingFile(name: String, cwd: String) -> URL {
        let projectKey = cwd.replacingOccurrences(of: "/", with: "-")
        return baseDir
            .appendingPathComponent(projectKey)
            .appendingPathComponent("\(name).json")
    }

    public func codexHistoryFile(name: String, cwd: String) -> URL {
        let projectKey = cwd.replacingOccurrences(of: "/", with: "-")
        return baseDir
            .appendingPathComponent(projectKey)
            .appendingPathComponent("\(name).codex.jsonl")
    }

    public func load(name: String, cwd: String) -> SessionMappingEntry? {
        let file = mappingFile(name: name, cwd: cwd)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SessionMappingEntry.self, from: data)
    }

    public func save(_ entry: SessionMappingEntry, name: String, cwd: String) throws {
        let file = mappingFile(name: name, cwd: cwd)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entry)
        try data.write(to: file)
    }

    public func loadCodexTurns(name: String, cwd: String) -> [SessionTurn] {
        let file = codexHistoryFile(name: name, cwd: cwd)
        guard let data = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return data.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .compactMap { line in
                try? JSONDecoder().decode(SessionTurn.self, from: Data(line.utf8))
            }
    }

    public func appendCodexTurn(_ turn: SessionTurn, name: String, cwd: String) throws {
        let file = codexHistoryFile(name: name, cwd: cwd)
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let json = try JSONEncoder().encode(turn)
        let line = String(data: json, encoding: .utf8)! + "\n"

        if FileManager.default.fileExists(atPath: file.path) {
            let handle = try FileHandle(forWritingTo: file)
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try line.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
