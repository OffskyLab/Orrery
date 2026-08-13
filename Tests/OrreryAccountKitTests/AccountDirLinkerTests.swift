import Foundation
import Testing
@testable import OrreryAccountKit

private func withTempDirs(_ body: (_ accountDir: URL, _ workspaceDir: URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("account-dir-linker-\(UUID().uuidString)")
    let accountDir = base.appendingPathComponent("account")
    let workspaceDir = base.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try body(accountDir, workspaceDir)
}

@Suite("AccountDirSharingPolicy")
struct AccountDirSharingPolicyTests {
    @Test("blocklist shares everything except listed names")
    func blocklistShares() {
        let policy = AccountDirSharingPolicy.blocklist(["cache", "backups"])
        #expect(policy.isShareable("skills"))
        #expect(policy.isShareable("projects"))
        #expect(!policy.isShareable("cache"))
        #expect(!policy.isShareable("backups"))
    }

    @Test("allowlist shares only listed names")
    func allowlistShares() {
        let policy = AccountDirSharingPolicy.allowlist(["skills", "plugins"])
        #expect(policy.isShareable("skills"))
        #expect(policy.isShareable("plugins"))
        #expect(!policy.isShareable("memories"))
        #expect(!policy.isShareable("config.toml"))
    }

    @Test("both policies always reject dotfiles")
    func dotfilesAlwaysPrivate() {
        #expect(!AccountDirSharingPolicy.blocklist([]).isShareable(".DS_Store"))
        #expect(!AccountDirSharingPolicy.allowlist(["skills"]).isShareable(".skills"))
    }
}

@Suite("AccountDirLinker.linkAccountDirsToWorkspace")
struct AccountDirLinkerLinkTests {
    @Test("blocklist: real dir in account moves into workspace and becomes a symlink")
    func blocklistMovesRealDir() throws {
        try withTempDirs { accountDir, workspaceDir in
            let skillsDir = accountDir.appendingPathComponent("skills")
            try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
            try Data("hi".utf8).write(to: skillsDir.appendingPathComponent("a.md"))

            let warnings = AccountDirLinker.linkAccountDirsToWorkspace(
                accountDir: accountDir, workspaceDir: workspaceDir,
                policy: .blocklist(["cache"]))
            #expect(warnings.isEmpty)

            let fm = FileManager.default
            let dest = try fm.destinationOfSymbolicLink(atPath: skillsDir.path)
            #expect(dest == workspaceDir.appendingPathComponent("skills").path)
            #expect(fm.fileExists(atPath: workspaceDir.appendingPathComponent("skills/a.md").path))
        }
    }

    @Test("blocklist: blocked name is left as a real directory, not migrated")
    func blocklistLeavesBlockedNamesAlone() throws {
        try withTempDirs { accountDir, workspaceDir in
            let cacheDir = accountDir.appendingPathComponent("cache")
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

            AccountDirLinker.linkAccountDirsToWorkspace(
                accountDir: accountDir, workspaceDir: workspaceDir,
                policy: .blocklist(["cache"]))

            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: cacheDir.path, isDirectory: &isDir)
            #expect(exists && isDir.boolValue)
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: cacheDir.path)) == nil)
        }
    }

    @Test("allowlist: only listed names migrate, everything else stays put")
    func allowlistOnlyMigratesListed() throws {
        try withTempDirs { accountDir, workspaceDir in
            try FileManager.default.createDirectory(
                at: accountDir.appendingPathComponent("skills"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: accountDir.appendingPathComponent("memories"), withIntermediateDirectories: true)

            AccountDirLinker.linkAccountDirsToWorkspace(
                accountDir: accountDir, workspaceDir: workspaceDir,
                policy: .allowlist(["skills"]))

            let fm = FileManager.default
            #expect((try? fm.destinationOfSymbolicLink(
                atPath: accountDir.appendingPathComponent("skills").path)) != nil)
            #expect((try? fm.destinationOfSymbolicLink(
                atPath: accountDir.appendingPathComponent("memories").path)) == nil)
            var isDir: ObjCBool = false
            #expect(fm.fileExists(atPath: accountDir.appendingPathComponent("memories").path, isDirectory: &isDir)
                && isDir.boolValue)
        }
    }

    @Test("plain files are never migrated, even when their name is shareable")
    func plainFilesNeverMigrate() throws {
        try withTempDirs { accountDir, workspaceDir in
            try Data("secret".utf8).write(to: accountDir.appendingPathComponent("skills"))

            AccountDirLinker.linkAccountDirsToWorkspace(
                accountDir: accountDir, workspaceDir: workspaceDir,
                policy: .allowlist(["skills"]))

            #expect((try? FileManager.default.destinationOfSymbolicLink(
                atPath: accountDir.appendingPathComponent("skills").path)) == nil)
            #expect(FileManager.default.fileExists(atPath: accountDir.appendingPathComponent("skills").path))
        }
    }

    @Test("conflicting file in workspace is backed up, not overwritten or lost")
    func conflictsAreBackedUpNotLost() throws {
        try withTempDirs { accountDir, workspaceDir in
            let acctSkills = accountDir.appendingPathComponent("skills")
            try FileManager.default.createDirectory(at: acctSkills, withIntermediateDirectories: true)
            try Data("account-version".utf8).write(to: acctSkills.appendingPathComponent("dup.md"))

            let wsSkills = workspaceDir.appendingPathComponent("skills")
            try FileManager.default.createDirectory(at: wsSkills, withIntermediateDirectories: true)
            try Data("workspace-version".utf8).write(to: wsSkills.appendingPathComponent("dup.md"))

            AccountDirLinker.linkAccountDirsToWorkspace(
                accountDir: accountDir, workspaceDir: workspaceDir,
                policy: .allowlist(["skills"]))

            // Workspace's copy wins at the live path...
            let liveContent = try String(contentsOf: wsSkills.appendingPathComponent("dup.md"), encoding: .utf8)
            #expect(liveContent == "workspace-version")

            // ...but the account's copy was backed up, not deleted.
            let backups = accountDir.appendingPathComponent("backups")
            let backupFiles = (try? FileManager.default.subpathsOfDirectory(atPath: backups.path)) ?? []
            #expect(backupFiles.contains { $0.hasSuffix("dup.md") })
        }
    }

    @Test("idempotent: running twice does not error or duplicate")
    func idempotent() throws {
        try withTempDirs { accountDir, workspaceDir in
            try FileManager.default.createDirectory(
                at: accountDir.appendingPathComponent("skills"), withIntermediateDirectories: true)

            let policy = AccountDirSharingPolicy.allowlist(["skills"])
            AccountDirLinker.linkAccountDirsToWorkspace(accountDir: accountDir, workspaceDir: workspaceDir, policy: policy)
            let warnings = AccountDirLinker.linkAccountDirsToWorkspace(accountDir: accountDir, workspaceDir: workspaceDir, policy: policy)
            #expect(warnings.isEmpty)

            let dest = try FileManager.default.destinationOfSymbolicLink(
                atPath: accountDir.appendingPathComponent("skills").path)
            #expect(dest == workspaceDir.appendingPathComponent("skills").path)
        }
    }
}

