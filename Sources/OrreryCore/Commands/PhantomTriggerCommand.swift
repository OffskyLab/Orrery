import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// `orrery-bin _phantom-trigger <env>` — invoked from inside a phantom-supervised
/// claude (typically via the `/orrery:phantom` slash command). Writes a sentinel
/// describing the desired next env + current session id, then SIGTERMs claude so
/// the supervisor loop in `activate.sh` can relaunch with the new env active and
/// `--resume <session-id>` so the conversation continues seamlessly.
public struct PhantomTriggerCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_phantom-trigger",
        abstract: L10n.Phantom.triggerAbstract,
        shouldDisplay: false
    )

    @Argument(parsing: .remaining)
    public var args: [String] = []

    public init() {}

    public func run() throws {
        let supervisorPidStr = ProcessInfo.processInfo.environment["ORRERY_PHANTOM_SHELL_PID"]
        guard let supervisorPidStr, let supervisorPid = Int32(supervisorPidStr) else {
            throw ValidationError(L10n.Phantom.notUnderPhantom)
        }

        let store = EnvironmentStore.default

        // No-arg form: list envs and bail with a hint. The slash command will
        // catch this output and re-prompt the user.
        guard let target = args.first, !target.isEmpty else {
            let names = ([ReservedEnvironment.defaultName] + ((try? store.listNames().sorted()) ?? []))
            print(L10n.Phantom.availableHeader)
            for n in names { print("  - \(n)") }
            print("")
            print(L10n.Phantom.usageHint)
            return
        }

        // Validate target env exists (origin is always valid).
        if target != ReservedEnvironment.defaultName {
            _ = try store.load(named: target)
        }

        // Find claude FIRST — if we can't reach it, don't leave a stale sentinel
        // that would fire on the next normal claude exit.
        guard let claudePid = Self.findClaudeAncestor(supervisorPid: supervisorPid) else {
            throw ValidationError(L10n.Phantom.claudeNotFound)
        }

        let sessionId = Self.findCurrentClaudeSessionId()
        try Self.writeSentinel(targetEnv: target, sessionId: sessionId, store: store)

        if let sessionId {
            print(L10n.Phantom.switching(target, String(sessionId.prefix(8))))
        } else {
            print(L10n.Phantom.switchingNoSession(target))
        }

        // SIGTERM lets claude exit cleanly. Its JSONL is streamed live so the
        // conversation up to this turn is already on disk. If the signal fails
        // to deliver (race with claude exiting), pull the sentinel back so it
        // doesn't fire on the next manual launch.
        if kill(claudePid, SIGTERM) != 0 {
            try? FileManager.default.removeItem(at: Self.sentinelURL(store: store))
            throw ValidationError(L10n.Phantom.signalFailed)
        }
    }

    // MARK: - Session id discovery

    /// Locate the active Claude session by scanning `<claude-config>/projects/<encoded-cwd>/`
    /// for the .jsonl with the highest mtime. Returns nil if no session file is
    /// found (e.g. brand-new conversation that hasn't streamed yet).
    static func findCurrentClaudeSessionId() -> String? {
        let cwd = FileManager.default.currentDirectoryPath
        let projectKey = cwd.replacingOccurrences(of: "/", with: "-")

        let configDirPath = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/.claude")
        let projectsDir = URL(fileURLWithPath: configDirPath)
            .appendingPathComponent("projects")
            .appendingPathComponent(projectKey)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        let jsonl = files.filter { $0.pathExtension == "jsonl" }
        let latest = jsonl.max { a, b in
            let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ad < bd
        }
        return latest?.deletingPathExtension().lastPathComponent
    }

    // MARK: - Sentinel

    public static func sentinelURL(store: EnvironmentStore) -> URL {
        store.homeURL.appendingPathComponent(".phantom-sentinel")
    }

    /// Sentinel format is shell-sourceable so the supervisor loop can simply
    /// `. "$sentinel"` to read it. Single-quoted values guard against names
    /// containing shell metacharacters (env names are validated elsewhere, but
    /// be defensive at the IPC boundary).
    static func writeSentinel(targetEnv: String, sessionId: String?, store: EnvironmentStore) throws {
        let url = Self.sentinelURL(store: store)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var lines: [String] = []
        lines.append("TARGET_ENV='\(shellEscape(targetEnv))'")
        if let sessionId {
            lines.append("SESSION_ID='\(shellEscape(sessionId))'")
        } else {
            lines.append("SESSION_ID=''")
        }
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    // MARK: - Process discovery

    /// Find the claude process that the supervisor launched, by walking UP from
    /// the trigger's own parent chain rather than down from the supervisor.
    ///
    /// Walking up is more robust than `pgrep -P <supervisor>`: claude is a
    /// Bun-compiled Mach-O that may fork worker processes, and the actual
    /// claude in the trigger's ancestry isn't guaranteed to be a *direct*
    /// child of the supervisor shell — only an ancestor.
    ///
    /// We pick the claude whose parent is the supervisor (correctly handles
    /// nested-claude scenarios where an inner claude was launched from a
    /// supervised outer one). If no such match exists, return nil so the
    /// trigger errors out cleanly rather than killing the wrong process.
    static func findClaudeAncestor(supervisorPid: Int32) -> Int32? {
        var pid = getppid()
        for _ in 0..<32 {
            guard pid > 1 else { break }
            guard let info = Self.readProcessInfo(pid: pid) else { break }
            if info.comm == "claude" && info.ppid == supervisorPid {
                return pid
            }
            pid = info.ppid
        }
        return nil
    }

    /// Read `(ppid, comm)` for a given pid via `ps`. `comm` is normalized to
    /// the basename so `/path/to/claude` becomes `claude`.
    static func readProcessInfo(pid: Int32) -> (ppid: Int32, comm: String)? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["ps", "-p", String(pid), "-o", "ppid=,comm="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        // ps output: leading whitespace + "<ppid> <comm>". comm may include a
        // path or have its own spaces — split once on the first whitespace run.
        let trimmed = raw.drop(while: { $0 == " " })
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let ppid = Int32(parts[0]) else { return nil }
        let commPath = String(parts[1]).trimmingCharacters(in: .whitespaces)
        let basename = (commPath as NSString).lastPathComponent
        return (ppid, basename)
    }
}
