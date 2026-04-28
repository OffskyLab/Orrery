import ArgumentParser
import Foundation

public struct SessionResolver {
    public static func resolve(
        _ specifier: SessionSpecifier,
        tool: Tool,
        cwd: String,
        store: EnvironmentStore,
        activeEnvironment: String?
    ) throws -> SessionsCommand.SessionEntry {
        let entries = findScopedSessions(tool: tool, cwd: cwd, store: store, activeEnvironment: activeEnvironment)
            .sorted { ($0.lastTime ?? .distantPast) > ($1.lastTime ?? .distantPast) }

        switch specifier {
        case .last:
            guard let first = entries.first else {
                throw ValidationError(L10n.Delegate.resumeNotFound)
            }
            return first
        case .index(let n):
            guard n <= entries.count else {
                throw ValidationError(L10n.Resume.indexOutOfRange(n, entries.count))
            }
            return entries[n - 1]
        case .id(let s):
            guard let match = entries.first(where: { $0.id == s }) else {
                throw ValidationError("session '\(s)' not found")
            }
            return match
        }
    }

    // MARK: - Scoped session discovery (shared + active env only)

    /// Discover sessions scoped to the active environment + shared sessions.
    /// Public so that external library consumers can drive session-diff logic.
    public static func findScopedSessions(
        tool: Tool,
        cwd: String,
        store: EnvironmentStore,
        activeEnvironment: String?
    ) -> [SessionsCommand.SessionEntry] {
        switch tool {
        case .claude: return findScopedClaudeSessions(cwd: cwd, store: store, activeEnvironment: activeEnvironment)
        case .codex:  return findScopedCodexSessions(store: store, activeEnvironment: activeEnvironment)
        case .gemini: return findScopedGeminiSessions(cwd: cwd, store: store, activeEnvironment: activeEnvironment)
        }
    }

    // MARK: - Claude: projects/<project-key>/*.jsonl

    private static func findScopedClaudeSessions(
        cwd: String,
        store: EnvironmentStore,
        activeEnvironment: String?
    ) -> [SessionsCommand.SessionEntry] {
        let projectKey = cwd.replacingOccurrences(of: "/", with: "-")
        var files: [URL] = []
        var seen = Set<String>()

        // Shared
        let sharedDir = store.sharedSessionDir(tool: .claude)
            .appendingPathComponent("projects")
            .appendingPathComponent(projectKey)
        files.append(contentsOf: SessionsCommand.jsonlFiles(in: sharedDir))

        // Active environment only (skip symlinked dirs)
        if let envName = activeEnvironment, envName != ReservedEnvironment.defaultName {
            let projectsDir = store.toolConfigDir(tool: .claude, environment: envName)
                .appendingPathComponent("projects")
            if !SessionsCommand.isSymlink(projectsDir) {
                let dir = projectsDir.appendingPathComponent(projectKey)
                files.append(contentsOf: SessionsCommand.jsonlFiles(in: dir))
            }
        }

        return SessionsCommand.dedup(files, seen: &seen)
            .compactMap { SessionsCommand.parseClaudeSession(file: $0) }
    }

    // MARK: - Codex: sessions/YYYY/MM/DD/rollout-*.jsonl (global)

    private static func findScopedCodexSessions(
        store: EnvironmentStore,
        activeEnvironment: String?
    ) -> [SessionsCommand.SessionEntry] {
        var files: [URL] = []
        var seen = Set<String>()

        // Shared
        let sharedDir = store.sharedSessionDir(tool: .codex)
            .appendingPathComponent("sessions")
        files.append(contentsOf: SessionsCommand.findRecursiveJsonl(in: sharedDir, prefix: "rollout-"))

        // Active environment only
        if let envName = activeEnvironment, envName != ReservedEnvironment.defaultName {
            let sessionsDir = store.toolConfigDir(tool: .codex, environment: envName)
                .appendingPathComponent("sessions")
            if !SessionsCommand.isSymlink(sessionsDir) {
                files.append(contentsOf: SessionsCommand.findRecursiveJsonl(in: sessionsDir, prefix: "rollout-"))
            }
        }

        return SessionsCommand.dedup(files, seen: &seen)
            .compactMap { SessionsCommand.parseCodexSession(file: $0) }
    }

    // MARK: - Gemini: tmp/<project-hash>/chats/checkpoint-*.json

    private static func findScopedGeminiSessions(
        cwd: String,
        store: EnvironmentStore,
        activeEnvironment: String?
    ) -> [SessionsCommand.SessionEntry] {
        var files: [URL] = []
        var seen = Set<String>()

        // Shared
        let sharedTmp = store.sharedSessionDir(tool: .gemini)
            .appendingPathComponent("tmp")
        files.append(contentsOf: SessionsCommand.findGeminiCheckpoints(in: sharedTmp))

        // Active environment only
        if let envName = activeEnvironment, envName != ReservedEnvironment.defaultName {
            let tmpDir = store.toolConfigDir(tool: .gemini, environment: envName)
                .appendingPathComponent("tmp")
            if !SessionsCommand.isSymlink(tmpDir) {
                files.append(contentsOf: SessionsCommand.findGeminiCheckpoints(in: tmpDir))
            }
        }

        return SessionsCommand.dedup(files, seen: &seen)
            .compactMap { SessionsCommand.parseGeminiSession(file: $0) }
    }
}
