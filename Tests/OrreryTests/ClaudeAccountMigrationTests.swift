import Foundation
import Testing
@testable import OrreryCore
import OrreryAccountKit

@Suite("ClaudeAccountMigration.migrateAccount")
struct ClaudeAccountMigrationTests {

    @Test("migrating an account creates per-account dir layout (idempotent)")
    func createsLayoutIdempotent() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            var acct = Account(tool: .claude, displayName: "alice", email: "alice@example.com")
            try acctStore.save(acct)

            let manager = try AccountDirectoryRuntime.manager(for: .claude)

            // First call: creates layout
            try ClaudeAccountMigration.migrateAccount(
                acct, accountStore: acctStore, environmentStore: envStore)
            #expect(manager.verifySymlinks(
                account: acct, accountStore: acctStore, environmentStore: envStore) == .ok)

            // Second call: still .ok, no errors thrown
            try ClaudeAccountMigration.migrateAccount(
                acct, accountStore: acctStore, environmentStore: envStore)
            #expect(manager.verifySymlinks(
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

    #if os(macOS)
    /// Regression, same schema rule as `PrepareClaudeLaunchCommand`: seeding
    /// the identity file from a stored credential must not throw away the
    /// account-identity half of `oauthAccount`. The credential blob carries
    /// tokens only; `emailAddress` is all the identity migration has, and it
    /// has to survive alongside them.
    @Test("migration keeps Account.email in oauthAccount when a credential is present")
    func seedsIdentityKeepsEmailAlongsideCredential() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            var acct = Account(tool: .claude, displayName: "alice", email: "alice@example.com")
            acct.keychainItem = ClaudeKeychain.serviceName(forOrreryAccount: acct.id)
            try acctStore.save(acct)
            defer { ClaudeKeychain.deleteKeychainItem(service: acct.keychainItem!) }

            ClaudeKeychain.storePassword(
                #"{"claudeAiOauth":{"accessToken":"tok-access","refreshToken":"tok-refresh","expiresAt":1787232311999}}"#,
                forOrreryAccount: acct.id
            )

            try ClaudeAccountMigration.migrateAccount(
                acct, accountStore: acctStore, environmentStore: envStore)

            let identityURL = ClaudeJsonMerge.identityFileURL(
                accountDir: acctStore.accountDir(id: acct.id, tool: .claude))
            let identity = ClaudeJsonMerge.loadJSON(at: identityURL)
            let oauthAccount = try #require(identity?["oauthAccount"] as? [String: Any])

            #expect(oauthAccount["emailAddress"] as? String == "alice@example.com",
                "the credential must not displace the account's identity fields")
            #expect(oauthAccount["accessToken"] as? String == "tok-access")
            #expect(oauthAccount["refreshToken"] as? String == "tok-refresh")
        }
    }
    #endif

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
