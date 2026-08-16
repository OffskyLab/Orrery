import Testing
import Foundation
@testable import OrreryCore

@Suite("PhantomBeginCommand")
struct PhantomBeginCommandTests {
    var tmpDir: URL!
    var registry: PhantomRegistry!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-phantom-begin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        registry = PhantomRegistry(homeURL: tmpDir)
    }

    @Test("export script assigns both env vars with quoted values")
    func exportScript() {
        let script = PhantomBeginCommand.exportScript(
            id: "4242", dirURL: URL(fileURLWithPath: "/tmp/o rrery/phantom/4242"))
        #expect(script.contains("export ORRERY_PHANTOM_ID='4242'"))
        #expect(script.contains("export ORRERY_PHANTOM_DIR='/tmp/o rrery/phantom/4242'"))
    }

    @Test("begin writes an entry keyed by the supervisor pid")
    func writesEntry() throws {
        try PhantomBeginCommand.begin(
            tool: "claude",
            supervisorPid: 4242,
            supervisorStartedAt: 123.5,
            cwd: "/tmp/project",
            tty: "/dev/ttys004",
            workspace: "origin",
            account: "work",
            registry: registry)

        let entry = try #require(registry.read(id: "4242"))
        #expect(entry.supervisorPid == 4242)
        #expect(entry.supervisorStartedAt == 123.5)
        #expect(entry.tool == "claude")
        #expect(entry.cwd == "/tmp/project")
        #expect(entry.tty == "/dev/ttys004")
        #expect(entry.workspace == "origin")
        #expect(entry.account == "work")
        #expect(entry.sessionId == nil)
        #expect(entry.sessionIdSource == .probe)
    }

    @Test("begin overwrites a stale entry left by a recycled pid")
    func overwritesStale() throws {
        try PhantomBeginCommand.begin(
            tool: "claude", supervisorPid: 4242, supervisorStartedAt: 1.0,
            cwd: "/old", tty: nil, workspace: nil, account: nil, registry: registry)
        try PhantomBeginCommand.begin(
            tool: "claude", supervisorPid: 4242, supervisorStartedAt: 2.0,
            cwd: "/new", tty: nil, workspace: nil, account: nil, registry: registry)

        let entry = try #require(registry.read(id: "4242"))
        #expect(entry.cwd == "/new")
        #expect(entry.supervisorStartedAt == 2.0)
    }

    @Test("begin removes the legacy global sentinel if one is left over")
    func removesLegacySentinel() throws {
        let legacy = tmpDir.appendingPathComponent(".phantom-sentinel")
        try "SESSION_ID=''\n".write(to: legacy, atomically: true, encoding: .utf8)

        PhantomBeginCommand.removeLegacySentinel(homeURL: tmpDir)

        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }
}
