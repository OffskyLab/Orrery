import Foundation
import Testing
@testable import OrreryCore

@Suite("ClaudeAccountMigration.migrateAccount")
struct ClaudeAccountMigrationTests {

    @Test("migrating an account creates per-account dir layout (idempotent)")
    func createsLayoutIdempotent() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            var acct = Account(tool: .claude, displayName: "alice", email: "alice@example.com")
            try acctStore.save(acct)

            // First call: creates layout
            try ClaudeAccountMigration.migrateAccount(
                acct, accountStore: acctStore, environmentStore: envStore)
            #expect(ClaudeAccountDirectory.verifySymlinks(
                account: acct, accountStore: acctStore, environmentStore: envStore) == .ok)

            // Second call: still .ok, no errors thrown
            try ClaudeAccountMigration.migrateAccount(
                acct, accountStore: acctStore, environmentStore: envStore)
            #expect(ClaudeAccountDirectory.verifySymlinks(
                account: acct, accountStore: acctStore, environmentStore: envStore) == .ok)
        }
    }

    @Test("migration seeds claude-identity.json with oauthAccount from Account.email")
    func seedsIdentityFromEmail() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            var acct = Account(tool: .claude, displayName: "alice", email: "alice@example.com")
            try acctStore.save(acct)

            try ClaudeAccountMigration.migrateAccount(
                acct, accountStore: acctStore, environmentStore: envStore)

            let identityURL = ClaudeJsonMerge.identityFileURL(
                accountDir: acctStore.accountDir(id: acct.id, tool: .claude))
            let identity = ClaudeJsonMerge.loadJSON(at: identityURL)
            #expect(identity != nil)
            let oauthAccount = identity?["oauthAccount"] as? [String: Any]
            #expect(oauthAccount?["emailAddress"] as? String == "alice@example.com")
        }
    }

    @Test("migration with no email writes empty identity")
    func noEmailNoSnapshotEmptyIdentity() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            let acct = Account(tool: .claude, displayName: "alice")  // no email
            try acctStore.save(acct)

            try ClaudeAccountMigration.migrateAccount(
                acct, accountStore: acctStore, environmentStore: envStore)

            let identity = ClaudeJsonMerge.loadJSON(
                at: ClaudeJsonMerge.identityFileURL(
                    accountDir: acctStore.accountDir(id: acct.id, tool: .claude)))
            #expect(identity != nil)
            #expect(identity?.isEmpty == true)
        }
    }

    @Test("migration leaves existing v3.0.4 credential/metadata untouched (additive)")
    func leavesV304StateAlone() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            let acct = Account(tool: .claude, displayName: "alice", email: "alice@example.com")
            try acctStore.save(acct)

            // Pre-seed: metadata.json (already exists from save), a fake credential file.
            let poolDir = acctStore.accountDir(id: acct.id, tool: .claude)
            try FileManager.default.createDirectory(at: poolDir, withIntermediateDirectories: true)
            let credURL = poolDir.appendingPathComponent(".credentials.json")
            let credContent = Data(#"{"claudeAiOauth":{"accessToken":"sk-fake"}}"#.utf8)
            try credContent.write(to: credURL)

            try ClaudeAccountMigration.migrateAccount(
                acct, accountStore: acctStore, environmentStore: envStore)

            // v3.0.4 credential file still there, byte-for-byte unchanged.
            #expect(FileManager.default.fileExists(atPath: credURL.path))
            #expect(try Data(contentsOf: credURL) == credContent)
        }
    }
}
