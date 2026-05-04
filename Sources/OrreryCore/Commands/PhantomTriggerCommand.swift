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

    /// Source-of-truth markdown for the `/orrery:phantom` slash command. Both
    /// `orrery setup` (global → `~/.claude/commands/`) and `orrery mcp setup`
    /// (project-local → `<project>/.claude/commands/`) install this same
    /// content. The project-local copy is what makes the slash command work
    /// in non-origin envs, where `CLAUDE_CONFIG_DIR` redirects user-level
    /// commands away from `~/.claude/commands/` — project-local lookups are
    /// independent of `CLAUDE_CONFIG_DIR`.
    public static let slashCommandMarkdown: String = """
    ---
    description: Switch orrery environment without restarting Claude
    argument-hint: [env-name]
    ---

    # Phantom: switch orrery environment in-place

    Switch the active orrery environment without losing the conversation. Claude exits and the orrery supervisor relaunches it with the new env active and `--resume`, so the conversation continues where it left off.

    **Prerequisite**: Claude must have been launched via `orrery run claude` (which is phantom-supervised by default). If Claude was launched directly or with `orrery run --non-phantom claude`, the trigger will error with a clear message.

    ## What to do

    Inspect `$ARGUMENTS`:

    - **If `$ARGUMENTS` is non-empty** (a target env name): run `orrery-bin _phantom-trigger $ARGUMENTS`. The trigger writes a sentinel and signals Claude to exit. The supervisor relaunches Claude under the new env automatically — no further user action is needed.

    - **If `$ARGUMENTS` is empty**: first run `orrery-bin _phantom-trigger` (with no arguments) to get the list of available environments. Then ask the user which environment they want to switch to — present the list as choices. Once they answer, run `orrery-bin _phantom-trigger <chosen-env>`.

    Do not narrate the relaunch — Claude will simply exit and reappear with the new env. The user's next message lands in the new env.
    """

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
    /// Why we don't require `claude.ppid == supervisor`: some Claude Code
    /// setups wrap the binary with `caffeinate` to keep the system awake
    /// during long sessions, so the tree looks like `supervisor → caffeinate
    /// → claude`. We instead walk up until we either reach the supervisor
    /// (good — return the innermost claude we passed) or run out of
    /// ancestors (bad — return nil).
    ///
    /// We return the *outermost* claude in the chain (the one closest to the
    /// supervisor). Killing it cascades down through any wrapper layers
    /// (caffeinate, nested claudes) and lets the supervisor's `command
    /// claude` line return so the loop can read the sentinel and relaunch.
    static func findClaudeAncestor(supervisorPid: Int32) -> Int32? {
        var pid = getppid()
        var outermostClaude: Int32? = nil
        for _ in 0..<32 {
            guard pid > 1 else { break }
            guard let info = Self.readProcessInfo(pid: pid) else { break }
            if info.comm == "claude" {
                // Overwrite as we walk up — keep the last (outermost) claude.
                outermostClaude = pid
            }
            if pid == supervisorPid {
                return outermostClaude
            }
            pid = info.ppid
        }
        return nil
    }

    /// Read `(ppid, comm)` for a given pid via `ps`. `comm` is normalized to
    /// the basename so `/path/to/claude` becomes `claude`.
    static func readProcessInfo(pid: Int32) -> (ppid: Int32, comm: String)? {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var procInfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride

        let result = mib.withUnsafeMutableBufferPointer { mibPtr in
            withUnsafeMutablePointer(to: &procInfo) { infoPtr in
                infoPtr.withMemoryRebound(to: CChar.self, capacity: size) { bytes in
                    sysctl(mibPtr.baseAddress, 4, bytes, &size, nil, 0)
                }
            }
        }

        if result == 0, size > 0 {
            let comm = withUnsafePointer(to: &procInfo.kp_proc.p_comm) { ptr in
                String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
            }
            let basename = (comm as NSString).lastPathComponent
            if !basename.isEmpty {
                return (procInfo.kp_eproc.e_ppid, basename)
            }
        }
        #endif

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
