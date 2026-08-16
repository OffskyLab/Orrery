import Testing
import Foundation
@testable import OrreryCore

@Suite("PhantomRegistry")
struct PhantomRegistryTests {
    var tmpDir: URL!
    var registry: PhantomRegistry!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-phantom-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        registry = PhantomRegistry(homeURL: tmpDir)
    }

    private func sampleEntry(pid: Int32 = 4242, startedAt: Double = 100.0) -> PhantomEntry {
        PhantomEntry(
            supervisorPid: pid,
            supervisorStartedAt: startedAt,
            tool: "claude",
            tty: "/dev/ttys004",
            cwd: "/tmp/project",
            workspace: "origin",
            account: "work",
            sessionId: nil,
            sessionIdSource: .probe,
            updatedAt: 100.0
        )
    }

    @Test("write then read round-trips every field")
    func roundTrip() throws {
        let entry = sampleEntry()
        try registry.write(entry, id: "4242")

        let loaded = try #require(registry.read(id: "4242"))
        #expect(loaded.schema == 1)
        #expect(loaded.supervisorPid == 4242)
        #expect(loaded.supervisorStartedAt == 100.0)
        #expect(loaded.tool == "claude")
        #expect(loaded.tty == "/dev/ttys004")
        #expect(loaded.cwd == "/tmp/project")
        #expect(loaded.workspace == "origin")
        #expect(loaded.account == "work")
        #expect(loaded.sessionId == nil)
        #expect(loaded.sessionIdSource == .probe)
    }

    @Test("meta.json uses snake_case keys so it is readable outside Swift")
    func snakeCaseKeys() throws {
        try registry.write(sampleEntry(), id: "4242")
        let text = try String(
            contentsOf: registry.entryDirURL(id: "4242").appendingPathComponent("meta.json"),
            encoding: .utf8)
        #expect(text.contains("\"supervisor_pid\""))
        #expect(text.contains("\"supervisor_started_at\""))
        #expect(text.contains("\"session_id_source\""))
    }

    @Test("registry root is under homeURL/phantom, isolated per ORRERY_HOME")
    func rootLocation() throws {
        try registry.write(sampleEntry(), id: "4242")
        let expected = tmpDir.appendingPathComponent("phantom").appendingPathComponent("4242")
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    @Test("sentinel lives inside the entry dir, not globally")
    func sentinelIsPerEntry() {
        let url = registry.sentinelURL(id: "4242")
        #expect(url.lastPathComponent == "sentinel")
        #expect(url.deletingLastPathComponent().lastPathComponent == "4242")
    }

    @Test("read returns nil for an unknown id")
    func readMissing() {
        #expect(registry.read(id: "9999") == nil)
    }

    @Test("remove deletes the whole entry dir including its sentinel")
    func removeDeletesDir() throws {
        try registry.write(sampleEntry(), id: "4242")
        try "SESSION_ID='x'\n".write(to: registry.sentinelURL(id: "4242"),
                                    atomically: true, encoding: .utf8)
        registry.remove(id: "4242")
        #expect(!FileManager.default.fileExists(atPath: registry.entryDirURL(id: "4242").path))
    }

    @Test("liveEntries keeps live entries and deletes dead ones")
    func liveEntriesPrunes() throws {
        try registry.write(sampleEntry(pid: 100, startedAt: 1.0), id: "100")
        try registry.write(sampleEntry(pid: 200, startedAt: 2.0), id: "200")

        let live = registry.liveEntries { pid, _ in pid == 100 }

        #expect(live.count == 1)
        #expect(live[0].id == "100")
        #expect(FileManager.default.fileExists(atPath: registry.entryDirURL(id: "100").path))
        #expect(!FileManager.default.fileExists(atPath: registry.entryDirURL(id: "200").path))
    }

    @Test("liveEntries treats a recycled pid as dead by comparing start time")
    func pidRecycleGuard() throws {
        try registry.write(sampleEntry(pid: 300, startedAt: 50.0), id: "300")

        // pid 300 is alive, but it started at a different time — a different process.
        let live = registry.liveEntries { pid, startedAt in pid == 300 && startedAt == 50.0 }
        #expect(live.count == 1)

        try registry.write(sampleEntry(pid: 300, startedAt: 50.0), id: "300")
        let recycled = registry.liveEntries { pid, startedAt in pid == 300 && startedAt == 999.0 }
        #expect(recycled.isEmpty)
    }

    @Test("liveEntries ignores an entry dir with unreadable meta.json")
    func corruptEntryIsPruned() throws {
        let dir = registry.entryDirURL(id: "500")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json".write(to: dir.appendingPathComponent("meta.json"),
                             atomically: true, encoding: .utf8)
        let live = registry.liveEntries { _, _ in true }
        #expect(live.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("liveEntries on a missing registry root returns empty, not an error")
    func missingRoot() {
        let empty = PhantomRegistry(homeURL: tmpDir.appendingPathComponent("nope"))
        #expect(empty.liveEntries { _, _ in true }.isEmpty)
    }
}
