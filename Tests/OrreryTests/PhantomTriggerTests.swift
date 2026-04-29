import Testing
import Foundation
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

    @Test("sentinel is shell-sourceable with target env and session id")
    func sentinelRoundTrip() throws {
        try PhantomTriggerCommand.writeSentinel(targetEnv: "work", sessionId: "abc123-def", store: store)
        let url = PhantomTriggerCommand.sentinelURL(store: store)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("TARGET_ENV='work'"))
        #expect(text.contains("SESSION_ID='abc123-def'"))
        // Each assignment must be on its own line so `. sentinel` works under
        // both bash and zsh without surprises.
        #expect(text.contains("\n"))
    }

    @Test("sentinel handles nil session id (fresh conversation)")
    func sentinelNoSession() throws {
        try PhantomTriggerCommand.writeSentinel(targetEnv: "personal", sessionId: nil, store: store)
        let text = try String(contentsOf: PhantomTriggerCommand.sentinelURL(store: store), encoding: .utf8)
        #expect(text.contains("TARGET_ENV='personal'"))
        #expect(text.contains("SESSION_ID=''"))
    }

    @Test("sentinel escapes single quotes in env name (defensive)")
    func sentinelEscaping() throws {
        // Env names with quotes should never reach the sentinel (they're rejected
        // upstream by the create command), but test the shell escaping anyway
        // because this is the IPC trust boundary.
        try PhantomTriggerCommand.writeSentinel(targetEnv: "weird'name", sessionId: nil, store: store)
        let text = try String(contentsOf: PhantomTriggerCommand.sentinelURL(store: store), encoding: .utf8)
        #expect(text.contains(#"TARGET_ENV='weird'\''name'"#))
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

        let id = PhantomTriggerCommand.findCurrentClaudeSessionId()
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

        let id = PhantomTriggerCommand.findCurrentClaudeSessionId()
        #expect(id == nil)
    }

    // MARK: - Process discovery

    @Test("findClaudeAncestor returns nil when there's no claude in the parent chain")
    func findClaudeAncestorAbsent() {
        // Use this test process itself as the "supervisor". The test runner
        // is not running under claude, so walking up from getppid() will not
        // find any claude ancestor whose parent is this pid.
        let pid = getpid()
        let result = PhantomTriggerCommand.findClaudeAncestor(supervisorPid: pid)
        #expect(result == nil)
    }

    @Test("readProcessInfo returns ppid+comm for the current process")
    func readProcessInfoCurrent() {
        let info = PhantomTriggerCommand.readProcessInfo(pid: getpid())
        #expect(info != nil)
        // The test runner's parent should be either swift or xctest; comm is a
        // basename string, so just check it's non-empty and has no slashes.
        if let info {
            #expect(info.ppid > 0)
            #expect(!info.comm.isEmpty)
            #expect(!info.comm.contains("/"))
        }
    }
}

@Suite("ShellFunctionGenerator run case (phantom-by-default)")
struct ShellFunctionGeneratorRunTests {

    @Test("run case is wired into the orrery() function")
    func hasRunCase() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("run)"))
        #expect(script.contains("ORRERY_PHANTOM_SHELL_PID"))
        #expect(script.contains(".phantom-sentinel"))
    }

    @Test("run loop relaunches claude with --resume when sentinel carries SESSION_ID")
    func runLoopUsesResume() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("--resume"))
        #expect(script.contains("SESSION_ID"))
    }

    @Test("run loop calls 'orrery use' to switch envs between iterations")
    func runLoopSwitchesEnv() {
        let script = ShellFunctionGenerator.generate()
        // The loop must use the orrery() shell function (not orrery-bin directly)
        // so the env vars actually mutate the supervisor's shell — that's how the
        // child claude inherits the new env on the next iteration.
        #expect(script.contains("orrery use \"$TARGET_ENV\""))
    }

    @Test("run parses -e flag for the target env")
    func runAcceptsEnvFlag() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("-e|--env"))
        #expect(script.contains("_run_target"))
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
    private func assertDispatchSelectsPhantom(shell: String) throws {
        // Skip if the shell isn't installed in this environment.
        guard FileManager.default.isExecutableFile(atPath: "/bin/\(shell)")
            || FileManager.default.isExecutableFile(atPath: "/usr/bin/\(shell)") else {
            return
        }
        let script = ShellFunctionGenerator.generate()

        // Stub `command` so the supervisor loop's `command claude` and the
        // fallthrough's `command orrery-bin run` both print a marker and
        // immediately return success — preventing actual claude launches and
        // making the supervisor loop exit on its first iteration (sentinel
        // missing → break).
        let probe = """
        \(script)

        command() {
          case "$1" in
            claude) echo PHANTOM_BRANCH ;;
            orrery-bin)
              shift
              if [ "$1" = "run" ]; then echo FALLTHROUGH_BRANCH; fi
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
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        #expect(out.contains("PHANTOM_BRANCH"), "[\(shell)] expected phantom branch, got: \(out)")
        #expect(!out.contains("FALLTHROUGH_BRANCH"), "[\(shell)] should not fall through to orrery-bin run, got: \(out)")
    }

    @Test("run honors -- separator for unambiguous claude args")
    func runHonorsDoubleDash() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("--)"))
    }

    @Test("run loop strips claude IPC env vars to prevent nested-claude hangs")
    func runStripsIpcEnv() {
        let script = ShellFunctionGenerator.generate()
        // Defensive: matches the same stripping RunCommand.swift does for the
        // single-shot path.
        #expect(script.contains("CLAUDECODE"))
        #expect(script.contains("CLAUDE_CODE_ENTRYPOINT"))
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
