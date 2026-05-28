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
}
