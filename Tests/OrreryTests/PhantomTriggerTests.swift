import Testing
import Foundation
import Synchronization
@testable import OrreryCore

@Suite("PhantomTrigger")
struct PhantomTriggerTests {
    var tmpDir: URL!
    var store: EnvironmentStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-phantom-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = EnvironmentStore(homeURL: tmpDir)
    }

    // MARK: - Sentinel format

    @Test("sentinel is shell-sourceable with target account and session id")
    func sentinelRoundTrip() throws {
        let url = tmpDir.appendingPathComponent("sentinel")
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "work",
            sessionId: "abc123-def", to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("TARGET_ACCOUNT_TOOL='claude'"))
        #expect(text.contains("TARGET_ACCOUNT_NAME='work'"))
        #expect(text.contains("SESSION_ID='abc123-def'"))
        // Each assignment must be on its own line so `. sentinel` works under
        // both bash and zsh without surprises.
        #expect(text.contains("\n"))
    }

    @Test("sentinel handles nil session id (fresh conversation)")
    func sentinelNoSession() throws {
        let url = tmpDir.appendingPathComponent("sentinel")
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "personal",
            sessionId: nil, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("TARGET_ACCOUNT_NAME='personal'"))
        #expect(text.contains("SESSION_ID=''"))
    }

    @Test("sentinel escapes single quotes in account name (defensive)")
    func sentinelEscaping() throws {
        // Account names with quotes should never reach the sentinel (they're
        // rejected upstream), but test the shell escaping anyway because this
        // is the IPC trust boundary.
        let url = tmpDir.appendingPathComponent("sentinel")
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "weird'name",
            sessionId: nil, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(#"TARGET_ACCOUNT_NAME='weird'\''name'"#))
    }

    // MARK: - Session id discovery

    @Test("findCurrentClaudeSessionId returns latest jsonl by mtime")
    func findsLatestSession() throws {
        // Simulate Claude's session layout: $CLAUDE_CONFIG_DIR/projects/<encoded-cwd>/<id>.jsonl
        let claudeDir = tmpDir.appendingPathComponent("claude-config")
        let cwd = FileManager.default.currentDirectoryPath
        let projectKey = cwd.replacingOccurrences(of: "/", with: "-")
        let projectsDir = claudeDir
            .appendingPathComponent("projects")
            .appendingPathComponent(projectKey)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        let oldFile = projectsDir.appendingPathComponent("old-session-id.jsonl")
        let newFile = projectsDir.appendingPathComponent("new-session-id.jsonl")
        try Data().write(to: oldFile)
        try Data().write(to: newFile)
        // Force mtime ordering so the test isn't a race.
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: oldFile.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: newFile.path)

        // Override CLAUDE_CONFIG_DIR for the duration of the call.
        let prev = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        setenv("CLAUDE_CONFIG_DIR", claudeDir.path, 1)
        defer {
            if let prev { setenv("CLAUDE_CONFIG_DIR", prev, 1) }
            else { unsetenv("CLAUDE_CONFIG_DIR") }
        }

        let id = PhantomSupport.findCurrentClaudeSessionId()
        #expect(id == "new-session-id")
    }

    @Test("findCurrentClaudeSessionId returns nil when project dir is missing")
    func findsNothingWhenAbsent() throws {
        let claudeDir = tmpDir.appendingPathComponent("empty-claude-config")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let prev = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        setenv("CLAUDE_CONFIG_DIR", claudeDir.path, 1)
        defer {
            if let prev { setenv("CLAUDE_CONFIG_DIR", prev, 1) }
            else { unsetenv("CLAUDE_CONFIG_DIR") }
        }

        let id = PhantomSupport.findCurrentClaudeSessionId()
        #expect(id == nil)
    }

    // MARK: - Process discovery

    @Test("findClaudeAncestor returns nil when there's no claude in the parent chain")
    func findClaudeAncestorAbsent() {
        // Use this test process itself as the "supervisor". The test runner
        // is not running under claude, so walking up from getppid() will not
        // find any claude ancestor whose parent is this pid.
        let pid = getpid()
        let result = PhantomSupport.findClaudeAncestor(supervisorPid: pid)
        #expect(result == nil)
    }

    @Test("readProcessInfo returns ppid+comm for the current process")
    func readProcessInfoCurrent() {
        let info = PhantomSupport.readProcessInfo(pid: getpid())
        #expect(info != nil)
        // The test runner's parent should be either swift or xctest; comm is a
        // basename string, so just check it's non-empty and has no slashes.
        if let info {
            #expect(info.ppid > 0)
            #expect(!info.comm.isEmpty)
            #expect(!info.comm.contains("/"))
        }
    }

    // MARK: - resolveClaudePid (pure ancestry walk)

    /// Build a synthetic (pid -> ppid, comm) lookup for the pure walk tests.
    private func lookup(_ tree: [Int32: (ppid: Int32, comm: String)])
        -> (Int32) -> (ppid: Int32, comm: String)? {
        { tree[$0] }
    }

    @Test("resolveClaudePid: renamed claude (version comm) resolves via supervisor's child")
    func resolveRenamedClaude() {
        // The real-world break: claude reports its comm as the version string
        // (e.g. "2.1.201"), not "claude". 100(zsh) -> 200(claude) -> 300(supervisor).
        let tree: [Int32: (ppid: Int32, comm: String)] = [
            100: (200, "zsh"),
            200: (300, "2.1.201"),
            300: (400, "zsh"),
        ]
        let r = PhantomSupport.resolveClaudePid(
            start: 100, supervisorPid: 300, lookup: lookup(tree))
        #expect(r.reachedSupervisor)
        #expect(r.claudePid == 200)
    }

    @Test("resolveClaudePid: claude named 'claude' resolves via name match")
    func resolveNamedClaude() {
        let tree: [Int32: (ppid: Int32, comm: String)] = [
            100: (200, "zsh"),
            200: (300, "claude"),
            300: (400, "zsh"),
        ]
        let r = PhantomSupport.resolveClaudePid(
            start: 100, supervisorPid: 300, lookup: lookup(tree))
        #expect(r.claudePid == 200)
    }

    @Test("resolveClaudePid: a name match wins over the supervisor's child (wrapper case)")
    func resolveNamedClaudeBehindWrapper() {
        // supervisor -> caffeinate -> claude: return the real claude, not caffeinate.
        // 100(zsh) -> 200(claude) -> 250(caffeinate) -> 300(supervisor).
        let tree: [Int32: (ppid: Int32, comm: String)] = [
            100: (200, "zsh"),
            200: (250, "claude"),
            250: (300, "caffeinate"),
            300: (400, "zsh"),
        ]
        let r = PhantomSupport.resolveClaudePid(
            start: 100, supervisorPid: 300, lookup: lookup(tree))
        #expect(r.claudePid == 200)
    }

    @Test("resolveClaudePid: nil when the supervisor is never reached")
    func resolveSupervisorNotReached() {
        let tree: [Int32: (ppid: Int32, comm: String)] = [
            100: (200, "zsh"),
            200: (1, "zsh"),
        ]
        let r = PhantomSupport.resolveClaudePid(
            start: 100, supervisorPid: 999, lookup: lookup(tree))
        #expect(!r.reachedSupervisor)
        #expect(r.claudePid == nil)
    }

    @Test("isClaudeComm accepts claude/claude.exe, rejects version and helper names")
    func isClaudeCommMatching() {
        #expect(PhantomSupport.isClaudeComm("claude"))
        #expect(PhantomSupport.isClaudeComm("claude.exe"))
        #expect(!PhantomSupport.isClaudeComm("2.1.201"))
        #expect(!PhantomSupport.isClaudeComm("claude-helper"))
    }

    // MARK: - Downward resolution (out-of-band triggering)

    /// Fake tree helper: children maps parent -> [child], comms maps pid -> comm.
    private func downward(
        supervisor: Int32,
        children: [Int32: [Int32]],
        comms: [Int32: String]
    ) -> Int32? {
        PhantomSupport.resolveClaudePidDownward(
            supervisorPid: supervisor,
            children: { children[$0] ?? [] },
            lookup: { pid in comms[pid].map { (ppid: Int32(0), comm: $0) } })
    }

    @Test("finds a claude that is a direct child of the supervisor")
    func downwardDirectChild() {
        #expect(downward(supervisor: 10, children: [10: [11]],
                         comms: [10: "zsh", 11: "claude"]) == 11)
    }

    @Test("finds claude behind a caffeinate wrapper")
    func downwardThroughWrapper() {
        #expect(downward(supervisor: 10, children: [10: [11], 11: [12]],
                         comms: [10: "zsh", 11: "caffeinate", 12: "claude"]) == 12)
    }

    @Test("matches the Bun-compiled claude.exe comm")
    func downwardBunName() {
        #expect(downward(supervisor: 10, children: [10: [11]],
                         comms: [10: "zsh", 11: "claude.exe"]) == 11)
    }

    @Test("falls back to the only child when nothing is named claude")
    func downwardVersionStringComm() {
        // Claude Code often reports its comm as a bare version string.
        #expect(downward(supervisor: 10, children: [10: [11]],
                         comms: [10: "zsh", 11: "2.1.201"]) == 11)
    }

    @Test("returns nil when the supervisor has no children")
    func downwardNoChildren() {
        #expect(downward(supervisor: 10, children: [:], comms: [10: "zsh"]) == nil)
    }

    @Test("prefers the claude-named process over an unrelated sibling")
    func downwardPrefersNamed() {
        #expect(downward(supervisor: 10, children: [10: [11, 12]],
                         comms: [10: "zsh", 11: "sleep", 12: "claude"]) == 12)
    }

    @Test("does not mistarget a helper process whose name merely starts with claude")
    func downwardIgnoresHelper() {
        #expect(downward(supervisor: 10, children: [10: [11], 11: [12]],
                         comms: [10: "zsh", 11: "claude-helper", 12: "claude"]) == 12)
    }

    @Test("a busy claude with several of its own children still resolves via the first-level fallback")
    func downwardBusyClaudeWithChildrenStillResolves() {
        // Real-world case: claude's own comm is a version string (e.g.
        // "2.1.228"), so isClaudeComm never matches it, and while claude is
        // busy it spawns its own children (MCP servers, tool subprocesses) —
        // branching one level below the supervisor's unique direct child.
        // That deeper branching must not erase the fallback: the
        // supervisor's own child is still the right answer regardless of
        // what its own children look like.
        #expect(downward(
            supervisor: 10,
            children: [10: [11], 11: [12, 13, 14]],
            comms: [10: "zsh", 11: "2.1.228", 12: "worker", 13: "worker", 14: "worker"]) == 11)
    }

    @Test("an ambiguous tree with no claude-named process returns nil rather than guessing")
    func downwardRefusesToGuessWhenAmbiguous() {
        // Two unnamed branches: any pid we picked here would be a guess, and
        // the caller signals whatever it gets back.
        #expect(downward(supervisor: 10, children: [10: [11, 12], 11: [13]],
                         comms: [10: "zsh", 11: "sleep", 12: "node", 13: "tail"]) == nil)
    }

    @Test("a chain deeper than maxDepth stops without returning a deeper pid")
    func downwardStopsAtMaxDepth() {
        // A 10-link unnamed chain against the default maxDepth of 8.
        var children: [Int32: [Int32]] = [:]
        var comms: [Int32: String] = [10: "zsh"]
        for i in Int32(10)..<Int32(20) {
            children[i] = [i + 1]
            comms[i + 1] = "worker"
        }
        let result = downward(supervisor: 10, children: children, comms: comms)
        // Truncation must not reach the tail of the chain.
        #expect(result != 20)
    }
}

