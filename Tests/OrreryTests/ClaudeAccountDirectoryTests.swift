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
}
