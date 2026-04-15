import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct SessionsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: L10n.Sessions.abstract,
        subcommands: [SyncSubcommand.self]
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

        var items: [SessionItem] = []
        for tool in tools {
            for entry in Self.findSessions(tool: tool, cwd: cwd, store: store) {
                items.append(SessionItem(tool: tool, entry: entry))
            }
        }
        items.sort { ($0.entry.lastTime ?? .distantPast) > ($1.entry.lastTime ?? .distantPast) }

        if items.isEmpty {
            print(L10n.Sessions.noSessions)
            return
        }

        Self.printGroupedList(items: items)
    }

    /// Grouped per-tool output preserved for non-TTY callers (pipes, MCP).
    static func printGroupedList(items: [SessionItem]) {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short

        // Re-group by tool, preserving the chronological sort within each tool.
        var byTool: [Tool: [SessionItem]] = [:]
        for item in items {
            byTool[item.tool, default: []].append(item)
        }

        for tool in Tool.allCases {
            guard let group = byTool[tool], !group.isEmpty else { continue }
            print("")
            print("  \u{1B}[1m\(tool.displayName)\u{1B}[0m")
            print("")
            for (i, item) in group.enumerated() {
                let idx = i + 1
                let title = String(item.entry.firstMessage.prefix(60))
                let msgs = "\(item.entry.userCount) msgs"
                let timeStr = item.entry.lastTime.map { df.string(from: $0) } ?? "?"
                print("  \u{1B}[1m[\(idx)]\u{1B}[0m \(title)")
                print("      \u{1B}[2m\(item.entry.id)\u{1B}[0m")
                print("      \u{1B}[2m\(msgs) · \(timeStr)\u{1B}[0m")
                if i < group.count - 1 { print("") }
            }
        }
        print("")
    }

    struct SessionItem {
        let tool: Tool
        let entry: SessionEntry
    }

    // MARK: - Per-tool session discovery

    public struct SessionEntry {
        public let id: String
        public let firstMessage: String
        public let lastTime: Date?
        public let userCount: Int
        public var isActive: Bool = false
    }

    public static func findSessions(tool: Tool, cwd: String, store: EnvironmentStore) -> [SessionEntry] {
        switch tool {
        case .claude: return findClaudeSessions(cwd: cwd, store: store)
        case .codex:  return findCodexSessions(store: store)
        case .gemini: return findGeminiSessions(cwd: cwd, store: store)
        }
    }

    // MARK: - Active session detection

    /// Returns the set of Claude session IDs that have a live process running them.
    /// Claude writes `sessions/<pid>.json` files under its config dir; we check
    /// whether each PID is still alive with kill(pid, 0).
    public static func activeClaudeSessionIds(store: EnvironmentStore) -> Set<String> {
        let sessionsDir = store.sharedSessionDir(tool: .claude).appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil
        ) else { return [] }

        var active = Set<String>()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = d["pid"] as? Int,
                  let sessionId = d["sessionId"] as? String
            else { continue }
            if kill(Int32(pid), 0) == 0 {
                active.insert(sessionId)
            }
        }
        return active
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
        // File modification date is accurate to the last write — no need to scan all lines.
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let modDate = attrs?[.modificationDate] as? Date
        let fileSize = (attrs?[.size] as? Int) ?? 0

        // Read only the first 16 KB to find the first user message quickly.
        guard let fh = try? FileHandle(forReadingFrom: file) else { return nil }
        let chunk = fh.readData(ofLength: 16_384)
        try? fh.close()
        guard let text = String(data: chunk, encoding: .utf8) else { return nil }

        var firstUser: String?
        var userCount = 0
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            guard let d = jsonDict(line) else { continue }
            if d["type"] as? String == "user" {
                userCount += 1
                if firstUser == nil { firstUser = extractText(from: d, key: "message") }
            }
        }
        // Scale count proportionally when only a prefix was read.
        if fileSize > chunk.count, chunk.count > 0, userCount > 0 {
            userCount = Int(Double(userCount) * Double(fileSize) / Double(chunk.count))
        }
        return SessionEntry(id: id, firstMessage: firstUser ?? "(empty)", lastTime: modDate, userCount: userCount)
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
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let modDate = attrs?[.modificationDate] as? Date
        let fileSize = (attrs?[.size] as? Int) ?? 0

        guard let fh = try? FileHandle(forReadingFrom: file) else { return nil }
        let chunk = fh.readData(ofLength: 16_384)
        try? fh.close()
        guard let text = String(data: chunk, encoding: .utf8) else { return nil }

        var firstUser: String?
        var userCount = 0
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            guard let d = jsonDict(line) else { continue }
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
        if fileSize > chunk.count, chunk.count > 0, userCount > 0 {
            userCount = Int(Double(userCount) * Double(fileSize) / Double(chunk.count))
        }
        return SessionEntry(id: id, firstMessage: firstUser ?? "(empty)", lastTime: modDate, userCount: userCount)
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

    // MARK: - sync subcommand

    /// Copy session files from one env into another. Skip-existing semantics:
    /// destination files are never overwritten. Works across any combination of
    /// origin / shared / isolated session storage — each env name resolves to
    /// the concrete dir(s) that hold its sessions for each tool.
    public struct SyncSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "sync",
            abstract: "Copy session files from one env into another (skip-existing)"
        )

        @Option(name: .long, help: "Source env name (e.g. 'origin', 'work').")
        public var from: String

        @Option(name: .long, help: "Destination env name. Defaults to the active env (ORRERY_ACTIVE_ENV).")
        public var to: String?

        public init() {}

        public func run() throws {
            let store = EnvironmentStore.default
            let toName = to
                ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
                ?? ReservedEnvironment.defaultName

            if from == toName {
                print("Source and destination are the same env (\(from)) — nothing to do.")
                return
            }

            // Validate envs exist (origin is always valid).
            if from != ReservedEnvironment.defaultName {
                _ = try store.load(named: from)
            }
            if toName != ReservedEnvironment.defaultName {
                _ = try store.load(named: toName)
            }

            let fm = FileManager.default
            var grandImported = 0
            var grandSkipped = 0

            for tool in Tool.allCases {
                let srcRoots = try Self.sessionRoots(envName: from, tool: tool, store: store)
                let dstRoots = try Self.sessionRoots(envName: toName, tool: tool, store: store)

                for (srcRoot, dstRoot) in zip(srcRoots, dstRoots) {
                    if srcRoot.standardizedFileURL == dstRoot.standardizedFileURL {
                        continue  // both ends share the same physical pool
                    }
                    guard fm.fileExists(atPath: srcRoot.path) else { continue }

                    let (imported, skipped) = try Self.copyMissing(from: srcRoot, to: dstRoot)
                    if imported + skipped > 0 {
                        print("\(tool.rawValue) \(srcRoot.lastPathComponent)/  \(from) → \(toName)")
                        print("  ✓ \(imported) imported, \(skipped) skipped")
                        grandImported += imported
                        grandSkipped += skipped
                    }
                }
            }

            print("")
            if grandImported == 0 && grandSkipped == 0 {
                print("No sessions found to sync.")
            } else {
                print("Total: \(grandImported) imported, \(grandSkipped) skipped")
            }
        }

        /// Resolve the absolute session-storage directories for a given env and
        /// tool. Returns one URL per `tool.sessionSubdirectories` entry (Claude
        /// has projects/sessions/session-env, Codex/Gemini have one each).
        static func sessionRoots(envName: String, tool: Tool, store: EnvironmentStore) throws -> [URL] {
            if envName == ReservedEnvironment.defaultName {
                return tool.sessionSubdirectories.map {
                    tool.defaultConfigDir.appendingPathComponent($0)
                }
            }
            let env = try store.load(named: envName)
            if env.isolatedSessionTools.contains(tool) {
                let toolDir = store.toolConfigDir(tool: tool, environment: envName)
                return tool.sessionSubdirectories.map {
                    toolDir.appendingPathComponent($0)
                }
            }
            return tool.sessionSubdirectories.map {
                store.sharedSessionDir(tool: tool).appendingPathComponent($0)
            }
        }

        /// Recursively copy regular files from `srcRoot` to `dstRoot`, skipping
        /// any destination paths that already exist. Returns (imported, skipped).
        static func copyMissing(from srcRoot: URL, to dstRoot: URL) throws -> (imported: Int, skipped: Int) {
            let fm = FileManager.default
            try fm.createDirectory(at: dstRoot, withIntermediateDirectories: true)

            guard let enumerator = fm.enumerator(atPath: srcRoot.path) else {
                return (0, 0)
            }

            var imported = 0
            var skipped = 0
            for case let relPath as String in enumerator {
                let srcURL = srcRoot.appendingPathComponent(relPath)
                let isFile = (try? srcURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isFile else { continue }

                let dstURL = dstRoot.appendingPathComponent(relPath)
                if fm.fileExists(atPath: dstURL.path) {
                    skipped += 1
                    continue
                }
                try fm.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: srcURL, to: dstURL)
                imported += 1
            }
            return (imported, skipped)
        }
    }
}
