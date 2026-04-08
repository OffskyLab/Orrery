import Foundation

public struct EnvironmentStore: Sendable {
    public enum Error: Swift.Error {
        case environmentNotFound(String)
        case invalidEnvironmentName(String)
    }

    public let homeURL: URL

    public init(homeURL: URL) {
        self.homeURL = homeURL
    }

    public static var `default`: EnvironmentStore {
        let home: URL
        if let custom = ProcessInfo.processInfo.environment["ORBITAL_HOME"] {
            home = URL(fileURLWithPath: custom)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".orbital")
        }
        return EnvironmentStore(homeURL: home)
    }

    private var envsURL: URL { homeURL.appendingPathComponent("envs") }
    private var currentURL: URL { homeURL.appendingPathComponent("current") }

    // Directory for an environment, keyed by UUID
    private func envURL(id: String) -> URL {
        envsURL.appendingPathComponent(id)
    }

    private func envJSONURL(id: String) -> URL {
        envURL(id: id).appendingPathComponent("env.json")
    }

    // Scan all UUID dirs and find the one whose env.json has the given name
    private func resolveID(for name: String) throws -> String {
        guard FileManager.default.fileExists(atPath: envsURL.path) else {
            throw Error.environmentNotFound(name)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dirs = try FileManager.default.contentsOfDirectory(atPath: envsURL.path)
        for dir in dirs {
            let jsonURL = envsURL.appendingPathComponent(dir).appendingPathComponent("env.json")
            guard FileManager.default.fileExists(atPath: jsonURL.path) else { continue }
            if let data = try? Data(contentsOf: jsonURL),
               let env = try? decoder.decode(OrbitalEnvironment.self, from: data),
               env.name == name {
                return dir
            }
        }
        throw Error.environmentNotFound(name)
    }

    public func save(_ environment: OrbitalEnvironment) throws {
        let dir = envURL(id: environment.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(environment)
        try data.write(to: envJSONURL(id: environment.id))
    }

    public func load(named name: String) throws -> OrbitalEnvironment {
        let id = try resolveID(for: name)
        let data = try Data(contentsOf: envJSONURL(id: id))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OrbitalEnvironment.self, from: data)
    }

    public func listNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: envsURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dirs = try FileManager.default.contentsOfDirectory(atPath: envsURL.path)
        return dirs.compactMap { dir -> String? in
            let jsonURL = envsURL.appendingPathComponent(dir).appendingPathComponent("env.json")
            guard let data = try? Data(contentsOf: jsonURL),
                  let env = try? decoder.decode(OrbitalEnvironment.self, from: data)
            else { return nil }
            return env.name
        }
    }

    public func delete(named name: String) throws {
        let id = try resolveID(for: name)
        try FileManager.default.removeItem(at: envURL(id: id))
    }

    public func setCurrent(_ name: String?) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        if let name {
            try name.write(to: currentURL, atomically: true, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: currentURL.path) {
            try FileManager.default.removeItem(at: currentURL)
        }
    }

    public func current() throws -> String? {
        guard FileManager.default.fileExists(atPath: currentURL.path) else { return nil }
        let content = try String(contentsOf: currentURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    public func addTool(_ tool: Tool, to envName: String) throws {
        var env = try load(named: envName)
        let toolDir = toolConfigDir(tool: tool, environment: envName)
        try FileManager.default.createDirectory(at: toolDir, withIntermediateDirectories: true)
        if !env.tools.contains(tool) {
            env.tools.append(tool)
            try save(env)
        }
    }

    public func removeTool(_ tool: Tool, from envName: String) throws {
        var env = try load(named: envName)
        let toolDir = toolConfigDir(tool: tool, environment: envName)
        if FileManager.default.fileExists(atPath: toolDir.path) {
            try FileManager.default.removeItem(at: toolDir)
        }
        env.tools.removeAll { $0 == tool }
        try save(env)
    }

    public func toolConfigDir(tool: Tool, environment envName: String) -> URL {
        // We need the UUID for the env — if not found, fall back gracefully
        let id = (try? resolveID(for: envName)) ?? envName
        return envURL(id: id).appendingPathComponent(tool.subdirectory)
    }

    public func rename(from oldName: String, to newName: String) throws {
        var env = try load(named: oldName)
        env.name = newName
        try save(env)

        if let currentName = try current(), currentName == oldName {
            try setCurrent(newName)
        }
    }
}
