import Testing
import Foundation
@testable import OrreryCore

@Suite("Memory migration")
struct MemoryMigrationTests {
    var tmpRoot: URL!

    init() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-mem-mig-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    // MARK: - merge=false is a no-op

    @Test("merge=false leaves dest untouched")
    func mergeFalseIsNoOp() throws {
        let (source, dest) = try makeDirs()
        try "src content".write(to: source.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        try "dest content".write(to: dest.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)

        try applyMigration(merge: false, fromDir: source, toDir: dest)

        let destContent = try String(contentsOf: dest.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        #expect(destContent == "dest content")
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("fragments").path))
    }

    // MARK: - MEMORY.md → fragment

    @Test("MEMORY.md from source becomes a fragment in dest")
    func memoryBecomesFragment() throws {
        let (source, dest) = try makeDirs()
        try "src memory body".write(to: source.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        try "dest memory unchanged".write(to: dest.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)

        try applyMigration(merge: true, fromDir: source, toDir: dest)

        // Dest's MEMORY.md is preserved as-is (not overwritten).
        let destBody = try String(contentsOf: dest.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        #expect(destBody == "dest memory unchanged")

        // A fragment file landed under dest/fragments/.
        let fragmentsDir = dest.appendingPathComponent("fragments")
        let fragments = try FileManager.default.contentsOfDirectory(atPath: fragmentsDir.path)
        #expect(fragments.count == 1)
        let fragmentPath = fragmentsDir.appendingPathComponent(fragments[0])
        let fragmentBody = try String(contentsOf: fragmentPath, encoding: .utf8)
        #expect(fragmentBody.contains("action: migrate"))
        #expect(fragmentBody.contains("src memory body"))
    }

    // MARK: - non-canonical files

    @Test("non-canonical .md file copies to dest when missing")
    func nonCanonicalFileCopiesWhenMissing() throws {
        let (source, dest) = try makeDirs()
        try "notes content".write(to: source.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        try applyMigration(merge: true, fromDir: source, toDir: dest)

        let copied = try String(contentsOf: dest.appendingPathComponent("notes.md"), encoding: .utf8)
        #expect(copied == "notes content")
    }

    @Test("non-canonical file is preserved (skip-existing) on collision")
    func nonCanonicalFileSkippedOnCollision() throws {
        let (source, dest) = try makeDirs()
        try "src version".write(to: source.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try "dest version".write(to: dest.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        try applyMigration(merge: true, fromDir: source, toDir: dest)

        let preserved = try String(contentsOf: dest.appendingPathComponent("notes.md"), encoding: .utf8)
        #expect(preserved == "dest version", "destination must not be overwritten")
    }

    // MARK: - subdirectories

    @Test("subdirectory copies recursively")
    func subdirectoryRecursiveCopy() throws {
        let (source, dest) = try makeDirs()
        let srcSub = source.appendingPathComponent("sub").appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: srcSub, withIntermediateDirectories: true)
        try "deep".write(to: srcSub.appendingPathComponent("deep.md"), atomically: true, encoding: .utf8)
        try "shallow".write(to: source.appendingPathComponent("sub").appendingPathComponent("shallow.md"), atomically: true, encoding: .utf8)

        try applyMigration(merge: true, fromDir: source, toDir: dest)

        let copiedDeep = try String(contentsOf: dest.appendingPathComponent("sub/nested/deep.md"), encoding: .utf8)
        let copiedShallow = try String(contentsOf: dest.appendingPathComponent("sub/shallow.md"), encoding: .utf8)
        #expect(copiedDeep == "deep")
        #expect(copiedShallow == "shallow")
    }

    @Test("file inside subdirectory is skip-existing on collision")
    func subdirFileSkippedOnCollision() throws {
        let (source, dest) = try makeDirs()
        let srcSub = source.appendingPathComponent("sub")
        let dstSub = dest.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: srcSub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstSub, withIntermediateDirectories: true)
        try "src".write(to: srcSub.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "dest-orig".write(to: dstSub.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "src-only".write(to: srcSub.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

        try applyMigration(merge: true, fromDir: source, toDir: dest)

        let aPreserved = try String(contentsOf: dstSub.appendingPathComponent("a.md"), encoding: .utf8)
        let bCopied = try String(contentsOf: dstSub.appendingPathComponent("b.md"), encoding: .utf8)
        #expect(aPreserved == "dest-orig")
        #expect(bCopied == "src-only")
    }

    // MARK: - fragments/ directory

    @Test("existing fragments in source's fragments/ are preserved across migration")
    func existingFragmentsCopyOver() throws {
        let (source, dest) = try makeDirs()
        let srcFragments = source.appendingPathComponent("fragments")
        try FileManager.default.createDirectory(at: srcFragments, withIntermediateDirectories: true)
        try "old fragment body".write(
            to: srcFragments.appendingPathComponent("f-abc12345-host.md"),
            atomically: true, encoding: .utf8
        )

        try applyMigration(merge: true, fromDir: source, toDir: dest)

        let destFragmentPath = dest.appendingPathComponent("fragments/f-abc12345-host.md")
        let copied = try String(contentsOf: destFragmentPath, encoding: .utf8)
        #expect(copied == "old fragment body")
    }

    // MARK: - source non-destructive

    @Test("source dir is left intact after migration (reversible)")
    func sourceLeftIntact() throws {
        let (source, dest) = try makeDirs()
        try "src memory".write(to: source.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        try "src note".write(to: source.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        try applyMigration(merge: true, fromDir: source, toDir: dest)

        let memoryStill = try String(contentsOf: source.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        let noteStill = try String(contentsOf: source.appendingPathComponent("notes.md"), encoding: .utf8)
        #expect(memoryStill == "src memory")
        #expect(noteStill == "src note")
    }

    // MARK: - missing source

    @Test("missing source dir is a silent no-op")
    func missingSourceNoOp() throws {
        let dest = tmpRoot.appendingPathComponent("dest-only")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let nonexistentSource = tmpRoot.appendingPathComponent("nope")

        // Must not throw — migrating from a nonexistent dir is fine (env that
        // never accumulated any memory before switching modes).
        try applyMigration(merge: true, fromDir: nonexistentSource, toDir: dest)
    }

    // MARK: - helpers

    private func makeDirs() throws -> (source: URL, dest: URL) {
        let source = tmpRoot.appendingPathComponent("src-\(UUID().uuidString)")
        let dest = tmpRoot.appendingPathComponent("dst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        return (source, dest)
    }
}
