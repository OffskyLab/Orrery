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

    /// Finding 2 of an external review of #53. The relocation function does two
    /// jobs with completely different lifetimes: moving `origin/` into
    /// `workspaces/origin/` happens once and globally, while repointing a tool's
    /// home symlink is per-tool and can be owed later. Nesting the second inside
    /// the first meant a tool that was not registered on the run that did the
    /// move could never have its symlink repaired — and the unconditional
    /// `markCovered(pending)` at the end then took away even its pending status.
    ///
    /// This reproduces the state after such a run: the move is already done, so
    /// `origin/` is gone, and gemini is still owed its repair.
    @Test("a tool still pending after the move has its home symlink repaired")
    func repairsSymlinkForToolPendingAfterMove() throws {
        try withIsolatedHome {
            let fm = FileManager.default
            let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORRERY_HOME"]!)

            // Post-move state: workspaces/origin/ exists, legacy origin/ does not.
            try fm.createDirectory(at: home.appendingPathComponent("workspaces/origin/gemini"),
                                   withIntermediateDirectories: true)

            // The flag records the move as done for claude and codex only,
            // leaving gemini pending — what a partially-registered first run
            // produces.
            let flag = MigrationFlag(
                url: home.appendingPathComponent(AccountMigration.workspaceStructureFlagFileName),
                legacyCoverage: AccountMigration.legacyBuiltInTools)
            try flag.markCovered(["claude", "codex"])

            // gemini's home symlink still points into the pre-move location.
            let link = Tool.gemini.defaultConfigDir
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(
                at: link, withDestinationURL: home.appendingPathComponent("origin/gemini"))

            AccountMigration.runWorkspaceStructureRelocationIfNeeded(homeURL: home)

            let dest = try fm.destinationOfSymbolicLink(atPath: link.path)
            #expect(dest.contains("/workspaces/origin/gemini"),
                    "a late-registered tool must still get its symlink repaired")
        }
    }

    /// The regression my own first fix introduced. Moving the repair loop out of
    /// the once-only move branch made it reachable for late tools — and also made
    /// it run when the move had *not* happened, repointing a link that still
    /// pointed at valid data toward a target that may not exist. Too narrow
    /// traded for too wide.
    @Test("a link is left alone while legacy origin is still present")
    func leavesLinkAloneWhenMoveHasNotHappened() throws {
        try withIsolatedHome {
            let fm = FileManager.default
            let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORRERY_HOME"]!)

            // Legacy origin/ is still here — the move has not run or failed —
            // and workspaces/origin/ does not exist.
            let legacyGemini = home.appendingPathComponent("origin/gemini")
            try fm.createDirectory(at: legacyGemini, withIntermediateDirectories: true)
            try fm.createDirectory(at: home.appendingPathComponent("workspaces"),
                                   withIntermediateDirectories: true)

            let link = Tool.gemini.defaultConfigDir
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: legacyGemini)

            // Make the move fail by planting a conflicting target it must not
            // overwrite.
            try fm.createDirectory(at: home.appendingPathComponent("workspaces/origin"),
                                   withIntermediateDirectories: true)

            AccountMigration.runWorkspaceStructureRelocationIfNeeded(homeURL: home)

            // The link still points at the data that is actually there.
            let dest = try fm.destinationOfSymbolicLink(atPath: link.path)
            #expect(dest.contains("/origin/gemini"))
            #expect(!dest.contains("/workspaces/origin/"))

            // And nothing was claimed as covered, so a later run can still act.
            let flag = MigrationFlag(
                url: home.appendingPathComponent(AccountMigration.workspaceStructureFlagFileName),
                legacyCoverage: AccountMigration.legacyBuiltInTools)
            #expect(try flag.pending(among: [Tool.gemini.rawValue])
                    == [Tool.gemini.rawValue])
        }
    }

    /// A link that a previous run deleted and failed to recreate is *owed* work,
    /// not settled work. Classifying "no link" as settled is what turned one
    /// transient failure into a permanently missing config path.
    @Test("a missing link for a pending tool is created, not written off")
    func createsMissingLinkForPendingTool() throws {
        try withIsolatedHome {
            let fm = FileManager.default
            let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORRERY_HOME"]!)

            // Post-move state, and gemini's link is simply gone.
            try fm.createDirectory(at: home.appendingPathComponent("workspaces/origin/gemini"),
                                   withIntermediateDirectories: true)
            let link = Tool.gemini.defaultConfigDir
            try? fm.removeItem(at: link)

            let flag = MigrationFlag(
                url: home.appendingPathComponent(AccountMigration.workspaceStructureFlagFileName),
                legacyCoverage: AccountMigration.legacyBuiltInTools)
            try flag.markCovered(["claude", "codex"])

            AccountMigration.runWorkspaceStructureRelocationIfNeeded(homeURL: home)

            let dest = try fm.destinationOfSymbolicLink(atPath: link.path)
            #expect(dest.contains("/workspaces/origin/gemini"))
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
