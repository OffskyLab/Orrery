import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// `orrery-bin _phantom-trigger-sandbox <env>` — invoked from inside a phantom-supervised
/// claude (typically via the `/orrery:phantom` slash command). Writes a sentinel
/// describing the desired next sandbox + current session id, then SIGTERMs claude so
/// the supervisor loop in `activate.sh` can relaunch with the new sandbox active and
/// `--resume <session-id>` so the conversation continues seamlessly.
public struct PhantomSandboxTriggerCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_phantom-trigger-sandbox",
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
    description: Switch orrery account or sandbox without restarting Claude
    argument-hint: [name | <tool> <name> | sandbox <name>]
    ---

    # Phantom: switch orrery account or sandbox in-place

    Switch the active orrery account (or sandbox) without losing the conversation. Claude exits and the orrery supervisor relaunches it with `--resume`, so the conversation continues where it left off.

    **Prerequisite**: Claude must have been launched via `orrery run claude` (which is phantom-supervised by default). If Claude was launched directly or with `orrery run --non-phantom claude`, the trigger will error with a clear message.

    ## What to do

    Inspect `$ARGUMENTS` and pick the matching branch:

    - **`$ARGUMENTS` is `sandbox <name>`** (explicit sandbox switch): run `orrery-bin _phantom-trigger-sandbox <name>`.

    - **`$ARGUMENTS` starts with `claude`, `codex`, or `gemini`** followed by a name: switch that tool's account. Run `orrery-bin _phantom-trigger-account --<tool> --name <name>`.

    - **`$ARGUMENTS` is just `<name>`** (a single token, not `sandbox`/`claude`/`codex`/`gemini`): default to switching the claude account. Run `orrery-bin _phantom-trigger-account --claude --name <name>`.

    - **`$ARGUMENTS` is empty**: first run `orrery-bin _phantom-trigger-sandbox` (no args) to get the list of available sandboxes, and `orrery-bin list` to get the list of accounts. Present both lists to the user, ask which they want to switch to, and re-invoke this slash command with their choice.

    Do not narrate the relaunch — Claude will simply exit and reappear with the new account or sandbox active. The user's next message lands in the new context.
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
            let names = ([Workspace.reservedOriginName] + ((try? store.listNames().sorted()) ?? []))
            print(L10n.Phantom.availableHeader)
            for n in names { print("  - \(n)") }
            print("")
            print(L10n.Phantom.usageHint)
            return
        }

        // Validate target env exists (origin is always valid).
        if target != Workspace.reservedOriginName {
            _ = try store.load(named: target)
        }

        // Find claude FIRST — if we can't reach it, don't leave a stale sentinel
        // that would fire on the next normal claude exit.
        guard let claudePid = Self.findClaudeAncestor(supervisorPid: supervisorPid) else {
            throw ValidationError(L10n.Phantom.claudeNotFound)
        }

        let sessionId = Self.findCurrentClaudeSessionId()
        try Self.writeSentinel(
            targetSandbox: target,
            targetAccountTool: nil,
            targetAccountName: nil,
            sessionId: sessionId,
            store: store
        )

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
    /// containing shell metacharacters (env / account names are validated
    /// elsewhere, but be defensive at the IPC boundary).
    ///
    /// The sentinel can carry EITHER a target env (env-switch) OR a target
    /// account (account-switch) — the supervisor loop applies whichever is
    /// present AFTER claude exits. Only non-nil fields are emitted; `SESSION_ID`
    /// is always emitted (empty string when nil).
    static func writeSentinel(
        targetSandbox: String?,
        targetAccountTool: String?,
        targetAccountName: String?,
        sessionId: String?,
        store: EnvironmentStore
    ) throws {
        let url = Self.sentinelURL(store: store)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var lines: [String] = []
        if let targetSandbox {
            lines.append("TARGET_SANDBOX='\(shellEscape(targetSandbox))'")
        }
        if let targetAccountTool {
            lines.append("TARGET_ACCOUNT_TOOL='\(shellEscape(targetAccountTool))'")
        }
        if let targetAccountName {
            lines.append("TARGET_ACCOUNT_NAME='\(shellEscape(targetAccountName))'")
        }
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
    /// Whether a process comm names the Claude Code binary. The native binary
    /// is Bun-compiled and runs with comm "claude.exe" (Bun appends .exe to
    /// compiled executables even on macOS); other installs report plain
    /// "claude". The regex accepts "claude" with an optional extension,
    /// case-insensitively — tolerant of packaging changes, but anchored by
    /// `wholeMatch` so it won't mistarget e.g. "claude-helper":
    /// findClaudeAncestor's result gets signalled.
    static func isClaudeComm(_ comm: String) -> Bool {
        comm.wholeMatch(of: /claude(\..+)?/.ignoresCase()) != nil
    }

    static func findClaudeAncestor(supervisorPid: Int32) -> Int32? {
        let result = resolveClaudePid(
            start: getppid(),
            supervisorPid: supervisorPid,
            lookup: { Self.readProcessInfo(pid: $0) })
        if result.claudePid == nil {
            if result.reachedSupervisor {
                stderrWrite("orrery: phantom: reached supervisor \(supervisorPid) "
                    + "but found no claude in the ancestry; walked: "
                    + result.walked.joined(separator: " -> ") + "\n")
            } else {
                stderrWrite("orrery: phantom: walked off the process tree without "
                    + "reaching supervisor \(supervisorPid); walked: "
                    + result.walked.joined(separator: " -> ") + "\n")
            }
        }
        return result.claudePid
    }

    /// Pure, testable ancestry resolution. Walks from `start` up the parent
    /// chain (via `lookup`) until it reaches `supervisorPid`.
    ///
    /// Identifying claude by its comm being "claude" is unreliable: Claude Code
    /// is a Node/Bun app that reports its process name as the version string
    /// (e.g. "2.1.201"), so `isClaudeComm` alone misses it. We still PREFER a
    /// comm that names claude — that keeps the right target when a wrapper (e.g.
    /// `caffeinate`) sits between claude and the supervisor — but when nothing
    /// in the chain matched by name, we FALL BACK to the supervisor's direct
    /// child in this chain. The supervisor's loop launches claude in the
    /// foreground, so that hop is the process to signal regardless of what it
    /// calls itself.
    ///
    /// Returns the resolved claude pid (nil only when the supervisor is never
    /// reached), whether the supervisor was reached, and the walked `pid:comm`
    /// hops for diagnostics.
    static func resolveClaudePid(
        start: Int32,
        supervisorPid: Int32,
        maxHops: Int = 32,
        lookup: (Int32) -> (ppid: Int32, comm: String)?
    ) -> (claudePid: Int32?, reachedSupervisor: Bool, walked: [String]) {
        var pid = start
        var outermostClaude: Int32? = nil
        var prev: Int32? = nil
        // Record each (pid:comm) hop so a failure prints the actual ancestry —
        // the error is then debuggable from its own output.
        var walked: [String] = []
        for _ in 0..<maxHops {
            guard pid > 1 else { break }
            guard let info = lookup(pid) else {
                walked.append("\(pid):<unreadable>")
                break
            }
            walked.append("\(pid):\(info.comm)")
            if Self.isClaudeComm(info.comm) {
                // Overwrite as we walk up — keep the last (outermost) claude.
                outermostClaude = pid
            }
            if pid == supervisorPid {
                // `prev` is the hop we visited right before the supervisor —
                // i.e. the supervisor's direct child in this chain.
                return (outermostClaude ?? prev, true, walked)
            }
            prev = pid
            pid = info.ppid
        }
        return (nil, false, walked)
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
            let basename = URL(fileURLWithPath: comm).lastPathComponent
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
        let basename = URL(fileURLWithPath: commPath).lastPathComponent
        return (ppid, basename)
    }
}
