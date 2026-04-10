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
    private var sharedURL: URL { homeURL.appendingPathComponent("shared") }

    /// Returns the shared directory for a tool (e.g. `~/.orbital/shared/claude/`)
    public func sharedSessionDir(tool: Tool) -> URL {
        sharedURL.appendingPathComponent(tool.subdirectory)
    }

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

        if !env.isolateSessions {
            try linkSharedSessionDirs(tool: tool, toolDir: toolDir)
        }

        if !env.tools.contains(tool) {
            env.tools.append(tool)
            try save(env)
        }
    }

    /// Ensures shared session symlinks exist for a tool in the given environment.
    /// Called lazily on `orbital use` to migrate existing environments.
    public func ensureSharedSessionLinks(tool: Tool, environment envName: String) throws {
        let toolDir = toolConfigDir(tool: tool, environment: envName)
        try linkSharedSessionDirs(tool: tool, toolDir: toolDir)
    }

    /// Creates symlinks from the tool's session subdirectories to a shared location.
    /// Shared path: `~/.orbital/shared/<tool>/<subdir>/`
    private func linkSharedSessionDirs(tool: Tool, toolDir: URL) throws {
        let fm = FileManager.default
        for subdir in tool.sessionSubdirectories {
            let sharedDir = sharedURL.appendingPathComponent(tool.subdirectory)
                .appendingPathComponent(subdir)
            try fm.createDirectory(at: sharedDir, withIntermediateDirectories: true)

            let linkPath = toolDir.appendingPathComponent(subdir)
            // Skip if already a symlink pointing to the correct target
            if let dest = try? fm.destinationOfSymbolicLink(atPath: linkPath.path),
               dest == sharedDir.path {
                continue
            }
            // If a real directory already exists, move its contents to shared first
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: linkPath.path, isDirectory: &isDir), isDir.boolValue {
                let contents = try fm.contentsOfDirectory(atPath: linkPath.path)
                for item in contents {
                    let src = linkPath.appendingPathComponent(item)
                    let dst = sharedDir.appendingPathComponent(item)
                    if !fm.fileExists(atPath: dst.path) {
                        try fm.moveItem(at: src, to: dst)
                    }
                }
                try fm.removeItem(at: linkPath)
            }
            try fm.createSymbolicLink(at: linkPath, withDestinationURL: sharedDir)
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

    public func envDir(for envName: String) throws -> URL {
        let id = try resolveID(for: envName)
        return envURL(id: id)
    }

    public func toolConfigDir(tool: Tool, environment envName: String) -> URL {
        // We need the UUID for the env — if not found, fall back gracefully
        let id = (try? resolveID(for: envName)) ?? envName
        return envURL(id: id).appendingPathComponent(tool.subdirectory)
    }

    // MARK: - Memory path helpers

    /// Shared memory dir for a project: `~/.orbital/shared/memory/{projectKey}/`
    public func sharedMemoryDir(projectKey: String) -> URL {
        homeURL
            .appendingPathComponent("shared")
            .appendingPathComponent("memory")
            .appendingPathComponent(projectKey)
    }

    /// Isolated memory dir for a specific env: `~/.orbital/shared/memory/{projectKey}/{envName}/`
    public func isolatedMemoryDir(projectKey: String, envName: String) -> URL {
        sharedMemoryDir(projectKey: projectKey).appendingPathComponent(envName)
    }

    /// Returns the correct ORBITAL_MEMORY.md URL for the given env (nil = default/shared).
    public func memoryFile(projectKey: String, envName: String?) -> URL {
        let dir: URL
        if let envName, envName != ReservedEnvironment.defaultName,
           let env = try? load(named: envName), env.isolateMemory {
            dir = isolatedMemoryDir(projectKey: projectKey, envName: envName)
        } else {
            dir = sharedMemoryDir(projectKey: projectKey)
        }
        return dir.appendingPathComponent("ORBITAL_MEMORY.md")
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
