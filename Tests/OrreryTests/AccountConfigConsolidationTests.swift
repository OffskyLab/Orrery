import Foundation
import Testing
@testable import OrreryCore

/// Phase C: folding the takeover-captured workspace settings into each claude
/// account dir, so the account dir is the authoritative config home.
@Suite("AccountConfigConsolidation")
struct AccountConfigConsolidationTests {

    @Test("mergedClaudeSettings: workspace base + account override, drops workspace statusLine")
    func mergePure() {
        let workspace: [String: Any] = [
            "permissions": ["defaultMode": "auto"],
            "hooks": ["Notification": []],
            "statusLine": ["command": "node /stale/origin/statusline.js"],
            "theme": "light",
        ]
        let account: [String: Any] = [
            "statusLine": ["command": "node /account/statusline.js"],
            "theme": "dark",
        ]

        let merged = AccountMigration.mergedClaudeSettings(workspace: workspace, account: account)

        #expect(merged["permissions"] != nil)                 // inherited from workspace
        #expect(merged["hooks"] != nil)                       // inherited from workspace
        #expect((merged["theme"] as? String) == "dark")       // account overrides
        let sl = merged["statusLine"] as? [String: Any]
        #expect((sl?["command"] as? String) == "node /account/statusline.js") // account's, not workspace's
    }

    @Test("mergedClaudeSettings: account without statusLine does NOT inherit the workspace's")
    func mergeNoAccountStatusLine() {
        let workspace: [String: Any] = [
            "permissions": ["defaultMode": "auto"],
            "statusLine": ["command": "node /stale/origin/statusline.js"],
        ]
        let merged = AccountMigration.mergedClaudeSettings(workspace: workspace, account: [:])
        #expect(merged["permissions"] != nil)
        #expect(merged["statusLine"] == nil)   // workspace statusLine is dropped, not propagated
    }

    @Test("consolidate folds workspace settings into the account dir, keeps account statusLine")
    func consolidateFiles() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("orrery-consol-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let acctStore = AccountStore(homeURL: home)
        let envStore = EnvironmentStore(homeURL: home)

        // A claude account pinned to the default "origin" workspace.
        let acct = Account(tool: .claude, displayName: "origin")
        try acctStore.save(acct)
        let accountDir = acctStore.accountDir(id: acct.id, tool: .claude)
        let accountSettings = accountDir.appendingPathComponent("settings.json")

        // Account dir has only its own statusLine + theme.
        try ClaudeJsonMerge.saveJSON(
            ["statusLine": ["command": "node \(accountDir.path)/statusline.js"],
             "theme": "dark"],
            at: accountSettings)

        // Workspace holds the takeover-captured real settings (+ a stale statusLine).
        let wsDir = envStore.claudeWorkspaceDir(workspace: "origin")
        try fm.createDirectory(at: wsDir, withIntermediateDirectories: true)
        try ClaudeJsonMerge.saveJSON(
            ["permissions": ["defaultMode": "auto"],
             "hooks": ["Notification": []],
             "env": ["FOO": "bar"],
             "statusLine": ["command": "node /stale/origin/statusline.js"]],
            at: wsDir.appendingPathComponent("settings.json"))

        AccountMigration.consolidateClaudeAccountSettings(homeURL: home)

        let result = try #require(ClaudeJsonMerge.loadJSON(at: accountSettings))
        #expect(result["permissions"] != nil)            // gained from workspace
        #expect(result["hooks"] != nil)                  // gained from workspace
        #expect(result["env"] != nil)                    // gained from workspace
        #expect((result["theme"] as? String) == "dark")  // account preserved
        let sl = result["statusLine"] as? [String: Any]
        #expect((sl?["command"] as? String)?.contains(accountDir.path) == true) // account's statusLine kept
    }

    @Test("originAccountClaudeDir resolves the origin-pinned account dir")
    func originDirResolution() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("orrery-origindir-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let acctStore = AccountStore(homeURL: home)
        let envStore = EnvironmentStore(homeURL: home)

        // No origin claude pin yet → nil.
        #expect(AccountMigration.originAccountClaudeDir(homeURL: home) == nil)

        let acct = Account(tool: .claude, displayName: "origin")
        try acctStore.save(acct)
        var origin = envStore.loadOriginWorkspace()
        origin.setAccount(acct.id, for: .claude)
        try envStore.saveOriginWorkspace(origin)

        let resolved = AccountMigration.originAccountClaudeDir(homeURL: home)
        #expect(resolved?.path == acctStore.accountDir(id: acct.id, tool: .claude).path)
    }

