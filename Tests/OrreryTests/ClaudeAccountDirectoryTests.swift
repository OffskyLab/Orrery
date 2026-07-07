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

    @Test("moves a pre-existing real directory into the workspace and symlinks it")
    func movesPreexistingRealDirectory() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            var acct = Account(tool: .claude, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let realDir = acctDir.appendingPathComponent("projects")
            try FileManager.default.createDirectory(
                at: realDir, withIntermediateDirectories: true)
            try Data("important".utf8)
                .write(to: realDir.appendingPathComponent("user-file.txt"))

            try ClaudeAccountDirectory.prepareDirectory(
                account: acct, accountStore: acctStore, environmentStore: envStore)

            let fm = FileManager.default
            let wsDir = envStore.claudeWorkspaceDir(workspace: "origin")
            // account/projects is now a symlink into the workspace.
            let dest = try fm.destinationOfSymbolicLink(
                atPath: acctDir.appendingPathComponent("projects").path)
            #expect(dest == wsDir.appendingPathComponent("projects").path)
            // The user's file was moved into the workspace, not lost.
            let moved = wsDir.appendingPathComponent("projects/user-file.txt")
            #expect(fm.fileExists(atPath: moved.path))
            #expect((try? String(contentsOf: moved, encoding: .utf8)) == "important")
        }
    }

    @Test("backs up a plain file sitting at a base subdir path, then symlinks it")
    func backsUpPlainFileAtBasePath() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            var acct = Account(tool: .claude, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            try FileManager.default.createDirectory(
                at: acctDir, withIntermediateDirectories: true)
            // A plain FILE (not dir/symlink) occupies the base "projects" path.
            try Data("stray".utf8)
                .write(to: acctDir.appendingPathComponent("projects"))

            try ClaudeAccountDirectory.prepareDirectory(
                account: acct, accountStore: acctStore, environmentStore: envStore)

            let fm = FileManager.default
            let wsDir = envStore.claudeWorkspaceDir(workspace: "origin")
            // projects is now a proper symlink to the workspace.
            let dest = try fm.destinationOfSymbolicLink(
                atPath: acctDir.appendingPathComponent("projects").path)
            #expect(dest == wsDir.appendingPathComponent("projects").path)
            // the stray file was preserved under backups/premerge-*/projects
            let backups = acctDir.appendingPathComponent("backups")
            let premerge = (try? fm.contentsOfDirectory(
                at: backups, includingPropertiesForKeys: nil))?
                .first { $0.lastPathComponent.hasPrefix("premerge-") }
            let saved = try #require(premerge).appendingPathComponent("projects")
            #expect((try? String(contentsOf: saved, encoding: .utf8)) == "stray")
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

@Suite("ClaudeAccountDirectory.verifySymlinks")
struct ClaudeAccountDirectoryVerifyTests {
    @Test("returns .ok for freshly prepared dir")
    func okAfterPrepare() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            var acct = Account(tool: .claude, displayName: "t")
            acct.workspace = "origin"
            try acctStore.save(acct)
            try ClaudeAccountDirectory.prepareDirectory(
                account: acct, accountStore: acctStore, environmentStore: envStore)

            let status = ClaudeAccountDirectory.verifySymlinks(
                account: acct, accountStore: acctStore, environmentStore: envStore)
            #expect(status == .ok)
        }
    }

    @Test("returns .missing when dir has no symlinks at all")
    func missingWhenAbsent() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            var acct = Account(tool: .claude, displayName: "t")
            acct.workspace = "origin"
            try acctStore.save(acct)
            // no prepareDirectory call

            let status = ClaudeAccountDirectory.verifySymlinks(
                account: acct, accountStore: acctStore, environmentStore: envStore)
            #expect(status == .missing)
        }
    }

    @Test("returns .mismatch when symlinks point at wrong workspace")
    func mismatchWhenWrongTarget() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            var acct = Account(tool: .claude, displayName: "t")
            acct.workspace = "origin"
            try acctStore.save(acct)
            try ClaudeAccountDirectory.prepareDirectory(
                account: acct, accountStore: acctStore, environmentStore: envStore)

            // Manually flip account.workspace without repointing.
            acct.workspace = "work"
            try acctStore.save(acct)

            let status = ClaudeAccountDirectory.verifySymlinks(
                account: acct, accountStore: acctStore, environmentStore: envStore)
            #expect(status == .mismatch)
        }
    }

    @Test("returns .notApplicable for non-claude account")
    func notApplicableForNonClaude() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            let acct = Account(tool: .codex, displayName: "x")
            try acctStore.save(acct)

            let status = ClaudeAccountDirectory.verifySymlinks(
                account: acct, accountStore: acctStore, environmentStore: envStore)
            #expect(status == .notApplicable)
        }
    }

    @Test("returns .missing when symlink target dir was deleted (broken link)")
    func missingWhenBrokenLink() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            var acct = Account(tool: .claude, displayName: "t")
            acct.workspace = "origin"
            try acctStore.save(acct)
            try ClaudeAccountDirectory.prepareDirectory(
                account: acct, accountStore: acctStore, environmentStore: envStore)

            // Nuke the workspace dir entirely — symlinks remain but targets vanish.
            let wsDir = envStore.claudeWorkspaceDir(workspace: "origin")
            try FileManager.default.removeItem(at: wsDir)

            let status = ClaudeAccountDirectory.verifySymlinks(
                account: acct, accountStore: acctStore, environmentStore: envStore)
            #expect(status == .missing)
        }
    }
}

