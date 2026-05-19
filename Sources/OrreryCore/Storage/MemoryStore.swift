import Foundation

/// Reads / writes a markdown memory store at `directory/`.
///
/// Layout:
/// - `directory/MEMORY.md` — canonical index, what the AI agent reads/writes.
/// - `directory/fragments/f-{id}-{peer}.md` — per-write fragment for cross-machine sync.
///
/// Used by both the project-level (per `projectKey` / env) and user-level
/// (`~/.orrery/user/memory/`) memory layers. The two layers differ only in
/// which `directory` they point at.
public struct MemoryStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public struct Fragment: Sendable, Equatable {
        public let filename: String
        public let content: String
    }

    public struct ReadResult: Sendable {
        public let memory: String
        public let fragments: [Fragment]
    }

    private var memoryFile: URL { directory.appendingPathComponent("MEMORY.md") }
    private var fragmentsDir: URL { directory.appendingPathComponent("fragments") }

    /// Read `MEMORY.md` plus any pending fragments. Both default to empty when missing.
    public func read() throws -> ReadResult {
        let fm = FileManager.default
        var memory = ""
        if fm.fileExists(atPath: memoryFile.path) {
            memory = try String(contentsOf: memoryFile, encoding: .utf8)
        }

        var fragments: [Fragment] = []
        if fm.fileExists(atPath: fragmentsDir.path) {
            let names = (try? fm.contentsOfDirectory(atPath: fragmentsDir.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".md") {
                let url = fragmentsDir.appendingPathComponent(name)
                if let body = try? String(contentsOf: url, encoding: .utf8) {
                    fragments.append(Fragment(filename: name, content: body))
                }
            }
        }
        return ReadResult(memory: memory, fragments: fragments)
    }

    /// Write or append to `MEMORY.md`, and record a fragment of the same write.
    /// When `append == false`, cleans up *prior* fragments before recording the new one — this
    /// is the consolidation contract: an overwrite means "the agent has integrated everything".
    public func write(content: String, append: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        if append, fm.fileExists(atPath: memoryFile.path) {
            let existing = try String(contentsOf: memoryFile, encoding: .utf8)
            try (existing + "\n" + content).write(to: memoryFile, atomically: true, encoding: .utf8)
        } else {
            try content.write(to: memoryFile, atomically: true, encoding: .utf8)
            cleanupFragments()
        }

        try writeFragment(content: content, action: append ? "append" : "overwrite")
    }

    /// Remove all fragments from `fragments/`. Best-effort; missing dir is fine.
    public func cleanupFragments() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: fragmentsDir.path) else { return }
        for name in names where name.hasSuffix(".md") {
            try? fm.removeItem(at: fragmentsDir.appendingPathComponent(name))
        }
    }

    /// Produce the hook-stdout / read-tool output: MEMORY.md content optionally followed
    /// by a "Pending Memory Fragments" block, truncated to `maxBytes`.
    public func emit(maxBytes: Int) throws -> String {
        let r = try read()
        var output = r.memory
        if !r.fragments.isEmpty {
            output += "\n\n---\n## Pending Memory Fragments (from sync)\n"
            output += "The following fragments were synced from other machines and need to be integrated.\n"
            output += "Please consolidate them into the memory above, then write back with append=false.\n"
            output += "After integration, the fragment files will be cleaned up automatically.\n\n"
            for f in r.fragments {
                output += "### \(f.filename)\n"
                output += f.content + "\n\n"
            }
        }
        let utf8Bytes = Array(output.utf8)
        if utf8Bytes.count <= maxBytes { return output }
        let truncated = String(decoding: utf8Bytes.prefix(maxBytes), as: UTF8.self)
        return truncated + "\n\n(truncated — read full via orrery_user_memory_read)"
    }

    private func writeFragment(content: String, action: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fragmentsDir, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let peer = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
        let id = String(UUID().uuidString.prefix(8).lowercased())
        let filename = "f-\(id)-\(peer).md"

        let body = """
        ---
        id: f-\(id)
        peer: \(peer)
        timestamp: \(timestamp)
        action: \(action)
        ---

        \(content)
        """
        try body.write(
            to: fragmentsDir.appendingPathComponent(filename),
            atomically: true,
            encoding: .utf8
        )
    }
}
