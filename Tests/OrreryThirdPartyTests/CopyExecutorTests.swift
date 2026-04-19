import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("CopyFile + CopyGlob executors")
struct CopyExecutorTests {
    private func makeTempTree() throws -> (src: URL, dst: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-copy-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src")
        let dst = root.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        return (src, dst)
    }

    @Test("copyFile copies and reports dest path")
    func copyFileWorks() throws {
        let (src, dst) = try makeTempTree()
        try Data("hi".utf8).write(to: src.appendingPathComponent("a.js"))

        let record = try CopyFileExecutor.apply(
            .copyFile(from: "a.js", to: "a.js"),
            sourceDir: src, claudeDir: dst
        )
        #expect(record == ["a.js"])
        let content = try String(contentsOf: dst.appendingPathComponent("a.js"), encoding: .utf8)
        #expect(content == "hi")
    }

    @Test("copyGlob copies each *.ext match")
    func copyGlobWorks() throws {
        let (src, dst) = try makeTempTree()
        let srcHooks = src.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: srcHooks, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: srcHooks.appendingPathComponent("a.js"))
        try Data("2".utf8).write(to: srcHooks.appendingPathComponent("b.js"))
        try Data("x".utf8).write(to: srcHooks.appendingPathComponent("skip.md"))

        let record = try CopyGlobExecutor.apply(
            .copyGlob(from: "hooks/*.js", toDir: "hooks"),
            sourceDir: src, claudeDir: dst
        )
        #expect(Set(record) == Set(["hooks/a.js", "hooks/b.js"]))
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("hooks/a.js").path))
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("hooks/skip.md").path) == false)
    }

    @Test("copyGlob rejects non *.ext pattern")
    func copyGlobRejectsWeirdPattern() {
        let src = URL(fileURLWithPath: "/tmp")
        let dst = URL(fileURLWithPath: "/tmp")
        #expect(throws: ThirdPartyError.self) {
            _ = try CopyGlobExecutor.apply(
                .copyGlob(from: "**/*.js", toDir: "x"),
                sourceDir: src, claudeDir: dst
            )
        }
    }
}