    /// Build a temp home with an origin-pinned claude account and the workspace
    /// claude dir present. Returns (home, originAccountDir, workspaceClaudeDir).
    private func makeOriginHome() throws -> (URL, URL, URL) {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("orrery-repoint-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let acctStore = AccountStore(homeURL: home)
        let envStore = EnvironmentStore(homeURL: home)

        let acct = Account(tool: .claude, displayName: "origin")
        try acctStore.save(acct)
        var origin = envStore.loadOriginWorkspace()
        origin.setAccount(acct.id, for: .claude)
        try envStore.saveOriginWorkspace(origin)

        let workspaceClaude = envStore.originConfigDir(tool: .claude)
        try fm.createDirectory(at: workspaceClaude, withIntermediateDirectories: true)
        return (home, acctStore.accountDir(id: acct.id, tool: .claude), workspaceClaude)
    }

    @Test("repoint: takeover symlink (→ workspace) is repointed to the origin account dir")
    func repointHappyPath() throws {
        let fm = FileManager.default
        let (home, originAccountDir, workspaceClaude) = try makeOriginHome()
        defer { try? fm.removeItem(at: home) }

        let link = home.appendingPathComponent("fake-dot-claude")
        try fm.createSymbolicLink(at: link, withDestinationURL: workspaceClaude)

        AccountMigration.repointClaudeDirSymlink(link: link, homeURL: home)

        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == originAccountDir.path)
    }

    @Test("repoint: a foreign symlink target is left untouched")
    func repointLeavesForeign() throws {
        let fm = FileManager.default
        let (home, _, _) = try makeOriginHome()
        defer { try? fm.removeItem(at: home) }

        let foreign = home.appendingPathComponent("somewhere-else")
        try fm.createDirectory(at: foreign, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("fake-dot-claude")
        try fm.createSymbolicLink(at: link, withDestinationURL: foreign)

        AccountMigration.repointClaudeDirSymlink(link: link, homeURL: home)

        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == foreign.path) // unchanged
    }

    @Test("repoint: a real directory (not a symlink) is never clobbered")
    func repointLeavesRealDir() throws {
        let fm = FileManager.default
        let (home, _, _) = try makeOriginHome()
        defer { try? fm.removeItem(at: home) }

        let link = home.appendingPathComponent("fake-dot-claude")
        try fm.createDirectory(at: link, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: link.appendingPathComponent("marker"))

        AccountMigration.repointClaudeDirSymlink(link: link, homeURL: home)

        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: link.path, isDirectory: &isDir) && isDir.boolValue) // still a dir
        #expect(fm.fileExists(atPath: link.appendingPathComponent("marker").path))         // contents intact
    }

    @Test("consolidate is a no-op when the workspace has no settings.json")
    func consolidateNoWorkspaceSettings() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("orrery-consol-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let acctStore = AccountStore(homeURL: home)
        let acct = Account(tool: .claude, displayName: "personal")
        try acctStore.save(acct)
        let accountSettings = acctStore.accountDir(id: acct.id, tool: .claude)
            .appendingPathComponent("settings.json")
        try ClaudeJsonMerge.saveJSON(["theme": "dark"], at: accountSettings)

        AccountMigration.consolidateClaudeAccountSettings(homeURL: home)

        let result = try #require(ClaudeJsonMerge.loadJSON(at: accountSettings))
        #expect((result["theme"] as? String) == "dark")   // untouched
        #expect(result.count == 1)
    }

    // MARK: - Phase D: origin-pin repair

    @Test("repairOriginPins pins the 'origin' account per tool when the workspace has none")
    func repairPinsOrigin() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("orrery-pinrepair-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let acctStore = AccountStore(homeURL: home)
        let envStore = EnvironmentStore(homeURL: home)

        let claudeOrigin = Account(tool: .claude, displayName: "origin")
        let codexOrigin = Account(tool: .codex, displayName: "origin")
        try acctStore.save(claudeOrigin)
        try acctStore.save(codexOrigin)

        // No origin workspace.json yet → no pins (the 3.0.4-damaged state).
        #expect(envStore.loadOriginWorkspace().account(for: .claude) == nil)

        AccountMigration.repairOriginPins(homeURL: home)

        let origin = envStore.loadOriginWorkspace()
        #expect(origin.account(for: .claude) == claudeOrigin.id)
        #expect(origin.account(for: .codex) == codexOrigin.id)
    }

    @Test("repairOriginPins leaves an already-pinned tool untouched")
    func repairKeepsExistingPin() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("orrery-pinrepair2-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let acctStore = AccountStore(homeURL: home)
        let envStore = EnvironmentStore(homeURL: home)

        let existing = Account(tool: .claude, displayName: "myaccount")
        let originAcct = Account(tool: .claude, displayName: "origin")
        try acctStore.save(existing)
        try acctStore.save(originAcct)

        var ws = envStore.loadOriginWorkspace()
        ws.setAccount(existing.id, for: .claude)
        try envStore.saveOriginWorkspace(ws)

        AccountMigration.repairOriginPins(homeURL: home)

        // Existing pin wins; we never override a tool that is already pinned.
        #expect(envStore.loadOriginWorkspace().account(for: .claude) == existing.id)
    }

    @Test("repairOriginPins is a no-op when there is no 'origin' account")
    func repairNoOriginAccount() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("orrery-pinrepair3-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let acctStore = AccountStore(homeURL: home)
        let envStore = EnvironmentStore(homeURL: home)
        try acctStore.save(Account(tool: .claude, displayName: "personal"))

        AccountMigration.repairOriginPins(homeURL: home)

        #expect(envStore.loadOriginWorkspace().account(for: .claude) == nil)
    }
}
