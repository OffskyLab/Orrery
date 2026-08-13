import Foundation
import Testing
import OrreryCore
@testable import OrreryAccountKit

private func withTempHome(_ body: (_ acctStore: AccountStore, _ envStore: EnvironmentStore) throws -> Void) throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-adapter-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    try body(AccountStore(homeURL: tmpDir), EnvironmentStore(homeURL: tmpDir))
}

@Suite("ClaudeAdapter.prepareDirectory")
struct ClaudeAdapterPrepareTests {
    let adapter = ClaudeAdapter()

    @Test("creates account dir with 5 symlinks to workspace")
    func createsDirAndSymlinks() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .claude, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)

            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let fm = FileManager.default
            #expect(fm.fileExists(atPath: acctDir.path))

            let wsDir = envStore.toolConfigDir(tool: .claude, environment: "origin")
            for sub in ["projects", "memory", "agents", "commands", "todos"] {
                let linkPath = acctDir.appendingPathComponent(sub).path
                let dest = try fm.destinationOfSymbolicLink(atPath: linkPath)
                #expect(dest == wsDir.appendingPathComponent(sub).path, "symlink \(sub) destination mismatch")
            }
        }
    }

    @Test("uses the UUID-resolved workspace dir, not the literal display name")
    func usesUuidPathNotLiteralName() throws {
        try withTempHome { acctStore, envStore in
            // Create a NAMED workspace (gets a UUID dir distinct from its name).
            var ws = Workspace(name: "work", isolateMemory: false)
            ws.tools = [.claude]
            try envStore.save(ws)

            var acct = Account(tool: .claude, displayName: "test")
            acct.workspace = "work"
            try acctStore.save(acct)

            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let uuidPath = envStore.toolConfigDir(tool: .claude, environment: "work")
            let literalPath = envStore.claudeWorkspaceDir(workspace: "work")

            // Precondition: for a named (non-origin) workspace these really are
            // two different paths — otherwise this test would prove nothing.
            #expect(uuidPath.path != literalPath.path)

            let dest = try FileManager.default.destinationOfSymbolicLink(
                atPath: acctDir.appendingPathComponent("projects").path)
            #expect(dest == uuidPath.appendingPathComponent("projects").path)
            #expect(dest != literalPath.appendingPathComponent("projects").path)
        }
    }

    @Test("is idempotent — second call doesn't error or duplicate")
    func isIdempotent() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .claude, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)

            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)
            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let dest = try FileManager.default.destinationOfSymbolicLink(
                atPath: acctDir.appendingPathComponent("projects").path)
            #expect(dest == envStore.toolConfigDir(tool: .claude, environment: "origin")
                .appendingPathComponent("projects").path)
        }
    }

    @Test("repoints a symlink after the account's workspace pin changes")
    func repointsExistingSymlink() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .claude, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)
            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            var ws = Workspace(name: "work", isolateMemory: false)
            ws.tools = [.claude]
            try envStore.save(ws)
            acct.workspace = "work"
            try acctStore.save(acct)
            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let workDir = envStore.toolConfigDir(tool: .claude, environment: "work")
            for sub in ["projects", "memory", "agents", "commands", "todos"] {
                let dest = try FileManager.default.destinationOfSymbolicLink(
                    atPath: acctDir.appendingPathComponent(sub).path)
                #expect(dest == workDir.appendingPathComponent(sub).path)
            }
        }
    }

    @Test("moves a pre-existing real directory into the workspace and symlinks it")
    func movesPreexistingRealDirectory() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .claude, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let realDir = acctDir.appendingPathComponent("projects")
            try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
            try Data("important".utf8).write(to: realDir.appendingPathComponent("user-file.txt"))

            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let fm = FileManager.default
            let wsDir = envStore.toolConfigDir(tool: .claude, environment: "origin")
            let dest = try fm.destinationOfSymbolicLink(atPath: acctDir.appendingPathComponent("projects").path)
            #expect(dest == wsDir.appendingPathComponent("projects").path)
            let moved = wsDir.appendingPathComponent("projects/user-file.txt")
            #expect((try? String(contentsOf: moved, encoding: .utf8)) == "important")
        }
    }

    @Test("backs up a plain file sitting at a base subdir path, then symlinks it")
    func backsUpPlainFileAtBasePath() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .claude, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            try FileManager.default.createDirectory(at: acctDir, withIntermediateDirectories: true)
            try Data("stray".utf8).write(to: acctDir.appendingPathComponent("projects"))

            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let fm = FileManager.default
            let wsDir = envStore.toolConfigDir(tool: .claude, environment: "origin")
            let dest = try fm.destinationOfSymbolicLink(atPath: acctDir.appendingPathComponent("projects").path)
            #expect(dest == wsDir.appendingPathComponent("projects").path)

            let backups = acctDir.appendingPathComponent("backups")
            let premerge = (try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil))?
                .first { $0.lastPathComponent.hasPrefix("premerge-") }
            let saved = try #require(premerge).appendingPathComponent("projects")
            #expect((try? String(contentsOf: saved, encoding: .utf8)) == "stray")
        }
    }

    @Test("throws when given a non-claude account")
    func throwsOnWrongTool() throws {
        try withTempHome { acctStore, envStore in
            let acct = Account(tool: .codex, displayName: "test")
            try acctStore.save(acct)

            #expect(throws: ClaudeAdapter.Error.self) {
                try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)
            }
        }
    }
}

@Suite("ClaudeAdapter.verifySymlinks")
struct ClaudeAdapterVerifyTests {
    let adapter = ClaudeAdapter()

    @Test("returns .ok for freshly prepared dir")
    func okAfterPrepare() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .claude, displayName: "t")
            acct.workspace = "origin"
            try acctStore.save(acct)
            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let status = adapter.verifySymlinks(account: acct, accountStore: acctStore, environmentStore: envStore)
            #expect(status == .ok)
        }
    }

    @Test("returns .missing when dir has no symlinks at all")
    func missingWhenAbsent() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .claude, displayName: "t")
            acct.workspace = "origin"
            try acctStore.save(acct)

            let status = adapter.verifySymlinks(account: acct, accountStore: acctStore, environmentStore: envStore)
            #expect(status == .missing)
        }
    }

    @Test("returns .mismatch when symlinks point at wrong workspace")
    func mismatchWhenWrongTarget() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .claude, displayName: "t")
            acct.workspace = "origin"
            try acctStore.save(acct)
            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            var ws = Workspace(name: "work", isolateMemory: false)
            ws.tools = [.claude]
            try envStore.save(ws)
            acct.workspace = "work"
            try acctStore.save(acct)

            let status = adapter.verifySymlinks(account: acct, accountStore: acctStore, environmentStore: envStore)
            #expect(status == .mismatch)
        }
    }

    @Test("returns .notApplicable for non-claude account")
    func notApplicableForNonClaude() throws {
        try withTempHome { acctStore, envStore in
            let acct = Account(tool: .codex, displayName: "x")
            try acctStore.save(acct)

            let status = adapter.verifySymlinks(account: acct, accountStore: acctStore, environmentStore: envStore)
            #expect(status == .notApplicable)
        }
    }

    @Test("returns .missing when symlink target dir was deleted (broken link)")
    func missingWhenBrokenLink() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .claude, displayName: "t")
            acct.workspace = "origin"
            try acctStore.save(acct)
            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let wsDir = envStore.toolConfigDir(tool: .claude, environment: "origin")
            try FileManager.default.removeItem(at: wsDir)

            let status = adapter.verifySymlinks(account: acct, accountStore: acctStore, environmentStore: envStore)
            #expect(status == .missing)
        }
    }
}
