import Foundation
import Testing
@testable import OrreryCore

@Suite("ShellFunctionGenerator claude() wrapper")
struct ShellFunctionClaudeWrapperTests {

    @Test("generated activate.sh contains a top-level claude() function")
    func declaresClaudeFunction() {
        let sh = ShellFunctionGenerator.generate()
        #expect(sh.contains("claude() {"),
            "generated activate.sh should declare claude() function")
    }

    @Test("_orrery_claude_launch calls _prepare-claude-launch before command claude")
    func callsPrepareBeforeClaude() {
        let sh = ShellFunctionGenerator.generate()
        // Task 10: prepare/capture moved out of claude() itself and into
        // _orrery_claude_launch, a helper the supervisor loop calls once per
        // iteration (each relaunch may land on a different account dir).
        guard let fnStart = sh.range(of: "_orrery_claude_launch() {") else {
            Issue.record("_orrery_claude_launch() function not found")
            return
        }
        let body = String(sh[fnStart.lowerBound...])

        let prepareIdx = body.range(of: "_prepare-claude-launch")?.lowerBound
        let commandClaudeIdx = body.range(of: "command claude")?.lowerBound

        #expect(prepareIdx != nil, "_orrery_claude_launch should call _prepare-claude-launch")
        #expect(commandClaudeIdx != nil, "_orrery_claude_launch should call command claude")
        if let p = prepareIdx, let c = commandClaudeIdx {
            #expect(p < c, "_prepare-claude-launch should run before command claude")
        }
    }

    @Test("_orrery_claude_launch calls _capture-claude-exit after command claude")
    func callsCaptureAfterClaude() {
        let sh = ShellFunctionGenerator.generate()
        guard let fnStart = sh.range(of: "_orrery_claude_launch() {") else {
            Issue.record("_orrery_claude_launch() function not found")
            return
        }
        let body = String(sh[fnStart.lowerBound...])

        let commandClaudeIdx = body.range(of: "command claude")?.lowerBound
        let captureIdx = body.range(of: "_capture-claude-exit")?.lowerBound

        #expect(captureIdx != nil, "_orrery_claude_launch should call _capture-claude-exit")
        if let c = commandClaudeIdx, let cap = captureIdx {
            #expect(c < cap, "_capture-claude-exit should run after command claude")
        }
    }

    @Test("claude() wrapper checks CLAUDE_CONFIG_DIR + metadata.json before wrapping")
    func shortCircuitsWithoutV31Marker() {
        let sh = ShellFunctionGenerator.generate()
        #expect(sh.contains("CLAUDE_CONFIG_DIR"))
        #expect(sh.contains("metadata.json"),
            "v3.1 marker check should be presence of metadata.json in the account dir")
    }

    @Test("phantom loop invokes the launch helper, not the bare binary directly")
    func phantomLoopUsesFunction() {
        let sh = ShellFunctionGenerator.generate()
        // Task 10: the supervisor loop now lives inside claude() itself (not
        // a separate `run)` branch calling the `claude` function), so its
        // per-iteration launch goes through _orrery_claude_launch — the only
        // place `command claude` (the real binary) appears.
        //
        // Scoped to the claude() function body specifically: `sh.range(of:
        // "while true; do")` alone would match the EARLIER, unrelated
        // `add)` case's background heal-hook loop first — a pre-existing
        // false-anchor risk this task's refactor exposed by moving the real
        // phantom loop's textual shape.
        guard let claudeFnStart = sh.range(of: "claude() {") else {
            Issue.record("claude() function not found")
            return
        }
        let claudeBody = sh[claudeFnStart.lowerBound...]
        guard let loopStart = claudeBody.range(of: "while true; do") else {
            Issue.record("phantom while-true loop not found inside claude()")
            return
        }
        guard let loopEnd = claudeBody.range(of: "done\n", range: loopStart.upperBound..<claudeBody.endIndex) else {
            Issue.record("phantom loop end (done) not found after while-true")
            return
        }
        let body = String(claudeBody[loopStart.upperBound..<loopEnd.lowerBound])
        #expect(!body.contains("command claude"),
            "phantom loop should call _orrery_claude_launch, not `command claude` directly")
        #expect(body.contains("_orrery_claude_launch"),
            "phantom loop should call the launch helper")
    }

    @Test("_orrery_claude_launch prepare failure echoes to stderr (does not silently swallow)")
    func prepareFailureSurfaces() {
        let sh = ShellFunctionGenerator.generate()
        guard let fnStart = sh.range(of: "_orrery_claude_launch() {") else {
            Issue.record("_orrery_claude_launch() function not found")
            return
        }
        let body = String(sh[fnStart.lowerBound...])
        // The prepare call should either not redirect stderr, or have an
        // explicit echo to stderr on failure. Either way, a failed prepare
        // must be observable to the user.
        let hasStderrSurface = body.contains("orrery: prepare")
            || body.contains(">&2 echo")
            || !body.contains("_prepare-claude-launch --account-dir \"$CLAUDE_CONFIG_DIR\" 2>/dev/null")
        #expect(hasStderrSurface,
            "prepare failure must surface to stderr (not be silenced by 2>/dev/null)")
    }

    @Test("_orrery_claude_launch links workspace for bare origin launch (CLAUDE_CONFIG_DIR unset)")
    func linksWorkspaceForBareOriginLaunch() {
        let sh = ShellFunctionGenerator.generate()
        guard let fnStart = sh.range(of: "_orrery_claude_launch() {") else {
            Issue.record("_orrery_claude_launch() function not found")
            return
        }
        let body = String(sh[fnStart.lowerBound...])
        // When CLAUDE_CONFIG_DIR is unset, ~/.claude is the origin account dir.
        // The wrapper must still sync workspace symlinks against it, using
        // --links-only (bare origin reads ~/.claude.json, so NO .claude.json merge).
        #expect(body.contains("$HOME/.claude/metadata.json"),
            "wrapper should detect the origin account dir at ~/.claude when CLAUDE_CONFIG_DIR is unset")
        #expect(body.contains("--links-only"),
            "bare origin launch should sync workspace symlinks via --links-only")
    }

    @Test("phantom loop account switch never bypasses the v3.1 export path")
    func phantomAccountSwitchUsesShellFunction() {
        let sh = ShellFunctionGenerator.generate()
        // Scoped to claude()'s body — see phantomLoopUsesFunction above for
        // why an unscoped search for "while true; do" is unsafe.
        guard let claudeFnStart = sh.range(of: "claude() {") else {
            Issue.record("claude() function not found")
            return
        }
        let claudeBody = sh[claudeFnStart.lowerBound...]
        guard let loopStart = claudeBody.range(of: "while true; do") else {
            Issue.record("phantom loop not found inside claude()")
            return
        }
        guard let loopEnd = claudeBody.range(of: "done\n", range: loopStart.upperBound..<claudeBody.endIndex) else {
            Issue.record("phantom loop end not found")
            return
        }
        let body = String(claudeBody[loopStart.upperBound..<loopEnd.lowerBound])
        // Task 10: the account switch is no longer a shell-level sentinel
        // dispatched to `orrery use` — `_phantom-next` prints an `export
        // CLAUDE_CONFIG_DIR=...` line directly (see PhantomNextCommand.swift)
        // for the loop to `eval`. There should be no `orrery-bin use` call of
        // any kind left in the loop body.
        #expect(!body.contains("TARGET_ACCOUNT_TOOL"))
        #expect(!body.contains("orrery-bin use"))
        #expect(body.contains("eval \"$_next\""),
            "phantom account switch should be applied by eval'ing _phantom-next's output")
    }
}