@Suite("ClaudeAccountDirectory.linkAccountDirsToWorkspace")
struct ClaudeAccountDirectoryLinkTests {

    /// 建立一對隔離的 acct / ws 暫存目錄;測試結束自動清掉。
    private func makeTempPair() throws -> (acct: URL, ws: URL, base: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("linktest-\(UUID().uuidString)")
        let acct = base.appendingPathComponent("acct")
        let ws = base.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: acct, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        return (acct, ws, base)
    }

    /// 在 backups/ 底下找出這次執行產生的 premerge-* 目錄。
    private func premergeDir(in acct: URL) -> URL? {
        let backups = acct.appendingPathComponent("backups")
        let kids = (try? FileManager.default.contentsOfDirectory(
            at: backups, includingPropertiesForKeys: nil)) ?? []
        return kids.first { $0.lastPathComponent.hasPrefix("premerge-") }
    }

    @Test("moves a brand-new real dir into the workspace and symlinks it")
    func movesNewDir() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        let skills = acct.appendingPathComponent("skills")
        try fm.createDirectory(at: skills, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: skills.appendingPathComponent("foo.md"))

        let warnings = ClaudeAccountDirectory.linkAccountDirsToWorkspace(
            accountDir: acct, workspaceDir: ws)

        #expect(warnings.isEmpty)
        let dest = try fm.destinationOfSymbolicLink(
            atPath: acct.appendingPathComponent("skills").path)
        #expect(dest == ws.appendingPathComponent("skills").path)
        let moved = ws.appendingPathComponent("skills/foo.md")
        #expect(fm.fileExists(atPath: moved.path))
        #expect((try? String(contentsOf: moved, encoding: .utf8)) == "hello")
    }

    @Test("mirrors a workspace-only dir back into the account as a symlink")
    func mirrorsWorkspaceOnlyDir() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        // A dir another account created in the shared workspace; this account
        // has no counterpart for it.
        let wsOnly = ws.appendingPathComponent("sandboxes")
        try fm.createDirectory(at: wsOnly, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: wsOnly.appendingPathComponent("a.txt"))

        let warnings = ClaudeAccountDirectory.linkAccountDirsToWorkspace(
            accountDir: acct, workspaceDir: ws)
        #expect(warnings.isEmpty)

        let dest = try fm.destinationOfSymbolicLink(
            atPath: acct.appendingPathComponent("sandboxes").path)
        #expect(dest == wsOnly.path)
    }

    @Test("does not mirror a private (blacklisted) workspace dir into the account")
    func skipsPrivateWorkspaceDir() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        try fm.createDirectory(
            at: ws.appendingPathComponent("cache"), withIntermediateDirectories: true)

        _ = ClaudeAccountDirectory.linkAccountDirsToWorkspace(
            accountDir: acct, workspaceDir: ws)

        #expect(!fm.fileExists(atPath: acct.appendingPathComponent("cache").path))
        #expect((try? fm.destinationOfSymbolicLink(
            atPath: acct.appendingPathComponent("cache").path)) == nil)
    }

    @Test("does not mirror a workspace file (only directories are mirrored)")
    func skipsWorkspaceFile() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        try Data("prog".utf8).write(to: ws.appendingPathComponent("statusline.js"))

        _ = ClaudeAccountDirectory.linkAccountDirsToWorkspace(
            accountDir: acct, workspaceDir: ws)

        #expect(!fm.fileExists(atPath: acct.appendingPathComponent("statusline.js").path))
        #expect((try? fm.destinationOfSymbolicLink(
            atPath: acct.appendingPathComponent("statusline.js").path)) == nil)
    }

    @Test("mirror pass is idempotent — second run leaves the symlink and no warnings")
    func mirrorIsIdempotent() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        try fm.createDirectory(
            at: ws.appendingPathComponent("sandboxes"), withIntermediateDirectories: true)

        _ = ClaudeAccountDirectory.linkAccountDirsToWorkspace(accountDir: acct, workspaceDir: ws)
        let warnings = ClaudeAccountDirectory.linkAccountDirsToWorkspace(accountDir: acct, workspaceDir: ws)

        #expect(warnings.isEmpty)
        let dest = try fm.destinationOfSymbolicLink(
            atPath: acct.appendingPathComponent("sandboxes").path)
        #expect(dest == ws.appendingPathComponent("sandboxes").path)
    }

    @Test("union merge keeps the workspace copy and backs up the account copy")
    func unionWorkspaceWins() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        let acctAgents = acct.appendingPathComponent("agents")
        let wsAgents = ws.appendingPathComponent("agents")
        try fm.createDirectory(at: acctAgents, withIntermediateDirectories: true)
        try fm.createDirectory(at: wsAgents, withIntermediateDirectories: true)
        try Data("acct".utf8).write(to: acctAgents.appendingPathComponent("shared.md"))
        try Data("acct-only".utf8).write(to: acctAgents.appendingPathComponent("only.md"))
        try Data("ws".utf8).write(to: wsAgents.appendingPathComponent("shared.md"))

        let warnings = ClaudeAccountDirectory.linkAccountDirsToWorkspace(
            accountDir: acct, workspaceDir: ws)
        #expect(warnings.isEmpty)

        let shared = ws.appendingPathComponent("agents/shared.md")
        #expect((try? String(contentsOf: shared, encoding: .utf8)) == "ws")
        let only = ws.appendingPathComponent("agents/only.md")
        #expect((try? String(contentsOf: only, encoding: .utf8)) == "acct-only")
        let dest = try fm.destinationOfSymbolicLink(
            atPath: acct.appendingPathComponent("agents").path)
        #expect(dest == wsAgents.path)
        let backup = try #require(premergeDir(in: acct))
        let backedUp = backup.appendingPathComponent("agents/shared.md")
        #expect((try? String(contentsOf: backedUp, encoding: .utf8)) == "acct")
    }

    @Test("nested dirs merge recursively (both children survive)")
    func nestedMerge() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        try fm.createDirectory(
            at: acct.appendingPathComponent("plugins/foo"), withIntermediateDirectories: true)
        try Data("b".utf8).write(to: acct.appendingPathComponent("plugins/foo/bar.txt"))
        try fm.createDirectory(
            at: ws.appendingPathComponent("plugins/foo"), withIntermediateDirectories: true)
        try Data("z".utf8).write(to: ws.appendingPathComponent("plugins/foo/baz.txt"))

        _ = ClaudeAccountDirectory.linkAccountDirsToWorkspace(accountDir: acct, workspaceDir: ws)

        #expect(fm.fileExists(atPath: ws.appendingPathComponent("plugins/foo/bar.txt").path))
        #expect(fm.fileExists(atPath: ws.appendingPathComponent("plugins/foo/baz.txt").path))
        let dest = try fm.destinationOfSymbolicLink(
            atPath: acct.appendingPathComponent("plugins").path)
        #expect(dest == ws.appendingPathComponent("plugins").path)
    }

    @Test("already-correct symlink is a no-op (no backup created)")
    func correctSymlinkNoop() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        let target = ws.appendingPathComponent("projects")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: acct.appendingPathComponent("projects"), withDestinationURL: target)

        let warnings = ClaudeAccountDirectory.linkAccountDirsToWorkspace(
            accountDir: acct, workspaceDir: ws)
        #expect(warnings.isEmpty)
        let dest = try fm.destinationOfSymbolicLink(
            atPath: acct.appendingPathComponent("projects").path)
        #expect(dest == target.path)
        #expect(premergeDir(in: acct) == nil)
    }

    @Test("symlink pointing at the wrong place is repointed")
    func repointsWrongSymlink() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        let wrong = base.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: wrong, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: acct.appendingPathComponent("projects"), withDestinationURL: wrong)

        _ = ClaudeAccountDirectory.linkAccountDirsToWorkspace(accountDir: acct, workspaceDir: ws)

        let dest = try fm.destinationOfSymbolicLink(
            atPath: acct.appendingPathComponent("projects").path)
        #expect(dest == ws.appendingPathComponent("projects").path)
    }

    @Test("private dirs and dotfiles and top-level files are untouched")
    func privateAndFilesUntouched() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        try fm.createDirectory(
            at: acct.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try Data("c".utf8).write(to: acct.appendingPathComponent("cache/x"))
        try fm.createDirectory(
            at: acct.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: acct.appendingPathComponent("settings.json"))

        _ = ClaudeAccountDirectory.linkAccountDirsToWorkspace(accountDir: acct, workspaceDir: ws)

        #expect(ClaudeAccountDirectory.isRealDirForTest(acct.appendingPathComponent("cache")))
        #expect(fm.fileExists(atPath: acct.appendingPathComponent("cache/x").path))
        #expect(!fm.fileExists(atPath: ws.appendingPathComponent("cache").path))
        #expect(ClaudeAccountDirectory.isRealDirForTest(acct.appendingPathComponent(".hidden")))
        #expect(fm.fileExists(atPath: acct.appendingPathComponent("settings.json").path))
        #expect(!fm.fileExists(atPath: ws.appendingPathComponent("settings.json").path))
    }

    @Test("links multiple shareable dirs in a single call")
    func linksMultipleDirs() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        for name in ["skills", "plugins"] {
            let d = acct.appendingPathComponent(name)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try Data(name.utf8).write(to: d.appendingPathComponent("f.md"))
        }
        let warnings = ClaudeAccountDirectory.linkAccountDirsToWorkspace(
            accountDir: acct, workspaceDir: ws)
        #expect(warnings.isEmpty)
        for name in ["skills", "plugins"] {
            let dest = try fm.destinationOfSymbolicLink(
                atPath: acct.appendingPathComponent(name).path)
            #expect(dest == ws.appendingPathComponent(name).path)
            #expect(fm.fileExists(atPath: ws.appendingPathComponent("\(name)/f.md").path))
        }
    }

    @Test("returns a warning and leaves the account dir intact when linking fails")
    func warningOnFailure() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        // A plain FILE occupies the workspace target path → createDirectory fails.
        try Data("x".utf8).write(to: ws.appendingPathComponent("skills"))
        let acctSkills = acct.appendingPathComponent("skills")
        try fm.createDirectory(at: acctSkills, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: acctSkills.appendingPathComponent("foo.md"))

        let warnings = ClaudeAccountDirectory.linkAccountDirsToWorkspace(
            accountDir: acct, workspaceDir: ws)

        #expect(warnings.count == 1)
        #expect(warnings.first?.hasPrefix("skills:") == true)
        #expect(ClaudeAccountDirectory.isRealDirForTest(acctSkills))
        #expect((try? String(contentsOf: acctSkills.appendingPathComponent("foo.md"),
                             encoding: .utf8)) == "keep")
    }

    @Test("dangling symlink at a nested workspace path does not abort the merge")
    func danglingSymlinkNoAbort() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        // account/plugins/foo (real dir) with a file.
        try fm.createDirectory(
            at: acct.appendingPathComponent("plugins/foo"),
            withIntermediateDirectories: true)
        try Data("data".utf8)
            .write(to: acct.appendingPathComponent("plugins/foo/x.txt"))
        // workspace/plugins/foo exists as a DANGLING symlink (target deleted).
        try fm.createDirectory(
            at: ws.appendingPathComponent("plugins"),
            withIntermediateDirectories: true)
        let deadTarget = base.appendingPathComponent("gone")
        try fm.createSymbolicLink(
            at: ws.appendingPathComponent("plugins/foo"),
            withDestinationURL: deadTarget)

        let warnings = ClaudeAccountDirectory.linkAccountDirsToWorkspace(
            accountDir: acct, workspaceDir: ws)

        // No permanent abort: account/plugins becomes a symlink to the workspace.
        #expect(warnings.isEmpty)
        let dest = try fm.destinationOfSymbolicLink(
            atPath: acct.appendingPathComponent("plugins").path)
        #expect(dest == ws.appendingPathComponent("plugins").path)
        // The conflicting account subtree was preserved under backups (not lost).
        let backups = acct.appendingPathComponent("backups")
        let premerge = (try? fm.contentsOfDirectory(
            at: backups, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasPrefix("premerge-") }
        let saved = try #require(premerge)
            .appendingPathComponent("plugins/foo/x.txt")
        #expect((try? String(contentsOf: saved, encoding: .utf8)) == "data")
    }

    @Test("cc-statusline stays per-account (never shared to the workspace)")
    func ccStatuslineStaysPrivate() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        try fm.createDirectory(
            at: acct.appendingPathComponent("cc-statusline"),
            withIntermediateDirectories: true)
        try Data("state".utf8)
            .write(to: acct.appendingPathComponent("cc-statusline/state.json"))

        let warnings = ClaudeAccountDirectory.linkAccountDirsToWorkspace(
            accountDir: acct, workspaceDir: ws)
        #expect(warnings.isEmpty)

        // Stays a real per-account dir with its content; not symlinked/shared.
        #expect(ClaudeAccountDirectory.isRealDirForTest(
            acct.appendingPathComponent("cc-statusline")))
        #expect(fm.fileExists(
            atPath: acct.appendingPathComponent("cc-statusline/state.json").path))
        #expect(!fm.fileExists(
            atPath: ws.appendingPathComponent("cc-statusline").path))
    }

    @Test("an already-shared cc-statusline symlink is un-shared back to a per-account dir")
    func ccStatuslineUnshared() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        // Pre-fix state: workspace holds cc-statusline; account symlinks into it.
        try fm.createDirectory(
            at: ws.appendingPathComponent("cc-statusline"),
            withIntermediateDirectories: true)
        try Data("shared".utf8)
            .write(to: ws.appendingPathComponent("cc-statusline/shared.json"))
        try fm.createSymbolicLink(
            at: acct.appendingPathComponent("cc-statusline"),
            withDestinationURL: ws.appendingPathComponent("cc-statusline"))

        _ = ClaudeAccountDirectory.linkAccountDirsToWorkspace(
            accountDir: acct, workspaceDir: ws)

        // account/cc-statusline is now a real per-account dir, not a symlink.
        #expect((try? fm.destinationOfSymbolicLink(
            atPath: acct.appendingPathComponent("cc-statusline").path)) == nil)
        #expect(ClaudeAccountDirectory.isRealDirForTest(
            acct.appendingPathComponent("cc-statusline")))
        // Removing the symlink never deletes the workspace target's data.
        #expect(fm.fileExists(
            atPath: ws.appendingPathComponent("cc-statusline/shared.json").path))
    }
}
