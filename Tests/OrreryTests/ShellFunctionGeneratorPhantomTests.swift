import Testing
@testable import OrreryCore

@Suite("ShellFunctionGenerator phantom")
struct ShellFunctionGeneratorPhantomTests {
    let script = ShellFunctionGenerator.generate(version: "9.9.9")

    @Test("the claude shim drives the supervisor loop")
    func loopInClaudeShim() {
        #expect(script.contains("_phantom-begin --tool claude --supervisor-pid $$"))
        #expect(script.contains("_phantom-next --id \"$ORRERY_PHANTOM_ID\""))
        #expect(script.contains("_phantom-end --id \"$ORRERY_PHANTOM_ID\""))
    }

    @Test("the supervisor pid is passed explicitly, never inferred")
    func explicitSupervisorPid() {
        // getppid() inside a $(...) substitution sees the transient subshell.
        #expect(script.contains("--supervisor-pid $$"))
    }

    @Test("fast-path guards short-circuit before any subcommand runs")
    func guards() {
        #expect(script.contains("${ORRERY_PHANTOM_ID:-}"))
        #expect(script.contains("${CLAUDECODE:-}"))
        #expect(script.contains("${ORRERY_NO_PHANTOM:-}"))
    }

    @Test("the loop calls the launch helper, never claude directly")
    func usesLaunchHelper() {
        #expect(script.contains("_orrery_claude_launch"))
    }

    @Test("prepare and capture still bracket the real claude binary")
    func prepareAndCapturePreserved() {
        #expect(script.contains("_prepare-claude-launch"))
        #expect(script.contains("_capture-claude-exit"))
        #expect(script.contains("command claude"))
    }

    @Test("orrery run no longer carries its own phantom loop")
    func runBranchHasNoLoop() {
        #expect(!script.contains("ORRERY_PHANTOM_SHELL_PID"))
        #expect(!script.contains("_phantom_sentinel"))
    }

    /// The text of the `run)` case only, not the whole script — an unscoped
    /// `script.contains("claude \"$@\"")` is also satisfied by the three
    /// `command claude "$@"` occurrences inside `_orrery_claude_launch`, so
    /// it can't fail even if the `run)` delegation itself were deleted.
    private func runCaseBody() -> Substring? {
        guard let runCaseStart = script.range(of: "\n    run)") else {
            Issue.record("run) case not found")
            return nil
        }
        guard let runCaseEnd = script.range(of: "\n    add)", range: runCaseStart.upperBound..<script.endIndex) else {
            Issue.record("add) case not found after run)")
            return nil
        }
        return script[runCaseStart.upperBound..<runCaseEnd.lowerBound]
    }

    @Test("orrery run claude delegates to the shim")
    func runDelegates() {
        guard let body = runCaseBody() else { return }
        #expect(body.contains("claude \"$@\""))
    }

    @Test("orrery run claude still strips claude IPC env vars before delegating")
    func runStripsIpcEnvBeforeDelegating() {
        // Bare `claude` never stripped these — this is `run claude`-specific,
        // preserved from the pre-shim loop so a nested `orrery run claude`
        // (typed inside another claude session) doesn't leak IPC vars into
        // the child and hang it waiting for an MCP host.
        guard let body = runCaseBody() else { return }
        #expect(body.contains("unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH"))
    }

    /// The text of the `claude()` shim's fast-path guard body only — between
    /// the guard's `if` and its closing `fi` — not the whole shim. An
    /// unscoped `script.contains("unset ORRERY_PHANTOM_ID")` would also be
    /// satisfied by the supervisor loop's own legitimate
    /// `unset ORRERY_PHANTOM_ID ORRERY_PHANTOM_DIR` after the loop exits, so
    /// it can't distinguish "fast-path clears it before launching" from
    /// "loop clears it on the way out".
    private func fastPathGuardBody() -> Substring? {
        let guardMarker = "if [ -n \"${ORRERY_PHANTOM_ID:-}\" ] || [ -n \"${CLAUDECODE:-}\" ] ||"
        guard let guardStart = script.range(of: guardMarker) else {
            Issue.record("claude() fast-path guard not found")
            return nil
        }
        guard let fiEnd = script.range(of: "\n  fi", range: guardStart.upperBound..<script.endIndex) else {
            Issue.record("closing fi for fast-path guard not found")
            return nil
        }
        return script[guardStart.upperBound..<fiEnd.lowerBound]
    }

    @Test("the claude shim fast-path clears ORRERY_PHANTOM_ID before launching directly")
    func fastPathClearsPhantomIdBeforeLaunch() {
        // Regression guard: a nested claude (or CLAUDECODE / ORRERY_NO_PHANTOM
        // fast-path) must not inherit an outer supervisor's ORRERY_PHANTOM_ID —
        // otherwise the nested claude's SessionStart hook stamps its own
        // session id into the OUTER supervisor's registry entry.
        guard let body = fastPathGuardBody() else { return }
        #expect(body.contains("unset ORRERY_PHANTOM_ID"))
        // The clear must happen before the fast-path launch call, not after.
        guard let unsetRange = body.range(of: "unset ORRERY_PHANTOM_ID"),
              let launchRange = body.range(of: "_orrery_claude_launch \"$@\"; return $?") else {
            Issue.record("expected both unset and the fast-path launch call in the guard body")
            return
        }
        #expect(unsetRange.upperBound <= launchRange.lowerBound)
    }
}
