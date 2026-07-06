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

    @Test("copyFile copies and reports dest path (account-relative)")
    func copyFileWorks() throws {
        let (src, dst) = try makeTempTree()
        try Data("hi".utf8).write(to: src.appendingPathComponent("a.js"))

        let record = try CopyFileExecutor.apply(
            .copyFile(from: "a.js", to: "a.js"),
            sourceDir: src, claudeDir: dst, workspaceDir: dst
        )
        #expect(record == ["a.js"])
        let content = try String(contentsOf: dst.appendingPathComponent("a.js"), encoding: .utf8)
        #expect(content == "hi")
    }

    @Test("copyFile with <WORKSPACE_CLAUDE_DIR> lands in the workspace and keeps the marker in the record")
    func copyFileWorkspaceTarget() throws {
        let (src, dst) = try makeTempTree()
        let ws = dst.deletingLastPathComponent().appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: src.appendingPathComponent("a.js"))

        let record = try CopyFileExecutor.apply(
            .copyFile(from: "a.js", to: "<WORKSPACE_CLAUDE_DIR>/a.js"),
            sourceDir: src, claudeDir: dst, workspaceDir: ws
        )
        // Lock keeps the marker verbatim.
        #expect(record == ["<WORKSPACE_CLAUDE_DIR>/a.js"])
        // File landed in the workspace, NOT the account dir.
        #expect(FileManager.default.fileExists(atPath: ws.appendingPathComponent("a.js").path))
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("a.js").path))
    }

    @Test("resolveInstalledPath maps marker to workspace, plain to account")
    func resolvePath() {
        let acct = URL(fileURLWithPath: "/acct")
        let ws = URL(fileURLWithPath: "/ws")
        #expect(CopyFileExecutor.resolveInstalledPath("statusline.js", claudeDir: acct, workspaceDir: ws).path
            == "/acct/statusline.js")
        #expect(CopyFileExecutor.resolveInstalledPath("<WORKSPACE_CLAUDE_DIR>/statusline.js", claudeDir: acct, workspaceDir: ws).path
            == "/ws/statusline.js")
    }

    @Test("rollback removes a <WORKSPACE_CLAUDE_DIR> file from the workspace")
    func rollbackWorkspaceTarget() throws {
        let (_, dst) = try makeTempTree()
        let ws = dst.deletingLastPathComponent().appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: ws.appendingPathComponent("a.js"))

        CopyFileExecutor.rollback(
            paths: ["<WORKSPACE_CLAUDE_DIR>/a.js"], claudeDir: dst, workspaceDir: ws)

        #expect(!FileManager.default.fileExists(atPath: ws.appendingPathComponent("a.js").path))
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
