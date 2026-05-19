import Foundation

public protocol UserMemoryHookInstaller {
    /// Idempotently add the user-memory SessionStart hook entry to this tool's config.
    func install(at configDir: URL) throws
    /// Remove only entries with `_orrery_managed: true`.
    func remove(at configDir: URL) throws
    /// Whether the managed entry is currently present.
    func isInstalled(at configDir: URL) -> Bool
}

/// Marker key the installers stamp on every entry they manage, so `remove` can
/// tell our hooks apart from user-installed ones.
let OrreryManagedKey = "_orrery_managed"
let UserMemoryHookCommand = "orrery memory user emit"

/// Shared JSON-merge logic used by all three installers — Claude, Codex (hooks.json),
/// Gemini all read JSON files with the same `hooks.SessionStart[*].hooks[*]` shape.
struct JSONHookEditor {
    let settingsFile: URL

    func loadOrEmpty() throws -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsFile.path) else { return [:] }
        let data = try Data(contentsOf: settingsFile)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func save(_ root: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsFile.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsFile, options: .atomic)
    }

    /// Returns `(root, sessionStart, firstMatcherIndex)` after ensuring shape exists.
    func ensureSessionStartShape(in root: inout [String: Any]) -> Int {
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var sessionStart = (hooks["SessionStart"] as? [[String: Any]]) ?? []
        if sessionStart.isEmpty {
            sessionStart.append(["matcher": "*", "hooks": [[String: Any]]()])
        } else if sessionStart[0]["hooks"] == nil {
            sessionStart[0]["hooks"] = [[String: Any]]()
        }
        hooks["SessionStart"] = sessionStart
        root["hooks"] = hooks
        return 0
    }

    func install() throws {
        var root = try loadOrEmpty()
        _ = ensureSessionStartShape(in: &root)
        var hooks = root["hooks"] as! [String: Any]
        var sessionStart = hooks["SessionStart"] as! [[String: Any]]
        var entries = sessionStart[0]["hooks"] as! [[String: Any]]

        let alreadyPresent = entries.contains {
            ($0[OrreryManagedKey] as? Bool) == true &&
            ($0["command"] as? String) == UserMemoryHookCommand
        }
        if !alreadyPresent {
            entries.append([
                "type": "command",
                "command": UserMemoryHookCommand,
                OrreryManagedKey: true
            ])
        }
        sessionStart[0]["hooks"] = entries
        hooks["SessionStart"] = sessionStart
        root["hooks"] = hooks
        try save(root)
    }

    func remove() throws {
        var root = try loadOrEmpty()
        guard var hooks = root["hooks"] as? [String: Any],
              var sessionStart = hooks["SessionStart"] as? [[String: Any]]
        else { return }
        for i in sessionStart.indices {
            if var entries = sessionStart[i]["hooks"] as? [[String: Any]] {
                entries.removeAll { ($0[OrreryManagedKey] as? Bool) == true }
                sessionStart[i]["hooks"] = entries
            }
        }
        hooks["SessionStart"] = sessionStart
        root["hooks"] = hooks
        try save(root)
    }

    func isInstalled() -> Bool {
        guard let root = try? loadOrEmpty(),
              let hooks = root["hooks"] as? [String: Any],
              let sessionStart = hooks["SessionStart"] as? [[String: Any]]
        else { return false }
        for matcher in sessionStart {
            let entries = (matcher["hooks"] as? [[String: Any]]) ?? []
            if entries.contains(where: {
                ($0[OrreryManagedKey] as? Bool) == true &&
                ($0["command"] as? String) == UserMemoryHookCommand
            }) {
                return true
            }
        }
        return false
    }
}

public struct ClaudeHookInstaller: UserMemoryHookInstaller {
    public init() {}
    public func install(at configDir: URL) throws {
        try JSONHookEditor(settingsFile: configDir.appendingPathComponent("settings.json")).install()
    }
    public func remove(at configDir: URL) throws {
        try JSONHookEditor(settingsFile: configDir.appendingPathComponent("settings.json")).remove()
    }
    public func isInstalled(at configDir: URL) -> Bool {
        JSONHookEditor(settingsFile: configDir.appendingPathComponent("settings.json")).isInstalled()
    }
}
