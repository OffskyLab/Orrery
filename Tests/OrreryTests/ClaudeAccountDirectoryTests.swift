import Foundation
import Testing
@testable import OrreryCore

@Suite("ClaudeAccountDirectory.prepareDirectory")
struct ClaudeAccountDirectoryPrepareTests {
    @Test("creates account dir with 5 symlinks to workspace")
    func createsDirAndSymlinks() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            var acct = Account(tool: .claude, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)

            try ClaudeAccountDirectory.prepareDirectory(
                account: acct,
                accountStore: acctStore,
                environmentStore: envStore
            )

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let fm = FileManager.default

            // Account dir exists
            #expect(fm.fileExists(atPath: acctDir.path))

            // 5 symlinks exist, each pointing to workspace's matching subdir
            let wsDir = envStore.claudeWorkspaceDir(workspace: "origin")
            for sub in ["projects", "memory", "agents", "commands", "todos"] {
                let linkPath = acctDir.appendingPathComponent(sub).path
                let dest = try fm.destinationOfSymbolicLink(atPath: linkPath)
                let expectedDest = wsDir.appendingPathComponent(sub).path
                #expect(dest == expectedDest, "symlink \(sub) destination mismatch")
            }
        }
    }

    @Test("is idempotent — second call doesn't error or duplicate")
    func isIdempotent() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            var acct = Account(tool: .claude, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)

            try ClaudeAccountDirectory.prepareDirectory(
                account: acct, accountStore: acctStore, environmentStore: envStore)
            try ClaudeAccountDirectory.prepareDirectory(
                account: acct, accountStore: acctStore, environmentStore: envStore)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let fm = FileManager.default
            let projectsLink = acctDir.appendingPathComponent("projects").path
            let dest = try fm.destinationOfSymbolicLink(atPath: projectsLink)
            #expect(dest == envStore.claudeWorkspaceDir(workspace: "origin")
                .appendingPathComponent("projects").path)
        }
    }

    @Test("creates the workspace's claude-workspace dir if absent")
    func createsWorkspaceDirIfAbsent() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            var acct = Account(tool: .claude, displayName: "test")
            acct.workspace = "freshly-named"
            try acctStore.save(acct)

            try ClaudeAccountDirectory.prepareDirectory(
                account: acct, accountStore: acctStore, environmentStore: envStore)

            let wsDir = envStore.claudeWorkspaceDir(workspace: "freshly-named")
            #expect(FileManager.default.fileExists(atPath: wsDir.path))
            for sub in ["projects", "memory", "agents", "commands", "todos"] {
                #expect(FileManager.default.fileExists(
                    atPath: wsDir.appendingPathComponent(sub).path))
            }
        }
    }

    @Test("repoints a symlink that previously pointed to a different workspace")
    func repointsExistingSymlink() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            var acct = Account(tool: .claude, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)
            try ClaudeAccountDirectory.prepareDirectory(
                account: acct, accountStore: acctStore, environmentStore: envStore)

            // Now flip workspace and re-prepare.
            acct.workspace = "work"
            try acctStore.save(acct)
            try ClaudeAccountDirectory.prepareDirectory(
                account: acct, accountStore: acctStore, environmentStore: envStore)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let fm = FileManager.default
            let workDir = envStore.claudeWorkspaceDir(workspace: "work")
            for sub in ClaudeAccountDirectory.sharedSubdirs {
                let dest = try fm.destinationOfSymbolicLink(
                    atPath: acctDir.appendingPathComponent(sub).path)
                #expect(dest == workDir.appendingPathComponent(sub).path,
                    "after repoint, \(sub) should point at 'work' workspace")
            }
        }
    }

    @Test("refuses to clobber a real directory at a symlink path")
    func refusesToClobberRealDirectory() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            var acct = Account(tool: .claude, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)

            // Pre-create a real dir + file at the projects/ path BEFORE
            // calling prepareDirectory — simulates user data left behind.
            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let realDir = acctDir.appendingPathComponent("projects")
            try FileManager.default.createDirectory(
                at: realDir, withIntermediateDirectories: true)
            try Data("important".utf8)
                .write(to: realDir.appendingPathComponent("user-file.txt"))

            // Now prepareDirectory must throw — not delete the user's file.
            #expect(throws: ClaudeAccountDirectory.Error.self) {
                try ClaudeAccountDirectory.prepareDirectory(
                    account: acct, accountStore: acctStore, environmentStore: envStore)
            }

            // Confirm the user file is still there.
            #expect(FileManager.default.fileExists(
                atPath: realDir.appendingPathComponent("user-file.txt").path))
        }
    }

    @Test("throws Error.wrongTool when given non-claude account")
    func throwsOnWrongTool() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            let acct = Account(tool: .codex, displayName: "test")
            try acctStore.save(acct)

            #expect(throws: ClaudeAccountDirectory.Error.self) {
                try ClaudeAccountDirectory.prepareDirectory(
                    account: acct, accountStore: acctStore, environmentStore: envStore)
            }
        }
    }
}
