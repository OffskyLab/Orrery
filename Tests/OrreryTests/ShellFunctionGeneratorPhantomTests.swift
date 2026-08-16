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

    @Test("orrery run claude delegates to the shim")
    func runDelegates() {
        #expect(script.contains("claude \"$@\""))
    }

    @Test("orrery run claude still strips claude IPC env vars before delegating")
    func runStripsIpcEnvBeforeDelegating() {
        // Bare `claude` never stripped these — this is `run claude`-specific,
        // preserved from the pre-shim loop so a nested `orrery run claude`
        // (typed inside another claude session) doesn't leak IPC vars into
        // the child and hang it waiting for an MCP host. Scoped to the run)
        // case specifically, not just "somewhere in the script", so this
        // can't silently move to (or vanish from) the wrong branch.
        guard let runCaseStart = script.range(of: "\n    run)") else {
            Issue.record("run) case not found")
            return
        }
        guard let runCaseEnd = script.range(of: "\n    add)", range: runCaseStart.upperBound..<script.endIndex) else {
            Issue.record("add) case not found after run)")
            return
        }
        let runCaseBody = script[runCaseStart.upperBound..<runCaseEnd.lowerBound]
        #expect(runCaseBody.contains("unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH"))
    }
}
