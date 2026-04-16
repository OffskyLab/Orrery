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
        if let custom = ProcessInfo.processInfo.environment["ORRERY_HOME"] {
            home = URL(fileURLWithPath: custom)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".orrery")
        }
        return EnvironmentStore(homeURL: home)
    }

    private var envsURL: URL { homeURL.appendingPathComponent("envs") }
    private var currentURL: URL { homeURL.appendingPathComponent("current") }
    private var sharedURL: URL { homeURL.appendingPathComponent("shared") }

    /// Returns the shared directory for a tool (e.g. `~/.orrery/shared/claude/`)
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
               let env = try? decoder.decode(OrreryEnvironment.self, from: data),
               env.name == name {
                return dir
            }
        }
        throw Error.environmentNotFound(name)
    }

    public func save(_ environment: OrreryEnvironment) throws {
        let dir = envURL(id: environment.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(environment)
        try data.write(to: envJSONURL(id: environment.id))
    }

    public func load(named name: String) throws -> OrreryEnvironment {
        let id = try resolveID(for: name)
        let data = try Data(contentsOf: envJSONURL(id: id))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OrreryEnvironment.self, from: data)
    }

    public func listNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: envsURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dirs = try FileManager.default.contentsOfDirectory(atPath: envsURL.path)
        return dirs.compactMap { dir -> String? in
            let jsonURL = envsURL.appendingPathComponent(dir).appendingPathComponent("env.json")
            guard let data = try? Data(contentsOf: jsonURL),
                  let env = try? decoder.decode(OrreryEnvironment.self, from: data)
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

        if !env.isolateSessions(for: tool) {
            try linkSharedSessionDirs(tool: tool, toolDir: toolDir)
        }

        if tool == .gemini {
            try ensureGeminiHomeWrapper(envName: envName)
        }

        if !env.tools.contains(tool) {
            env.tools.append(tool)
            try save(env)
        }
    }

    /// Ensures shared session symlinks exist for a tool in the given environment.
    /// Called lazily on `orrery use` to migrate existing environments.
    public func ensureSharedSessionLinks(tool: Tool, environment envName: String) throws {
        let toolDir = toolConfigDir(tool: tool, environment: envName)
        try linkSharedSessionDirs(tool: tool, toolDir: toolDir)
    }

    /// Per-env fake HOME for gemini. gemini-cli ignores `GEMINI_CONFIG_DIR`
    /// and always reads `~/.gemini/`, so isolation is achieved by setting
    /// HOME to this dir (via the shell wrapper / delegate process env).
    /// Layout: `<env>/gemini-home/.gemini/` is a symlink to `<env>/gemini/`,
    /// so the existing config dir stays where everything else expects it.
    public func geminiHomeDir(environment envName: String) -> URL {
        let id = (try? resolveID(for: envName)) ?? envName
        return envURL(id: id).appendingPathComponent("gemini-home")
    }

    /// Idempotent setup of the gemini home wrapper for an env: creates the
    /// `gemini-home` dir and the `.gemini` → `../gemini` symlink. Safe to call
    /// repeatedly (used both by addTool and lazily on `orrery use`).
    public func ensureGeminiHomeWrapper(envName: String) throws {
        let fm = FileManager.default
        let homeDir = geminiHomeDir(environment: envName)
        let configDir = toolConfigDir(tool: .gemini, environment: envName)
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: homeDir, withIntermediateDirectories: true)

        let link = homeDir.appendingPathComponent(".gemini")
        // Already correctly symlinked → done
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path),
           dest == "../gemini" || dest == configDir.path {
            return
        }
        // Wrong symlink or real dir at link path → remove first
        if fm.fileExists(atPath: link.path) ||
           (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try fm.removeItem(at: link)
        }
        // Create as relative symlink so the env dir stays portable
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../gemini")
    }

    /// Creates symlinks from the tool's session subdirectories to a shared location.
    /// Shared path: `~/.orrery/shared/<tool>/<subdir>/`
    ///
    /// Handles three starting states:
    /// - Already correctly symlinked → no-op.
    /// - Symlink pointing somewhere else (e.g. stale post-migration pointer into
    ///   `~/.orbital/shared/`) → remove and recreate.
    /// - Real directory (fresh env) → move contents to shared, remove, recreate as symlink.
    private func linkSharedSessionDirs(tool: Tool, toolDir: URL) throws {
        let fm = FileManager.default
        for subdir in tool.sessionSubdirectories {
            let sharedDir = sharedURL.appendingPathComponent(tool.subdirectory)
                .appendingPathComponent(subdir)
            try fm.createDirectory(at: sharedDir, withIntermediateDirectories: true)

            let linkPath = toolDir.appendingPathComponent(subdir)

            // Already correctly symlinked — done.
            if let dest = try? fm.destinationOfSymbolicLink(atPath: linkPath.path),
               dest == sharedDir.path {
                continue
            }

            // Symlink pointing elsewhere (or dangling). `destinationOfSymbolicLink`
            // only succeeds for symlinks, so this distinguishes them from real dirs.
            if (try? fm.destinationOfSymbolicLink(atPath: linkPath.path)) != nil {
                try fm.removeItem(at: linkPath)
            } else {
                // Real directory — migrate its contents into shared, then remove.
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: linkPath.path, isDirectory: &isDir), isDir.boolValue {
                    let contents = (try? fm.contentsOfDirectory(atPath: linkPath.path)) ?? []
                    for item in contents {
                        let src = linkPath.appendingPathComponent(item)
                        let dst = sharedDir.appendingPathComponent(item)
                        if !fm.fileExists(atPath: dst.path) {
                            try fm.moveItem(at: src, to: dst)
                        }
                    }
                    try fm.removeItem(at: linkPath)
                }
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

    /// Shared memory dir for a project: `~/.orrery/shared/memory/{projectKey}/`
    public func sharedMemoryDir(projectKey: String) -> URL {
        homeURL
            .appendingPathComponent("shared")
            .appendingPathComponent("memory")
            .appendingPathComponent(projectKey)
    }

    /// Isolated memory dir for a specific env: `~/.orrery/shared/memory/{projectKey}/{envName}/`
    public func isolatedMemoryDir(projectKey: String, envName: String) -> URL {
        sharedMemoryDir(projectKey: projectKey).appendingPathComponent(envName)
    }

    /// Returns the memory directory URL for the given env (nil = default/shared).
    /// Priority: custom memoryStoragePath > isolateMemory > shared default.
    /// The directory is symlinked into Claude's auto-memory dir so `MEMORY.md` +
    /// fragment files written by any tool land here and can be synced across machines.
    public func memoryDir(projectKey: String, envName: String?) -> URL {
        if let envName, envName != ReservedEnvironment.defaultName,
           let env = try? load(named: envName) {
            if let storagePath = env.memoryStoragePath {
                return URL(fileURLWithPath: storagePath)
            }
            if env.isolateMemory {
                return isolatedMemoryDir(projectKey: projectKey, envName: envName)
            }
        }
        return sharedMemoryDir(projectKey: projectKey)
    }

    /// Symlink Claude's memory directory for the given project to the orrery shared memory dir.
    /// This makes ALL of Claude's auto-memory writes land in the orrery shared location,
    /// which orrery-sync can then replicate across machines.
    /// `claudeConfigDir` is either toolConfigDir(.claude, env) or CLAUDE_CONFIG_DIR env var.
    public func linkOrreryMemory(projectKey: String, envName: String, claudeConfigDir: URL) {
        let targetDir = memoryDir(projectKey: projectKey, envName: envName)
        let memoryDirURL = claudeConfigDir
            .appendingPathComponent("projects")
            .appendingPathComponent(projectKey)
            .appendingPathComponent("memory")
        let fm = FileManager.default

        // Ensure orrery target directory exists
        try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        // Already correctly symlinked — nothing to do
        if let existing = try? fm.destinationOfSymbolicLink(atPath: memoryDirURL.path),
           existing == targetDir.path {
            return
        }

        // Existing symlink pointing elsewhere — remove it
        if let _ = try? fm.destinationOfSymbolicLink(atPath: memoryDirURL.path) {
            try? fm.removeItem(at: memoryDirURL)
        } else {
            // Real directory — migrate contents into orrery dir, then remove
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: memoryDirURL.path, isDirectory: &isDir), isDir.boolValue {
                let contents = (try? fm.contentsOfDirectory(atPath: memoryDirURL.path)) ?? []
                for item in contents {
                    let src = memoryDirURL.appendingPathComponent(item)
                    let dst = targetDir.appendingPathComponent(item)
                    if !fm.fileExists(atPath: dst.path) {
                        try? fm.moveItem(at: src, to: dst)
                    }
                }
                try? fm.removeItem(at: memoryDirURL)
            }
        }

        // Ensure parent directory exists
        try? fm.createDirectory(at: memoryDirURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: memoryDirURL, withDestinationURL: targetDir)
    }

    // MARK: - Origin management

    /// Storage directory for origin tool configs: `~/.orrery/origin/`
    public var originDir: URL { homeURL.appendingPathComponent("origin") }

    /// Per-tool storage path inside origin: `~/.orrery/origin/{tool}/`
    public func originConfigDir(tool: Tool) -> URL {
        originDir.appendingPathComponent(tool.subdirectory)
    }

    /// Marker file that suppresses automatic origin takeover.
    /// Written by `orrery origin release` / `orrery uninstall`.
    /// Deleted by `orrery origin takeover` / `orrery setup`.
    public var originTakeoverOptOutMarker: URL {
        homeURL.appendingPathComponent(".no-origin-takeover")
    }

    public var isOriginTakeoverOptedOut: Bool {
        FileManager.default.fileExists(atPath: originTakeoverOptOutMarker.path)
    }

    public func setOriginTakeoverOptOut(_ optOut: Bool) {
        let fm = FileManager.default
        if optOut {
            try? fm.createDirectory(at: homeURL, withIntermediateDirectories: true)
            fm.createFile(atPath: originTakeoverOptOutMarker.path, contents: nil)
        } else {
            try? fm.removeItem(at: originTakeoverOptOutMarker)
        }
    }

    /// Returns true if `tool.defaultConfigDir` is a symlink pointing to orrery's origin storage.
    public func isOriginManaged(tool: Tool) -> Bool {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(
            atPath: tool.defaultConfigDir.path
        ) else { return false }
        let target = originConfigDir(tool: tool)
        // Accept both absolute and relative dest paths
        return dest == target.path ||
               URL(fileURLWithPath: dest, relativeTo: tool.defaultConfigDir.deletingLastPathComponent()) == target
    }

    /// Move `tool.defaultConfigDir` into orrery origin storage and replace it with a symlink.
    /// Idempotent — no-op if already managed. Clears the opt-out marker.
    public func originTakeover(tool: Tool) throws {
        setOriginTakeoverOptOut(false)
        guard !isOriginManaged(tool: tool) else { return }
        let fm = FileManager.default
        let src = tool.defaultConfigDir
        let dst = originConfigDir(tool: tool)

        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)

        var srcIsDir: ObjCBool = false
        if fm.fileExists(atPath: src.path, isDirectory: &srcIsDir) {
            if fm.fileExists(atPath: dst.path) {
                // dst already exists — merge src contents in, then remove src
                if srcIsDir.boolValue {
                    let contents = (try? fm.contentsOfDirectory(atPath: src.path)) ?? []
                    for item in contents {
                        let srcItem = src.appendingPathComponent(item)
                        let dstItem = dst.appendingPathComponent(item)
                        if !fm.fileExists(atPath: dstItem.path) {
                            try fm.moveItem(at: srcItem, to: dstItem)
                        }
                    }
                }
                try fm.removeItem(at: src)
            } else {
                try fm.moveItem(at: src, to: dst)
            }
        } else {
            // No existing config — just create the target dir so the tool has somewhere to write
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        }

        try fm.createSymbolicLink(at: src, withDestinationURL: dst)
    }

    /// Remove the symlink and move data back to `tool.defaultConfigDir`.
    /// Idempotent — no-op if not managed. Sets the opt-out marker so orrery
    /// won't auto-takeover on the next invocation.
    public func originRelease(tool: Tool) throws {
        setOriginTakeoverOptOut(true)
        guard isOriginManaged(tool: tool) else { return }
        let fm = FileManager.default
        let link = tool.defaultConfigDir
        let stored = originConfigDir(tool: tool)

        try fm.removeItem(at: link)
        if fm.fileExists(atPath: stored.path) {
            try fm.moveItem(at: stored, to: link)
        }
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
