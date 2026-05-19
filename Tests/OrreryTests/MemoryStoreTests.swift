import Testing
import Foundation
@testable import OrreryCore

@Suite("MemoryStore")
struct MemoryStoreTests {
    let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-mstore-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    @Test("read() on empty dir returns empty string")
    func readEmpty() throws {
        let store = MemoryStore(directory: tmpDir)
        #expect(try store.read().memory.isEmpty)
        #expect(try store.read().fragments.isEmpty)
    }

    @Test("write(append:false) creates MEMORY.md and a fragment")
    func writeOverwrite() throws {
        let store = MemoryStore(directory: tmpDir)
        try store.write(content: "hello", append: false)

        let memory = try String(contentsOf: tmpDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        #expect(memory == "hello")

        let fragments = try FileManager.default.contentsOfDirectory(atPath: tmpDir.appendingPathComponent("fragments").path)
        #expect(fragments.count == 1)
        let body = try String(contentsOf: tmpDir.appendingPathComponent("fragments").appendingPathComponent(fragments[0]), encoding: .utf8)
        #expect(body.contains("action: overwrite"))
        #expect(body.contains("hello"))
    }

    @Test("write(append:true) appends with leading newline + fragment")
    func writeAppend() throws {
        let store = MemoryStore(directory: tmpDir)
        try store.write(content: "first", append: false)
        try store.write(content: "second", append: true)

        let memory = try String(contentsOf: tmpDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        #expect(memory == "first\nsecond")

        let fragments = try FileManager.default.contentsOfDirectory(atPath: tmpDir.appendingPathComponent("fragments").path)
        #expect(fragments.count == 2)
    }

    @Test("write(append:false) cleans up existing fragments after writing the new fragment")
    func writeOverwriteCleansFragments() throws {
        let store = MemoryStore(directory: tmpDir)
        try store.write(content: "a", append: true)
        try store.write(content: "b", append: true)
        try store.write(content: "consolidated", append: false)

        let fragments = try FileManager.default.contentsOfDirectory(atPath: tmpDir.appendingPathComponent("fragments").path)
        // Only the "overwrite" fragment from the consolidation call remains.
        #expect(fragments.count == 1)
        let body = try String(contentsOf: tmpDir.appendingPathComponent("fragments").appendingPathComponent(fragments[0]), encoding: .utf8)
        #expect(body.contains("action: overwrite"))
    }

    @Test("read() returns pending fragments sorted by filename")
    func readReturnsFragments() throws {
        let store = MemoryStore(directory: tmpDir)
        let fragDir = tmpDir.appendingPathComponent("fragments")
        try FileManager.default.createDirectory(at: fragDir, withIntermediateDirectories: true)
        try "frag-a-body".write(to: fragDir.appendingPathComponent("f-aaa-host.md"), atomically: true, encoding: .utf8)
        try "frag-b-body".write(to: fragDir.appendingPathComponent("f-bbb-host.md"), atomically: true, encoding: .utf8)

        let result = try store.read()
        #expect(result.fragments.map(\.filename) == ["f-aaa-host.md", "f-bbb-host.md"])
        #expect(result.fragments[0].content == "frag-a-body")
    }

    @Test("emit returns empty string when MEMORY.md is missing")
    func emitMissing() throws {
        let store = MemoryStore(directory: tmpDir)
        #expect(try store.emit(maxBytes: 25_600) == "")
    }

    @Test("emit returns MEMORY.md content when small")
    func emitSmall() throws {
        let store = MemoryStore(directory: tmpDir)
        // Seed MEMORY.md directly — `write()` would also produce a fragment as a side
        // effect, which would alter emit's output. Same seeding technique as
        // `emitWithFragments` / `readReturnsFragments`.
        try "tiny memory".write(to: tmpDir.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        let out = try store.emit(maxBytes: 25_600)
        #expect(out == "tiny memory")
    }

    @Test("emit appends pending fragments block")
    func emitWithFragments() throws {
        let store = MemoryStore(directory: tmpDir)
        try store.write(content: "main", append: false)
        let fragDir = tmpDir.appendingPathComponent("fragments")
        try "fragbody".write(to: fragDir.appendingPathComponent("f-x-host.md"), atomically: true, encoding: .utf8)
        let out = try store.emit(maxBytes: 25_600)
        #expect(out.contains("main"))
        #expect(out.contains("Pending Memory Fragments"))
        #expect(out.contains("f-x-host.md"))
        #expect(out.contains("fragbody"))
    }

    @Test("emit truncates at maxBytes and appends truncation hint")
    func emitTruncates() throws {
        let store = MemoryStore(directory: tmpDir)
        let big = String(repeating: "x", count: 30_000)
        try store.write(content: big, append: false)
        let out = try store.emit(maxBytes: 100)
        #expect(out.count > 100) // truncation hint adds bytes
        #expect(out.contains("truncated"))
        #expect(out.hasPrefix(String(repeating: "x", count: 100)))
    }
}
