import Foundation
import Testing
@testable import OrreryCore
import OrreryAccountKit

@Suite("WorkspaceStructureRelocation")
struct WorkspaceStructureRelocationTests {
    private func tmpHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-reloc-\(UUID().uuidString)")
    }

    @Test("renames envs/ to workspaces/ and origin/ to workspaces/origin/, env.json to workspace.json")
    func relocatesTree() throws {
        // `runWorkspaceStructureRelocationIfNeeded`'s origin-relocation branch
        // repoints `Tool.defaultConfigDir` symlinks (e.g. `~/.claude`), which
        // resolves via `userHomeURL()` — honoring `ORRERY_USER_HOME`, NOT the
        // `homeURL:` parameter passed below. Without isolating it here, this
        // test can delete and repoint the developer's REAL `~/.claude` symlink
        // if it happens to point under `.../origin/claude`. `withIsolatedHome`
        // is the project convention for this (see TestHelpers.swift) — it sets
        // ORRERY_HOME and ORRERY_USER_HOME together and restores both.
        try withIsolatedHome {
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
    }

    @Test("idempotent — second run does not error or change the tree")
    func idempotent() throws {
        // Same isolation hazard as `relocatesTree()` above — see its comment.
        try withIsolatedHome {
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

    @Test("Phase B rebuilds account symlinks into workspaces/<ws>/claude")
    func phaseBSymlinks() throws {
        let fm = FileManager.default
        let home = tmpHome()
        let acctStore = AccountStore(homeURL: home)
        let acct = Account(id: "ACCT1", tool: .claude, displayName: "me", workspace: "origin")
        try acctStore.save(acct)

        AccountMigration.runWorkspaceAccountSymlinksIfNeeded(homeURL: home)

        let acctDir = acctStore.accountDir(id: "ACCT1", tool: .claude)
        for sub in ClaudeAdapter.baseSharedSubdirs {
            let dest = try fm.destinationOfSymbolicLink(atPath: acctDir.appendingPathComponent(sub).path)
            #expect(dest == home.appendingPathComponent("workspaces/origin/claude/\(sub)").path)
        }
        #expect(fm.fileExists(atPath: home.appendingPathComponent(".workspace-account-symlinks").path))
    }
}
