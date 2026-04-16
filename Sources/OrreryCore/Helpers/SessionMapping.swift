import Foundation

public struct SessionMappingEntry: Codable {
    public let tool: String
    public let nativeSessionId: String?
    public let lastUsed: String
    public let summary: String?

    public init(tool: String, nativeSessionId: String?, lastUsed: String, summary: String? = nil) {
        self.tool = tool
        self.nativeSessionId = nativeSessionId
        self.lastUsed = lastUsed
        self.summary = summary
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

    public func allMappings(cwd: String) -> [(name: String, entry: SessionMappingEntry)] {
        let projectKey = cwd.replacingOccurrences(of: "/", with: "-")
        let dir = baseDir.appendingPathComponent(projectKey)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { file -> (String, SessionMappingEntry)? in
                guard let data = try? Data(contentsOf: file),
                      let entry = try? JSONDecoder().decode(SessionMappingEntry.self, from: data)
                else { return nil }
                let name = file.deletingPathExtension().lastPathComponent
                return (name, entry)
            }
            .sorted { $0.1.lastUsed > $1.1.lastUsed }
    }
}
