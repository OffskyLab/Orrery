import ArgumentParser
import Foundation

public struct SessionsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: L10n.Sessions.abstract
    )

    @Flag(help: ArgumentHelp(L10n.ToolFlag.claude))
    public var claude: Bool = false

    @Flag(help: ArgumentHelp(L10n.ToolFlag.codex))
    public var codex: Bool = false

    @Flag(help: ArgumentHelp(L10n.ToolFlag.gemini))
    public var gemini: Bool = false

    public init() {}

    public func run() throws {
        let cwd = FileManager.default.currentDirectoryPath
        let store = EnvironmentStore.default

        let tools: [Tool]
        let flags: [(Bool, Tool)] = [(claude, .claude), (codex, .codex), (gemini, .gemini)]
        let selected = flags.filter(\.0).map(\.1)
        tools = selected.isEmpty ? Tool.allCases.map { $0 } : selected

        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .short
        displayFormatter.timeStyle = .short

        var hasAny = false

        for tool in tools {
            let entries = Self.findSessions(tool: tool, cwd: cwd, store: store)
            guard !entries.isEmpty else { continue }
            hasAny = true

            let sorted = entries.sorted { ($0.lastTime ?? .distantPast) > ($1.lastTime ?? .distantPast) }

            print("")
            print("  \u{1B}[1m\(tool.displayName)\u{1B}[0m")
            print("")
            for (i, e) in sorted.enumerated() {
                let idx = i + 1
                let title = String(e.firstMessage.prefix(60))
                let msgs = "\(e.userCount) msgs"
                let timeStr = e.lastTime.map { displayFormatter.string(from: $0) } ?? "?"
                print("  \u{1B}[1m[\(idx)]\u{1B}[0m \(title)")
                print("      \u{1B}[2m\(e.id)\u{1B}[0m")
                print("      \u{1B}[2m\(msgs) · \(timeStr)\u{1B}[0m")
                if i < sorted.count - 1 { print("") }
            }
        }

        if !hasAny {
            print(L10n.Sessions.noSessions)
        } else {
            print("")
        }
    }

    // MARK: - Per-tool session discovery

    public struct SessionEntry {
        public let id: String
        public let firstMessage: String
        public let lastTime: Date?
        public let userCount: Int
    }

    public static func findSessions(tool: Tool, cwd: String, store: EnvironmentStore) -> [SessionEntry] {
        switch tool {
        case .claude: return findClaudeSessions(cwd: cwd, store: store)
        case .codex:  return findCodexSessions(store: store)
        case .gemini: return findGeminiSessions(cwd: cwd, store: store)
        }
    }

    // MARK: - Claude: projects/<project-key>/*.jsonl

    static func findClaudeSessions(cwd: String, store: EnvironmentStore) -> [SessionEntry] {
        let projectKey = cwd.replacingOccurrences(of: "/", with: "-")
        var files: [URL] = []
        var seen = Set<String>()

        // Shared
        let sharedDir = store.sharedSessionDir(tool: .claude)
            .appendingPathComponent("projects")
            .appendingPathComponent(projectKey)
        files.append(contentsOf: jsonlFiles(in: sharedDir))

        // Per-env (non-symlinked)
        for name in (try? store.listNames()) ?? [] {
            let projectsDir = store.toolConfigDir(tool: .claude, environment: name)
                .appendingPathComponent("projects")
            if isSymlink(projectsDir) { continue }
            let dir = projectsDir.appendingPathComponent(projectKey)
            files.append(contentsOf: jsonlFiles(in: dir))
        }

        return dedup(files, seen: &seen).compactMap { parseClaudeSession(file: $0) }
    }

    static func parseClaudeSession(file: URL) -> SessionEntry? {
        let id = file.deletingPathExtension().lastPathComponent
        guard let data = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        var firstUser: String?
        var lastTimestamp: Date?
        var userCount = 0

        for line in data.components(separatedBy: .newlines) where !line.isEmpty {
            guard let d = jsonDict(line) else { continue }
            updateTimestamp(from: d, current: &lastTimestamp)
            if d["type"] as? String == "user" {
                userCount += 1
                if firstUser == nil { firstUser = extractText(from: d, key: "message") }
            }
        }
        return SessionEntry(id: id, firstMessage: firstUser ?? "(empty)", lastTime: lastTimestamp, userCount: userCount)
    }

    // MARK: - Codex: sessions/YYYY/MM/DD/rollout-*.jsonl (global, not project-scoped)

    static func findCodexSessions(store: EnvironmentStore) -> [SessionEntry] {
        var files: [URL] = []
        var seen = Set<String>()

        // Shared
        let sharedDir = store.sharedSessionDir(tool: .codex)
            .appendingPathComponent("sessions")
        files.append(contentsOf: findRecursiveJsonl(in: sharedDir, prefix: "rollout-"))

        // Per-env
        for name in (try? store.listNames()) ?? [] {
            let sessionsDir = store.toolConfigDir(tool: .codex, environment: name)
                .appendingPathComponent("sessions")
            if isSymlink(sessionsDir) { continue }
            files.append(contentsOf: findRecursiveJsonl(in: sessionsDir, prefix: "rollout-"))
        }

        return dedup(files, seen: &seen).compactMap { parseCodexSession(file: $0) }
    }

    static func parseCodexSession(file: URL) -> SessionEntry? {
        let id = file.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "rollout-", with: "")
        guard let data = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        var firstUser: String?
        var lastTimestamp: Date?
        var userCount = 0

        for line in data.components(separatedBy: .newlines) where !line.isEmpty {
            guard let d = jsonDict(line) else { continue }
            updateTimestamp(from: d, current: &lastTimestamp)
            let role = d["role"] as? String ?? d["type"] as? String
            if role == "user" {
                userCount += 1
                if firstUser == nil {
                    firstUser = extractText(from: d, key: "message")
                        ?? extractText(from: d, key: "content")
                        ?? (d["content"] as? String).map { String($0.prefix(80)) }
                }
            }
        }
        return SessionEntry(id: id, firstMessage: firstUser ?? "(empty)", lastTime: lastTimestamp, userCount: userCount)
    }

    // MARK: - Gemini: tmp/<project-hash>/chats/checkpoint-*.json

    static func findGeminiSessions(cwd: String, store: EnvironmentStore) -> [SessionEntry] {
        var files: [URL] = []
        var seen = Set<String>()

        // Scan all project-hash dirs under shared tmp/
        let sharedTmp = store.sharedSessionDir(tool: .gemini)
            .appendingPathComponent("tmp")
        files.append(contentsOf: findGeminiCheckpoints(in: sharedTmp))

        // Per-env
        for name in (try? store.listNames()) ?? [] {
            let tmpDir = store.toolConfigDir(tool: .gemini, environment: name)
                .appendingPathComponent("tmp")
            if isSymlink(tmpDir) { continue }
            files.append(contentsOf: findGeminiCheckpoints(in: tmpDir))
        }

        return dedup(files, seen: &seen).compactMap { parseGeminiSession(file: $0) }
    }

    static func findGeminiCheckpoints(in baseDir: URL) -> [URL] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) else { return [] }
        var results: [URL] = []
        for dir in projectDirs {
            let chatsDir = dir.appendingPathComponent("chats")
            guard let files = try? fm.contentsOfDirectory(at: chatsDir, includingPropertiesForKeys: nil) else { continue }
            results.append(contentsOf: files.filter {
                $0.lastPathComponent.hasPrefix("checkpoint-") && $0.pathExtension == "json"
            })
        }
        return results
    }

    static func parseGeminiSession(file: URL) -> SessionEntry? {
        let id = file.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "checkpoint-", with: "")
        guard let data = try? Data(contentsOf: file),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        var firstUser: String?
        var userCount = 0

        for msg in arr {
            if msg["role"] as? String == "user" {
                userCount += 1
                if firstUser == nil {
                    if let parts = msg["parts"] as? [[String: Any]] {
                        for part in parts {
                            if let text = part["text"] as? String {
                                firstUser = String(text.prefix(80))
                                break
                            }
                        }
                    }
                }
            }
        }

        // Use file modification date as timestamp
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let modDate = attrs?[.modificationDate] as? Date

        return SessionEntry(id: id, firstMessage: firstUser ?? "(empty)", lastTime: modDate, userCount: userCount)
    }

    // MARK: - Shared helpers

    static func sharedSessionDir(store: EnvironmentStore, tool: Tool) -> URL {
        store.sharedSessionDir(tool: tool)
    }

    static func jsonlFiles(in dir: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents.filter { $0.pathExtension == "jsonl" }
    }

    static func findRecursiveJsonl(in dir: URL, prefix: String) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix(prefix) {
                results.append(url)
            }
        }
        return results
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    static func dedup(_ files: [URL], seen: inout Set<String>) -> [URL] {
        files.filter { url in
            let id = url.deletingPathExtension().lastPathComponent
            return seen.insert(id).inserted
        }
    }

    private static nonisolated(unsafe) let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func jsonDict(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    static func updateTimestamp(from d: [String: Any], current: inout Date?) {
        if let ts = d["timestamp"] as? String, let date = isoFormatter.date(from: ts) {
            if current == nil || date > current! { current = date }
        }
        if let snap = d["snapshot"] as? [String: Any],
           let ts = snap["timestamp"] as? String,
           let date = isoFormatter.date(from: ts) {
            if current == nil || date > current! { current = date }
        }
    }

    static func extractText(from d: [String: Any], key: String) -> String? {
        guard let msg = d[key] as? [String: Any] else { return nil }
        let content = msg["content"]
        if let text = content as? String {
            return String(text.prefix(80))
        }
        if let arr = content as? [[String: Any]] {
            for item in arr {
                if item["type"] as? String == "text", let text = item["text"] as? String {
                    return String(text.prefix(80))
                }
            }
        }
        return nil
    }
}
