import Foundation
import Testing
@testable import OrreryCore

@Suite("WorkspaceStructureRelocation")
struct WorkspaceStructureRelocationTests {
    private func tmpHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-reloc-\(UUID().uuidString)")
    }

    @Test("renames envs/ to workspaces/ and origin/ to workspaces/origin/, env.json to workspace.json")
    func relocatesTree() throws {
        let fm = FileManager.default
        let home = tmpHome()
        // Synthesize a v3.0.x tree.
        let envID = "11111111-1111-1111-1111-111111111111"
        try fm.createDirectory(at: home.appendingPathComponent("envs/\(envID)/claude"),
                               withIntermediateDirectories: true)
        try Data("{\"id\":\"\(envID)\",\"name\":\"work\",\"description\":\"\",\"createdAt\":\"2020-01-01T00:00:00Z\",\"lastUsed\":\"2020-01-01T00:00:00Z\",\"tools\":[],\"env\":{},\"isolatedSessionTools\":[],\"isolateMemory\":false}".utf8)
            .write(to: home.appendingPathComponent("envs/\(envID)/env.json"))
        try fm.createDirectory(at: home.appendingPathComponent("origin/claude"),
                               withIntermediateDirectories: true)
        try Data("{\"isolateMemory\":true,\"isolatedSessionTools\":[],\"accounts\":{}}".utf8)
            .write(to: home.appendingPathComponent("origin/config.json"))

        AccountMigration.runWorkspaceStructureRelocationIfNeeded(homeURL: home)

        #expect(!fm.fileExists(atPath: home.appendingPathComponent("envs").path))
        #expect(fm.fileExists(atPath: home.appendingPathComponent("workspaces/\(envID)/claude").path))
        #expect(fm.fileExists(atPath: home.appendingPathComponent("workspaces/\(envID)/workspace.json").path))
        #expect(!fm.fileExists(atPath: home.appendingPathComponent("workspaces/\(envID)/env.json").path))
        #expect(fm.fileExists(atPath: home.appendingPathComponent("workspaces/origin/claude").path))
        #expect(fm.fileExists(atPath: home.appendingPathComponent("workspaces/origin/workspace.json").path))
        // flag written; second run is a no-op
        #expect(fm.fileExists(atPath: home.appendingPathComponent(".workspace-structure-relocated").path))
    }

    @Test("idempotent — second run does not error or change the tree")
    func idempotent() throws {
        let fm = FileManager.default
        let home = tmpHome()
        try fm.createDirectory(at: home.appendingPathComponent("origin/claude"),
                               withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: home.appendingPathComponent("origin/config.json"))
        AccountMigration.runWorkspaceStructureRelocationIfNeeded(homeURL: home)
        AccountMigration.runWorkspaceStructureRelocationIfNeeded(homeURL: home)
        #expect(fm.fileExists(atPath: home.appendingPathComponent("workspaces/origin/workspace.json").path))
    }
}
