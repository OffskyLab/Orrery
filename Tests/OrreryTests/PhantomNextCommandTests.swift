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

    @Test("argv is --resume plus a quoted session id")
    func argvWithSession() {
        #expect(PhantomNextCommand.nextArgv(sessionId: "abc-123") == "--resume 'abc-123'")
    }

    @Test("argv is empty when there is no session to resume")
    func argvWithoutSession() {
        #expect(PhantomNextCommand.nextArgv(sessionId: nil) == "")
    }

    @Test("no sentinel means break the loop")
    func noSentinel() throws {
        var pinned: [(String, String)] = []
        let result = try PhantomNextCommand.advance(
            id: "4242", registry: registry,
            applyPin: { pinned.append(($0, $1)) },
            resolveSessionId: { nil })
        #expect(result == nil)
        #expect(pinned.isEmpty)
    }

    @Test("a sentinel applies the pin and returns resume argv")
    func appliesPin() throws {
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "work",
            sessionId: "sess-old", to: registry.sentinelURL(id: "4242"))

        var pinned: [(String, String)] = []
        let result = try PhantomNextCommand.advance(
            id: "4242", registry: registry,
            applyPin: { pinned.append(($0, $1)) },
            resolveSessionId: { "sess-old" })

        #expect(result == "--resume 'sess-old'")
        #expect(pinned.count == 1)
        #expect(pinned[0].0 == "claude")
        #expect(pinned[0].1 == "work")
    }

    @Test("the sentinel is consumed so the next iteration does not re-fire")
    func sentinelConsumed() throws {
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "work",
            sessionId: nil, to: registry.sentinelURL(id: "4242"))

        _ = try PhantomNextCommand.advance(
            id: "4242", registry: registry, applyPin: { _, _ in }, resolveSessionId: { nil })

        #expect(!FileManager.default.fileExists(
            atPath: registry.sentinelURL(id: "4242").path))
    }

    @Test("the entry records the new account after a switch")
    func entryUpdated() throws {
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "work",
            sessionId: nil, to: registry.sentinelURL(id: "4242"))

        _ = try PhantomNextCommand.advance(
            id: "4242", registry: registry, applyPin: { _, _ in },
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
            id: "4242", registry: registry, applyPin: { _, _ in },
            resolveSessionId: { "from-probe" })

        #expect(result == "--resume 'from-hook'")
    }

    @Test("a session id containing a quote is safely quoted for eval")
    func quotedSessionId() {
        #expect(PhantomNextCommand.nextArgv(sessionId: "a'b") == #"--resume 'a'\''b'"#)
    }
}