@Suite("ShellFunctionGenerator run case (phantom-by-default)")
struct ShellFunctionGeneratorRunTests {

    @Test("run case is wired into the orrery() function and delegates to the claude shim")
    func hasRunCase() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("run)"))
        // Task 10: the supervisor loop (and its per-shell sentinel file) moved
        // out of `run)` and into the claude() shim, so bare `claude` gets
        // supervision too. `run)`'s claude branch is now a thin alias.
        #expect(!script.contains("ORRERY_PHANTOM_SHELL_PID"))
        #expect(!script.contains(".phantom-sentinel"))
        #expect(script.contains("claude \"$@\""))
    }

    @Test("resume-on-relaunch now lives behind _phantom-next, not shell-parsed SESSION_ID")
    func runLoopUsesResume() {
        let script = ShellFunctionGenerator.generate()
        // The shell used to `. `-source a sentinel and read a SESSION_ID var
        // itself. That parsing (and the --resume argv it built) moved into
        // PhantomNextCommand.resumeSetLine — the shell only `eval`s whatever
        // `_phantom-next` prints.
        #expect(!script.contains("SESSION_ID"))
        #expect(script.contains("_phantom-next --id \"$ORRERY_PHANTOM_ID\""))
        #expect(script.contains("eval \"$_next\""))
    }

    @Test("account switching now lives behind _phantom-next's eval-able export line")
    func runLoopSwitchesAccount() {
        let script = ShellFunctionGenerator.generate()
        // TARGET_ACCOUNT_TOOL/NAME and the shell-level `orrery use --tool
        // name` call are gone — PhantomNextCommand resolves the account dir
        // itself and prints an `export CLAUDE_CONFIG_DIR=...` line for the
        // loop to `eval`, because a child process can't export into its
        // parent shell any other way (see PhantomNextCommand.swift).
        #expect(!script.contains("TARGET_ACCOUNT_TOOL"))
        #expect(!script.contains("TARGET_ACCOUNT_NAME"))
        #expect(!script.contains(#"orrery use --"$TARGET_ACCOUNT_TOOL" "$TARGET_ACCOUNT_NAME""#))
        #expect(script.contains("eval \"$_next\""))
    }

    @Test("orrery enter/exit and sandbox-level workspace switching are gone")
    func enterExitRemoved() {
        let script = ShellFunctionGenerator.generate()
        #expect(!script.contains("TARGET_SANDBOX"))
        #expect(!script.contains("orrery enter"))
        #expect(!script.contains("orrery exit"))
        #expect(!script.contains("orrery-bin sandbox"))
    }

    @Test("run parses -e flag for the target env (non-phantom fallback only)")
    func runAcceptsEnvFlag() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("-e|--env"))
        #expect(script.contains("_run_target"))
        // Phantom claude no longer supports -e — account switching is `orrery use`.
        #expect(script.contains("is not supported for claude"))
    }

    @Test("run accepts --non-phantom to opt out of supervisor mode")
    func runAcceptsNonPhantomFlag() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("--non-phantom"))
        #expect(script.contains("_run_non_phantom"))
    }

    @Test("phantom mode only kicks in when the command is claude")
    func runPhantomOnlyForClaude() {
        let script = ShellFunctionGenerator.generate()
        // Non-claude commands and --non-phantom invocations must fall through
        // to `orrery-bin run`, preserving the prior single-shot behavior.
        // We use $1 (positional param) instead of ${_run_args[0]} because zsh
        // arrays are 1-indexed by default — that bug shipped briefly and made
        // every `orrery run claude` silently take the non-phantom branch.
        #expect(script.contains(#"[ "${1:-}" = "claude" ]"#))
        #expect(!script.contains("${_run_args[0]"))
        #expect(script.contains("command orrery-bin run"))
    }

    @Test("dispatch under bash actually selects phantom branch for `run claude`")
    func dispatchBash() throws {
        try assertDispatchSelectsPhantom(shell: "bash")
    }

    @Test("dispatch under zsh actually selects phantom branch for `run claude`")
    func dispatchZsh() throws {
        try assertDispatchSelectsPhantom(shell: "zsh")
    }

    /// End-to-end shell test: source the generated activate.sh, intercept the
    /// child invocations (`command claude` / `command orrery-bin run`) with
    /// echo stubs, run `orrery run claude`, and assert which branch fired.
    /// This is the regression guard against the zsh 0-vs-1-indexed-array bug
    /// that substring tests can miss.
    ///
    /// Since Task 10, `run claude` delegates to the claude() shim, which
    /// calls `orrery-bin _phantom-begin` before it will loop at all. The stub
    /// below makes `_phantom-begin` fail (`return 1`), which is also what the
    /// real binary does outside a TTY — exactly this test's situation — so
    /// the shim takes its documented "just launch once" fallback
    /// (`_orrery_claude_launch "$@"; return $?`) without ever entering the
    /// loop. This also sidesteps a real trap: a stub whose unmatched `case`
    /// arms fall through with exit 0 (the shell default for "no commands
    /// ran") makes `_phantom-next`'s `|| break` never fire, looping forever —
    /// confirmed by hand while writing this fix. Only reaching `_phantom-next`
    /// at all would require the stub to emulate the whole begin/next/end
    /// protocol faithfully; failing at `_phantom-begin` avoids that entirely.
    private func assertDispatchSelectsPhantom(shell: String) throws {
        // Skip if the shell isn't installed in this environment.
        guard FileManager.default.isExecutableFile(atPath: "/bin/\(shell)")
            || FileManager.default.isExecutableFile(atPath: "/usr/bin/\(shell)") else {
            return
        }
        let script = ShellFunctionGenerator.generate()

        let probe = """
        \(script)

        command() {
          case "$1" in
            claude) echo PHANTOM_BRANCH ;;
            orrery-bin)
              shift
              case "$1" in
                run) echo FALLTHROUGH_BRANCH ;;
                _phantom-begin) return 1 ;;
              esac
              ;;
          esac
        }

        # _orrery_init touches the network / filesystem; bypass for a clean run.
        _orrery_init() { :; }

        orrery run claude
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [shell, "-c", probe]
        // Explicit clean slate: this process must decide PHANTOM_BRANCH vs.
        // FALLTHROUGH_BRANCH purely from the script under test, never from
        // whatever happens to be set in the host running the test suite
        // (e.g. CLAUDECODE, which — if inherited — would make the claude()
        // shim's own no-supervise guard fire first and mask what this test
        // is actually trying to exercise).
        var env = ProcessInfo.processInfo.environment
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH",
                    "ORRERY_PHANTOM_ID", "ORRERY_NO_PHANTOM", "CLAUDE_CONFIG_DIR"] {
            env.removeValue(forKey: key)
        }
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()

        // Watchdog: a regression that reintroduces an unconditional loop
        // (see the doc comment above) would otherwise hang this test —  and
        // therefore the whole suite, and CI — forever with no diagnostic.
        let timedOut = Mutex(false)
        let watchdog = DispatchQueue(label: "phantom-dispatch-watchdog")
        watchdog.asyncAfter(deadline: .now() + 5) {
            if proc.isRunning {
                timedOut.withLock { $0 = true }
                proc.terminate()
            }
        }
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        #expect(!timedOut.withLock { $0 }, "[\(shell)] supervisor loop did not terminate within 5s — see doc comment")
        #expect(out.contains("PHANTOM_BRANCH"), "[\(shell)] expected phantom branch, got: \(out)")
        #expect(!out.contains("FALLTHROUGH_BRANCH"), "[\(shell)] should not fall through to orrery-bin run, got: \(out)")
    }

    @Test("run honors -- separator for unambiguous claude args")
    func runHonorsDoubleDash() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("--)"))
    }

    @Test("the claude shim treats CLAUDECODE as a no-supervise guard, not something to strip")
    func runStripsIpcEnv() {
        let script = ShellFunctionGenerator.generate()
        // Task 10 deviation from the pre-shim design: `orrery run claude`
        // used to `unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH`
        // before its loop, specifically so a nested invocation (this command
        // typed inside another claude session) wouldn't leak IPC vars into
        // the child and hang it waiting for an MCP host. Now that `run)`
        // delegates to the claude() shim, CLAUDECODE is instead read as a
        // guard: if set, supervision is skipped entirely and the launch goes
        // straight through _orrery_claude_launch — but the var itself is no
        // longer stripped before that launch. Bare `claude` never stripped
        // it either, so this only regresses `orrery run claude`'s specific
        // nested-invocation case, and only once removed from a real hang:
        // it's the same as typing bare `claude` inside a nested shell.
        #expect(script.contains("${CLAUDECODE:-}"))
    }

    @Test("legacy 'phantom' subcommand is no longer present")
    func legacyPhantomCaseRemoved() {
        let script = ShellFunctionGenerator.generate()
        // The phantom-by-default refactor folded the loop into `run`. The old
        // case used these identifiers, which the run-case version replaces with
        // _run_target / _run_args. (Plain `phantom)` would false-match the new
        // `--non-phantom)` inner case.)
        #expect(!script.contains("_phantom_target"))
        #expect(!script.contains("_phantom_init_args"))
    }
}
