import Foundation
import Testing
import OrreryCore
@testable import OrreryAccountKit

private func withTempHome(_ body: (_ acctStore: AccountStore, _ envStore: EnvironmentStore) throws -> Void) throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-adapter-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    try body(AccountStore(homeURL: tmpDir), EnvironmentStore(homeURL: tmpDir))
}

@Suite("CodexAdapter.prepareDirectory")
struct CodexAdapterPrepareTests {
    let adapter = CodexAdapter()

    @Test("creates account dir with symlinks for the allowlisted subdirs only")
    func createsDirAndSymlinks() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .codex, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)

            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .codex)
            let fm = FileManager.default
            let wsDir = envStore.toolConfigDir(tool: .codex, environment: "origin")
            for sub in CodexAdapter.baseSharedSubdirs {
                let dest = try fm.destinationOfSymbolicLink(atPath: acctDir.appendingPathComponent(sub).path)
                #expect(dest == wsDir.appendingPathComponent(sub).path)
            }
        }
    }

    @Test("runtime noise sitting in the account dir is never migrated into the workspace")
    func leavesRuntimeNoisePrivate() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .codex, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .codex)
            try FileManager.default.createDirectory(at: acctDir, withIntermediateDirectories: true)
            let memories = acctDir.appendingPathComponent("memories")
            try FileManager.default.createDirectory(at: memories, withIntermediateDirectories: true)
            try Data("private".utf8).write(to: acctDir.appendingPathComponent("auth.json"))

            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let fm = FileManager.default
            #expect((try? fm.destinationOfSymbolicLink(atPath: memories.path)) == nil)
            var isDir: ObjCBool = false
            #expect(fm.fileExists(atPath: memories.path, isDirectory: &isDir) && isDir.boolValue)
            #expect((try? String(
                contentsOf: acctDir.appendingPathComponent("auth.json"), encoding: .utf8)) == "private")
        }
    }

    @Test("self-heals when the workspace side of a base subdir is a dangling symlink")
    func healsDanglingWorkspaceSideSymlink() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .codex, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)

            // Reproduces the real-world bug: workspaces/origin/codex/sessions
            // was left as a symlink into a since-deleted test ORRERY_HOME
            // (from an earlier isolation test), so it's now a broken symlink
            // sitting where a real directory needs to be.
            let wsDir = envStore.toolConfigDir(tool: .codex, environment: "origin")
            try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: wsDir.appendingPathComponent("sessions").path,
                withDestinationPath: "/tmp/definitely-does-not-exist-\(UUID().uuidString)")

            // Must not throw — self-heals by replacing the dangling symlink
            // with a real directory.
            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .codex)
            let dest = try FileManager.default.destinationOfSymbolicLink(
                atPath: acctDir.appendingPathComponent("sessions").path)
            #expect(dest == wsDir.appendingPathComponent("sessions").path)
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: dest, isDirectory: &isDir) && isDir.boolValue)
        }
    }

    @Test("throws when given a non-codex account")
    func throwsOnWrongTool() throws {
        try withTempHome { acctStore, envStore in
            let acct = Account(tool: .claude, displayName: "test")
            try acctStore.save(acct)

            #expect(throws: CodexAdapter.Error.self) {
                try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)
            }
        }
    }

    @Test("is idempotent")
    func isIdempotent() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .codex, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)

            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)
            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .codex)
            let dest = try FileManager.default.destinationOfSymbolicLink(
                atPath: acctDir.appendingPathComponent("skills").path)
            #expect(dest == envStore.toolConfigDir(tool: .codex, environment: "origin")
                .appendingPathComponent("skills").path)
        }
    }
}

@Suite("CodexAdapter.verifySymlinks")
struct CodexAdapterVerifyTests {
    let adapter = CodexAdapter()

    @Test("returns .ok for freshly prepared dir")
    func okAfterPrepare() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .codex, displayName: "t")
            acct.workspace = "origin"
            try acctStore.save(acct)
            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            #expect(adapter.verifySymlinks(account: acct, accountStore: acctStore, environmentStore: envStore) == .ok)
        }
    }

    @Test("returns .missing before prepareDirectory has run")
    func missingBeforePrepare() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .codex, displayName: "t")
            acct.workspace = "origin"
            try acctStore.save(acct)

            #expect(adapter.verifySymlinks(account: acct, accountStore: acctStore, environmentStore: envStore) == .missing)
        }
    }

    @Test("returns .notApplicable for a non-codex account")
    func notApplicableForOtherTool() throws {
        try withTempHome { acctStore, envStore in
            let acct = Account(tool: .gemini, displayName: "x")
            try acctStore.save(acct)

            #expect(adapter.verifySymlinks(account: acct, accountStore: acctStore, environmentStore: envStore) == .notApplicable)
        }
    }

    @Test("self-heals a dangling symlink (target directory deleted) back to .ok")
    func selfHealsDanglingSymlink() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .codex, displayName: "t")
            acct.workspace = "origin"
            try acctStore.save(acct)
            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            // Simulate the real dangling-sessions bug: the workspace dir is gone.
            let wsDir = envStore.toolConfigDir(tool: .codex, environment: "origin")
            try FileManager.default.removeItem(at: wsDir)
            #expect(adapter.verifySymlinks(account: acct, accountStore: acctStore, environmentStore: envStore) == .missing)

            // prepareDirectory repairs it.
            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)
            #expect(adapter.verifySymlinks(account: acct, accountStore: acctStore, environmentStore: envStore) == .ok)
        }
    }
}