@Suite("AccountDirLinker.mirrorWorkspaceDirsToAccount")
struct AccountDirLinkerMirrorTests {
    @Test("symlinks a shareable workspace dir the account is missing")
    func gapFillsMissingSymlink() throws {
        try withTempDirs { accountDir, workspaceDir in
            try FileManager.default.createDirectory(
                at: workspaceDir.appendingPathComponent("plugins"), withIntermediateDirectories: true)

            let warnings = AccountDirLinker.mirrorWorkspaceDirsToAccount(
                accountDir: accountDir, workspaceDir: workspaceDir,
                policy: .allowlist(["plugins"]))
            #expect(warnings.isEmpty)

            let dest = try FileManager.default.destinationOfSymbolicLink(
                atPath: accountDir.appendingPathComponent("plugins").path)
            #expect(dest == workspaceDir.appendingPathComponent("plugins").path)
        }
    }

    @Test("does not touch a name the account already has, of any kind")
    func leavesOccupiedNamesAlone() throws {
        try withTempDirs { accountDir, workspaceDir in
            try FileManager.default.createDirectory(
                at: workspaceDir.appendingPathComponent("plugins"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: accountDir.appendingPathComponent("plugins"), withIntermediateDirectories: true)

            AccountDirLinker.mirrorWorkspaceDirsToAccount(
                accountDir: accountDir, workspaceDir: workspaceDir,
                policy: .allowlist(["plugins"]))

            #expect((try? FileManager.default.destinationOfSymbolicLink(
                atPath: accountDir.appendingPathComponent("plugins").path)) == nil)
        }
    }

    @Test("skips names outside the policy")
    func skipsUnlistedNames() throws {
        try withTempDirs { accountDir, workspaceDir in
            try FileManager.default.createDirectory(
                at: workspaceDir.appendingPathComponent("cache"), withIntermediateDirectories: true)

            AccountDirLinker.mirrorWorkspaceDirsToAccount(
                accountDir: accountDir, workspaceDir: workspaceDir,
                policy: .allowlist(["skills"]))

            #expect(!FileManager.default.fileExists(atPath: accountDir.appendingPathComponent("cache").path))
        }
    }
}
