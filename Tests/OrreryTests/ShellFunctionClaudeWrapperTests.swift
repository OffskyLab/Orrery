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

    @Test("claude() wrapper calls _prepare-claude-launch before command claude")
    func callsPrepareBeforeClaude() {
        let sh = ShellFunctionGenerator.generate()
        guard let claudeFnStart = sh.range(of: "claude() {") else {
            Issue.record("claude() function not found")
            return
        }
        let body = String(sh[claudeFnStart.lowerBound...])

        let prepareIdx = body.range(of: "_prepare-claude-launch")?.lowerBound
        let commandClaudeIdx = body.range(of: "command claude")?.lowerBound

        #expect(prepareIdx != nil, "claude() should call _prepare-claude-launch")
        #expect(commandClaudeIdx != nil, "claude() should call command claude")
        if let p = prepareIdx, let c = commandClaudeIdx {
            #expect(p < c, "_prepare-claude-launch should run before command claude")
        }
    }

    @Test("claude() wrapper calls _capture-claude-exit after command claude")
    func callsCaptureAfterClaude() {
        let sh = ShellFunctionGenerator.generate()
        guard let claudeFnStart = sh.range(of: "claude() {") else {
            Issue.record("claude() function not found")
            return
        }
        let body = String(sh[claudeFnStart.lowerBound...])

        let commandClaudeIdx = body.range(of: "command claude")?.lowerBound
        let captureIdx = body.range(of: "_capture-claude-exit")?.lowerBound

        #expect(captureIdx != nil, "claude() should call _capture-claude-exit")
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

    @Test("phantom loop invokes the claude wrapper function, not the bare binary")
    func phantomLoopUsesFunction() {
        let sh = ShellFunctionGenerator.generate()
        // The phantom supervisor loop is the `while true; do … claude … ; done`
        // block. Find that block and confirm the inner claude invocation does
        // NOT use `command claude` (which would bypass our wrapper).
        guard let loopStart = sh.range(of: "while true; do") else {
            Issue.record("phantom while-true loop not found")
            return
        }
        guard let loopEnd = sh.range(of: "done\n", range: loopStart.upperBound..<sh.endIndex) else {
            Issue.record("phantom loop end (done) not found after while-true")
            return
        }
        let body = String(sh[loopStart.upperBound..<loopEnd.lowerBound])
        #expect(!body.contains("command claude"),
            "phantom loop should call `claude` (the function), not `command claude` (the binary)")
        #expect(body.contains("\nclaude ") || body.contains("\nclaude\n") || body.contains(" claude "),
            "phantom loop should call the claude function")
    }

    @Test("claude() prepare failure echoes to stderr (does not silently swallow)")
    func prepareFailureSurfaces() {
        let sh = ShellFunctionGenerator.generate()
        guard let claudeFnStart = sh.range(of: "claude() {") else {
            Issue.record("claude() function not found")
            return
        }
        let body = String(sh[claudeFnStart.lowerBound...])
        // The prepare call should either not redirect stderr, or have an
        // explicit echo to stderr on failure. Either way, a failed prepare
        // must be observable to the user.
        let hasStderrSurface = body.contains("orrery: prepare")
            || body.contains(">&2 echo")
            || !body.contains("_prepare-claude-launch --account-dir \"$CLAUDE_CONFIG_DIR\" 2>/dev/null")
        #expect(hasStderrSurface,
            "prepare failure must surface to stderr (not be silenced by 2>/dev/null)")
    }

    @Test("phantom loop account switch routes through orrery use shell function")
    func phantomAccountSwitchUsesShellFunction() {
        let sh = ShellFunctionGenerator.generate()
        guard let loopStart = sh.range(of: "while true; do") else {
            Issue.record("phantom loop not found")
            return
        }
        guard let loopEnd = sh.range(of: "done\n", range: loopStart.upperBound..<sh.endIndex) else {
            Issue.record("phantom loop end not found")
            return
        }
        let body = String(sh[loopStart.upperBound..<loopEnd.lowerBound])
        // Find the account-switch line — it should NOT use `command orrery-bin use`
        // (which would bypass our v3.1 `use)` case and leave CLAUDE_CONFIG_DIR stale).
        if body.contains("TARGET_ACCOUNT_TOOL") {
            #expect(!body.contains("command orrery-bin use"),
                "phantom account switch should call `orrery use` (shell function), not `command orrery-bin use`")
        }
    }
}
