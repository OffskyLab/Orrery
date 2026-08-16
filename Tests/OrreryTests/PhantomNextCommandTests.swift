import Testing
import Foundation
@testable import OrreryCore

@Suite("PhantomNextCommand")
struct PhantomNextCommandTests {
    var tmpDir: URL!
    var registry: PhantomRegistry!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-phantom-next-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        registry = PhantomRegistry(homeURL: tmpDir)
        try registry.write(PhantomEntry(
            supervisorPid: 4242, supervisorStartedAt: 1.0, tool: "claude",
            tty: nil, cwd: "/tmp/project", workspace: "origin", account: "old",
            sessionId: nil, sessionIdSource: .probe, updatedAt: 1.0), id: "4242")
    }

    // MARK: - resumeSetLine

    @Test("the resume set-line carries --resume plus a quoted session id")
    func resumeLineWithSession() {
        #expect(PhantomNextCommand.resumeSetLine(sessionId: "abc-123") == "set -- --resume 'abc-123'")
    }

    @Test("the resume set-line is bare `set --` when there is no session to resume")
    func resumeLineWithoutSession() {
        #expect(PhantomNextCommand.resumeSetLine(sessionId: nil) == "set --")
    }

    @Test("a session id containing a quote is safely quoted for eval")
    func quotedSessionId() {
        #expect(PhantomNextCommand.resumeSetLine(sessionId: "a'b") == #"set -- --resume 'a'\''b'"#)
    }

    // MARK: - exportVarName

    @Test("claude exports CLAUDE_CONFIG_DIR")
    func claudeVarName() {
        #expect(PhantomNextCommand.exportVarName(forTool: "claude") == "CLAUDE_CONFIG_DIR")
    }

    @Test("codex exports CODEX_HOME")
    func codexVarName() {
        #expect(PhantomNextCommand.exportVarName(forTool: "codex") == "CODEX_HOME")
    }

    @Test("gemini exports ORRERY_GEMINI_HOME, not GEMINI_CONFIG_DIR")
    func geminiVarName() {
        #expect(PhantomNextCommand.exportVarName(forTool: "gemini") == "ORRERY_GEMINI_HOME")
    }

    @Test("an unrecognized tool name has no export var")
    func unknownVarName() {
        #expect(PhantomNextCommand.exportVarName(forTool: "bogus") == nil)
    }

    // MARK: - advance

    @Test("no sentinel means break the loop")
    func noSentinel() throws {
        var resolveCalled = false
        let result = try PhantomNextCommand.advance(
            id: "4242", registry: registry,
            resolveAccountDir: { _, _ in resolveCalled = true; return nil },
            resolveSessionId: { nil })
        #expect(result == nil)
        #expect(!resolveCalled)
    }

    @Test("a resolved account dir emits an export line before the resume line")
    func emitsExportForResolvedAccount() throws {
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "work",
            sessionId: "sess-old", to: registry.sentinelURL(id: "4242"))

        let result = try PhantomNextCommand.advance(
            id: "4242", registry: registry,
            resolveAccountDir: { tool, name in
                #expect(tool == "claude")
                #expect(name == "work")
                return "/Users/x/.orrery/accounts/claude/some-uuid"
            },
            resolveSessionId: { "sess-old" })

        #expect(result == """
        export CLAUDE_CONFIG_DIR='/Users/x/.orrery/accounts/claude/some-uuid'
        set -- --resume 'sess-old'
        """)
    }

    @Test("codex and gemini sentinels resolve to their own export variable")
    func exportVariablePerTool() throws {
        try PhantomSupport.writeSentinel(
            targetAccountTool: "gemini", targetAccountName: "personal",
            sessionId: nil, to: registry.sentinelURL(id: "4242"))

        let result = try PhantomNextCommand.advance(
            id: "4242", registry: registry,
            resolveAccountDir: { _, _ in "/tmp/gemini-home" },
            resolveSessionId: { nil })

        #expect(result == """
        export ORRERY_GEMINI_HOME='/tmp/gemini-home'
        set --
        """)
    }

    @Test("a nil resolve result drops the switch but still continues the loop")
    func nilResolveDropsSwitch() throws {
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "work",
            sessionId: "sess-old", to: registry.sentinelURL(id: "4242"))

        let result = try PhantomNextCommand.advance(
            id: "4242", registry: registry,
            resolveAccountDir: { _, _ in nil },
            resolveSessionId: { "sess-old" })

        #expect(result == "set -- --resume 'sess-old'")
        #expect(!(result?.contains("export") ?? true))
    }

    @Test("a failed resolve leaves the entry's account unchanged, but still updates the session")
    func nilResolveDoesNotStampTheEntry() throws {
        // Fixture entry from init() starts at account "old" — the sentinel
        // targets "work", but resolveAccountDir fails (account missing, or
        // not in v3.1 layout), so the switch never actually took effect.
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "work",
            sessionId: nil, to: registry.sentinelURL(id: "4242"))

        let result = try PhantomNextCommand.advance(
            id: "4242", registry: registry,
            resolveAccountDir: { _, _ in nil },
            resolveSessionId: { "sess-new" })

        #expect(!(result?.contains("export") ?? true))

        let entry = try #require(registry.read(id: "4242"))
        // The registry must not claim a switch that never happened.
        #expect(entry.account == "old")
        // The session still has to survive even though the switch didn't.
        #expect(entry.sessionId == "sess-new")
    }

    @Test("a resolved dir containing a quote stays valid for eval")
    func quotedDirPath() throws {
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "work",
            sessionId: nil, to: registry.sentinelURL(id: "4242"))

        let result = try PhantomNextCommand.advance(
            id: "4242", registry: registry,
            resolveAccountDir: { _, _ in "/tmp/o'brien" },
            resolveSessionId: { nil })

        #expect(result == #"export CLAUDE_CONFIG_DIR='/tmp/o'\''brien'"# + "\nset --")
    }

    @Test("the sentinel is consumed so the next iteration does not re-fire")
    func sentinelConsumed() throws {
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "work",
            sessionId: nil, to: registry.sentinelURL(id: "4242"))

        _ = try PhantomNextCommand.advance(
            id: "4242", registry: registry,
            resolveAccountDir: { _, _ in nil }, resolveSessionId: { nil })

        #expect(!FileManager.default.fileExists(
            atPath: registry.sentinelURL(id: "4242").path))
    }

    @Test("the entry records the new account after a switch")
    func entryUpdated() throws {
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "work",
            sessionId: nil, to: registry.sentinelURL(id: "4242"))

        _ = try PhantomNextCommand.advance(
            id: "4242", registry: registry,
            resolveAccountDir: { _, _ in "/tmp/work-dir" },
            resolveSessionId: { "sess-new" })

        let entry = try #require(registry.read(id: "4242"))
        #expect(entry.account == "work")
        #expect(entry.sessionId == "sess-new")
    }

    @Test("a hook-sourced session id is preferred over a probed one")
    func hookSessionWins() throws {
        try registry.write(PhantomEntry(
            supervisorPid: 4242, supervisorStartedAt: 1.0, tool: "claude",
            tty: nil, cwd: "/tmp/project", workspace: "origin", account: "old",
            sessionId: "from-hook", sessionIdSource: .hook, updatedAt: 1.0), id: "4242")
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "work",
            sessionId: nil, to: registry.sentinelURL(id: "4242"))

        let result = try PhantomNextCommand.advance(
            id: "4242", registry: registry,
            resolveAccountDir: { _, _ in "/tmp/work-dir" },
            resolveSessionId: { "from-probe" })

        #expect(result == """
        export CLAUDE_CONFIG_DIR='/tmp/work-dir'
        set -- --resume 'from-hook'
        """)
    }
}
