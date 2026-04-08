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

    /// Default store reading ORBITAL_HOME env var, falling back to ~/.orbital
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

    private func envURL(name: String) -> URL {
        envsURL.appendingPathComponent(name)
    }

    private func envJSONURL(name: String) -> URL {
        envURL(name: name).appendingPathComponent("env.json")
    }

    public func save(_ environment: OrbitalEnvironment) throws {
        let dir = envURL(name: environment.name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(environment)
        try data.write(to: envJSONURL(name: environment.name))
    }

    public func load(named name: String) throws -> OrbitalEnvironment {
        let url = envJSONURL(name: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.environmentNotFound(name)
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OrbitalEnvironment.self, from: data)
    }

    public func listNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: envsURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: envsURL.path)
            .filter { name in
                var isDir: ObjCBool = false
                let path = envsURL.appendingPathComponent(name).path
                FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                return isDir.boolValue
            }
    }

    public func delete(named name: String) throws {
        let dir = envURL(name: name)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw Error.environmentNotFound(name)
        }
        try FileManager.default.removeItem(at: dir)
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
        let content = try String(contentsOf: currentURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
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

    public func toolConfigDir(tool: Tool, environment: String) -> URL {
        envURL(name: environment).appendingPathComponent(tool.subdirectory)
    }
}
