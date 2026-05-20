import Testing
import Foundation
@testable import OrreryCore

/// Tests for the v2→v3 account-pool migration.
///
/// `AccountMigration.runIfNeeded(homeURL:)` takes the home URL directly, so these
/// tests do NOT need the global `ORRERY_HOME` lock — each test owns its own temp dir.
@Suite("AccountMigration")
struct AccountMigrationTests {

    /// Makes a fresh temp dir and a `defer`-friendly cleanup that also sweeps any
    /// `.orrery-backup-*` siblings the migration created next to it.
    private func makeTempHome() -> (home: URL, cleanup: () -> Void) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-migration-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let home = parent.appendingPathComponent(".orrery")
        let cleanup: () -> Void = {
            // Removing the parent removes both `.orrery` and any backup siblings.
            try? FileManager.default.removeItem(at: parent)
        }
        return (home, cleanup)
    }

    @Test("skips when home does not exist")
    func skipsWhenNoHome() throws {
        let (home, cleanup) = makeTempHome()
        defer { cleanup() }
        // home itself was never created.
        #expect(!FileManager.default.fileExists(atPath: home.path))

        try AccountMigration.runIfNeeded(homeURL: home)

        // Nothing created — no flag, no home.
        #expect(!FileManager.default.fileExists(atPath: home.path))
    }

    @Test("fresh install writes the flag without scanning")
    func freshInstallWritesFlag() throws {
        let (home, cleanup) = makeTempHome()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        try AccountMigration.runIfNeeded(homeURL: home)

        let flag = home.appendingPathComponent(AccountMigration.flagFileName)
        #expect(FileManager.default.fileExists(atPath: flag.path))
    }

    @Test("does not rerun when the flag already exists")
    func doesNotRerunWhenFlagExists() throws {
        let (home, cleanup) = makeTempHome()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        // Pre-create the flag.
        let flag = home.appendingPathComponent(AccountMigration.flagFileName)
        try Data("v3\n".utf8).write(to: flag)

        // Build a real env with a codex credential — would normally be migrated.
        let envStore = EnvironmentStore(homeURL: home)
        let env = OrreryEnvironment(name: "work", tools: [.codex])
        try envStore.save(env)
        let codexDir = envStore.toolConfigDir(tool: .codex, environment: "work")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try Data(#"{"token":"abc"}"#.utf8)
            .write(to: codexDir.appendingPathComponent("auth.json"))

        try AccountMigration.runIfNeeded(homeURL: home)

        // Flag already present → migration is a no-op: no pool account created.
        let acctStore = AccountStore(homeURL: home)
        #expect(try acctStore.list(tool: .codex).isEmpty)
        // And the env was not re-pinned.
        let reloaded = try envStore.load(named: "work")
        #expect(reloaded.account(for: .codex) == nil)
    }

    @Test("extracts a codex credential into the pool, non-destructively")
    func extractsCodexCredentialIntoPool() throws {
        let (home, cleanup) = makeTempHome()
        defer { cleanup() }

        let envStore = EnvironmentStore(homeURL: home)
        let env = OrreryEnvironment(name: "work", tools: [.codex])
        try envStore.save(env)

        let codexDir = envStore.toolConfigDir(tool: .codex, environment: "work")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let authFile = codexDir.appendingPathComponent("auth.json")
        let credentialContent = Data(#"{"token":"codex-secret-123"}"#.utf8)
        try credentialContent.write(to: authFile)

        try AccountMigration.runIfNeeded(homeURL: home)

        let acctStore = AccountStore(homeURL: home)

        // (a) exactly one codex pool account.
        let accounts = try acctStore.list(tool: .codex)
        #expect(accounts.count == 1)
        let account = try #require(accounts.first)

        // (b) the env is pinned to that account.
        let reloaded = try envStore.load(named: "work")
        #expect(reloaded.account(for: .codex) == account.id)

        // (c) the original credential file still exists (non-destructive).
        #expect(FileManager.default.fileExists(atPath: authFile.path))

        // And the credential was actually copied into the pool with the right content.
        let pooled = acctStore.accountDir(id: account.id, tool: .codex)
            .appendingPathComponent("auth.json")
        #expect(FileManager.default.fileExists(atPath: pooled.path))
        #expect(try Data(contentsOf: pooled) == credentialContent)
    }

    @Test("dedups a credential shared by two envs into one account")
    func dedupSharedCredential() throws {
        let (home, cleanup) = makeTempHome()
        defer { cleanup() }

        let envStore = EnvironmentStore(homeURL: home)
        let shared = Data(#"{"token":"shared-codex-token"}"#.utf8)

        for name in ["alpha", "beta"] {
            let env = OrreryEnvironment(name: name, tools: [.codex])
            try envStore.save(env)
            let codexDir = envStore.toolConfigDir(tool: .codex, environment: name)
            try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
            try shared.write(to: codexDir.appendingPathComponent("auth.json"))
        }

        try AccountMigration.runIfNeeded(homeURL: home)

        let acctStore = AccountStore(homeURL: home)
        // Identical content → exactly ONE pool account.
        let accounts = try acctStore.list(tool: .codex)
        #expect(accounts.count == 1)
        let id = try #require(accounts.first?.id)

        // Both envs point at the same account.
        #expect(try envStore.load(named: "alpha").account(for: .codex) == id)
        #expect(try envStore.load(named: "beta").account(for: .codex) == id)
    }

    @Test("takes a backup before migrating a non-empty home")
    func takesBackupBeforeMigrating() throws {
        let (home, cleanup) = makeTempHome()
        defer { cleanup() }

        let envStore = EnvironmentStore(homeURL: home)
        let env = OrreryEnvironment(name: "work", tools: [.codex])
        try envStore.save(env)
        let codexDir = envStore.toolConfigDir(tool: .codex, environment: "work")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try Data(#"{"token":"x"}"#.utf8)
            .write(to: codexDir.appendingPathComponent("auth.json"))

        try AccountMigration.runIfNeeded(homeURL: home)

        // A `.orrery-backup-*` directory exists as a sibling of home.
        let parent = home.deletingLastPathComponent()
        let siblings = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        #expect(siblings.contains { $0.hasPrefix(".orrery-backup-") })
    }
}
