import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Shared infrastructure for phantom-mode account switching (`/orrery:phantom`,
/// backed by `orrery-bin phantom`): sentinel read/write, claude-process
/// discovery, and the slash-command markdown installed by `orrery setup` /
/// `orrery mcp setup`.
public enum PhantomSupport {

    /// Source-of-truth markdown for the `/orrery:phantom` slash command. Both
    /// `orrery setup` (global → `~/.claude/commands/`) and `orrery mcp setup`
    /// (project-local → `<project>/.claude/commands/`) install this same
    /// content. The project-local copy is what makes the slash command work
    /// in non-origin envs, where `CLAUDE_CONFIG_DIR` redirects user-level
    /// commands away from `~/.claude/commands/` — project-local lookups are
    /// independent of `CLAUDE_CONFIG_DIR`.
    public static let slashCommandMarkdown: String = """
    ---
    description: Switch orrery account without restarting Claude
    argument-hint: [name | <tool> <name>] [--session <number|id>]
    ---

    # Phantom: switch orrery account in-place

    Switch the active orrery account without losing the conversation. Claude exits and the orrery supervisor relaunches it with `--resume`, so the conversation continues where it left off.

    **Prerequisite**: a bare `claude` launch is phantom-supervised by default — no special invocation needed. If the trigger errors saying no supervised session was found, either claude was started with `orrery run --non-phantom claude` / `--non-phantom`, or the shell integration predates phantom's registry support — run `orrery setup` to refresh it.

    **Tip**: this slash command is just a convenience wrapper — `orrery phantom <name>` (or `orrery phantom --codex <name>` / `--gemini`) is a plain CLI command and works the same way run directly (e.g. via `!` command-mode), including when the account's usage is exhausted and a Claude turn isn't available to parse this command.

    **Multiple sessions running**: the trigger addresses sessions via a registry, not just the current terminal, so if more than one supervised session is live it can't guess which one you mean. It responds with a numbered list (id, tool, account, cwd, session id) and refuses to switch anything. Re-invoke with `--session <number|id>` — either the number from that list or the session id directly — to pick one, e.g. `orrery-bin phantom <name> --session 2`.

    ## What to do

    Inspect `$ARGUMENTS` and pick the matching branch:

    - **`$ARGUMENTS` starts with `claude`, `codex`, or `gemini`** followed by a name: switch that tool's account. Run `orrery-bin phantom --<tool> <name>` (omit `--claude`, it's the default).

    - **`$ARGUMENTS` is just `<name>`** (a single token, not `claude`/`codex`/`gemini`): default to switching the claude account. Run `orrery-bin phantom <name>`.

    - **`$ARGUMENTS` is empty**: run `orrery-bin list` to get the list of accounts, present it to the user, and ask which they want to switch to, then re-invoke this slash command with their choice.

    - **The trigger reports multiple supervised sessions**: show the user the numbered list from its error output and ask which one they mean (using tool/account/cwd to disambiguate), then re-invoke with `--session <number|id>` appended.

    Do not narrate the relaunch — Claude will simply exit and reappear with the new account active. The user's next message lands in the new context.
    """

    // MARK: - Sentinel

    /// Sentinel format is shell-sourceable so the supervisor loop can simply
    /// `. "$sentinel"` to read it. Single-quoted values guard against names
    /// containing shell metacharacters (account names are validated
    /// elsewhere, but be defensive at the IPC boundary).
    ///
    /// `SESSION_ID` is always emitted (empty string when nil); the account
    /// fields are only emitted when non-nil.
    ///
    /// The destination is passed in rather than derived: sentinels live inside
    /// a supervisor's own registry directory, because a single shared path let
    /// concurrent sessions read each other's switch requests.
    public static func writeSentinel(
        targetAccountTool: String?,
        targetAccountName: String?,
        sessionId: String?,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var lines: [String] = []
        if let targetAccountTool {
            lines.append("TARGET_ACCOUNT_TOOL=\(ShellQuote.single(targetAccountTool))")
        }
        if let targetAccountName {
            lines.append("TARGET_ACCOUNT_NAME=\(ShellQuote.single(targetAccountName))")
        }
        lines.append("SESSION_ID=\(ShellQuote.single(sessionId ?? ""))")
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Parse a sentinel written by `writeSentinel`. Returns nil when the file
    /// is absent or unreadable. An empty `SESSION_ID` reads back as nil so
    /// callers never have to special-case the empty string.
    public static func readSentinel(
        at url: URL
    ) -> (tool: String?, name: String?, sessionId: String?)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            var value = String(line[line.index(after: eq)...])
            if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                value = value.replacingOccurrences(of: #"'\''"#, with: "'")
            }
            values[key] = value
        }
        let session = values["SESSION_ID"]
        return (
            tool: values["TARGET_ACCOUNT_TOOL"],
            name: values["TARGET_ACCOUNT_NAME"],
            sessionId: (session?.isEmpty ?? true) ? nil : session
        )
    }

    // MARK: - Session id discovery

    /// Locate the active Claude session by scanning `<claude-config>/projects/<encoded-cwd>/`
    /// for the .jsonl with the highest mtime. Returns nil if no session file is
    /// found (e.g. brand-new conversation that hasn't streamed yet).
    static func findCurrentClaudeSessionId() -> String? {
        let cwd = FileManager.default.currentDirectoryPath
        let projectKey = cwd.replacingOccurrences(of: "/", with: "-")

        let configDirPath = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? (userHomeURL().path + "/.claude")
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

    // MARK: - Process discovery

    /// Find the claude process that the supervisor launched, by walking UP from
    /// the trigger's own parent chain rather than down from the supervisor.
    ///
    /// Walking up is more robust than `pgrep -P <supervisor>`: claude is a
    /// Bun-compiled Mach-O that may fork worker processes, and the actual
    /// claude in the trigger's ancestry isn't guaranteed to be a *direct*
    /// child of the supervisor shell — only an ancestor.
    ///
    /// Why we don't require `claude.ppid == supervisor`: an unrelated process
    /// could in principle sit between the supervisor and claude in the tree,
    /// and this walk tolerates that rather than assuming a direct
    /// parent/child link. We instead walk up until we either reach the
    /// supervisor (good — return the innermost claude we passed) or run out
    /// of ancestors (bad — return nil).
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

    // MARK: - Downward process discovery (out-of-band triggering)

    /// Find claude by descending from a known supervisor.
    ///
    /// The in-chain trigger walks *up* from itself, which is shorter and needs
    /// no search. Out-of-band callers have no such ancestry — they only know
    /// the supervisor pid from the registry — so they descend instead.
    ///
    /// The supervisor's loop runs claude (or, if some unrelated process ever
    /// sits directly above it, that process) as its one foreground child, so
    /// that child's pid is trustworthy on its own: killing it cascades down
    /// to whatever is actually running underneath, regardless of what THAT
    /// process's own children look like. We still prefer a process whose
    /// comm names claude — that's what lets us return the actual claude pid
    /// rather than whatever intermediate process sits above it — but Claude
    /// Code itself reports its comm as a bare version string (e.g. "2.1.228"), so
    /// `isClaudeComm` can never match it directly, and while claude is busy it
    /// spawns its own children (MCP servers, tool subprocesses) — so the
    /// level below the supervisor's direct child branches constantly. That
    /// deeper branching must NOT invalidate the fallback: we are not choosing
    /// among the supervisor's own children there, we already know which one
    /// to signal.
    ///
    /// Ambiguity only matters at the FIRST level. If the supervisor itself
    /// has zero or several direct children, there is nothing to fall back to
    /// — picking one there really would be a guess, and the guess gets
    /// signalled, so a wrong one kills an unrelated process. A comm that
    /// names claude still wins immediately at any depth, first level or
    /// below.
    static func resolveClaudePidDownward(
        supervisorPid: Int32,
        maxDepth: Int = 8,
        children: (Int32) -> [Int32],
        lookup: (Int32) -> (ppid: Int32, comm: String)?
    ) -> Int32? {
        let firstLevel = children(supervisorPid)
        // Fixed once, from the first level only — see doc comment above for
        // why deeper branching must not touch this.
        let fallback: Int32? = firstLevel.count == 1 ? firstLevel.first : nil

        var frontier = firstLevel
        var depth = 0
        while !frontier.isEmpty, depth < maxDepth {
            for pid in frontier {
                if let info = lookup(pid), isClaudeComm(info.comm) {
                    return pid
                }
            }
            frontier = frontier.flatMap { children($0) }
            depth += 1
        }
        return fallback
    }

    /// Direct children of `pid`, via a full process-table snapshot.
    static func childPids(of pid: Int32) -> [Int32] {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

        let actual = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(actual)
            .filter { $0.kp_eproc.e_ppid == pid }
            .map { $0.kp_proc.p_pid }
        #else
        return []
        #endif
    }
}
