import Foundation
import Testing
@testable import OrreryCore

@Suite("MigrateToV31Command")
struct MigrateToV31CommandTests {

    @Test("migrates all claude pool accounts, idempotent on second run")
    func migratesAllIdempotent() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            let alice = Account(tool: .claude, displayName: "alice", email: "alice@x.com")
            let bob = Account(tool: .claude, displayName: "bob", email: "bob@x.com")
            try acctStore.save(alice)
            try acctStore.save(bob)

            var cmd = try MigrateToV31Command.parse([])
            try cmd.run()

            // Both accounts have the v3.1 layout now.
            #expect(ClaudeAccountDirectory.verifySymlinks(
                account: alice, accountStore: acctStore, environmentStore: envStore) == .ok)
            #expect(ClaudeAccountDirectory.verifySymlinks(
                account: bob, accountStore: acctStore, environmentStore: envStore) == .ok)

            // Both have claude-identity.json seeded with their email.
            for acct in [alice, bob] {
                let identity = ClaudeJsonMerge.loadJSON(
                    at: ClaudeJsonMerge.identityFileURL(
                        accountDir: acctStore.accountDir(id: acct.id, tool: .claude)))
                let oauth = identity?["oauthAccount"] as? [String: Any]
                #expect(oauth?["emailAddress"] as? String == acct.email)
            }

            // Second run is a no-op (does not throw, does not clobber identity).
            try cmd.run()
            #expect(ClaudeAccountDirectory.verifySymlinks(
                account: alice, accountStore: acctStore, environmentStore: envStore) == .ok)
        }
    }

    @Test("non-claude accounts are skipped")
    func skipsNonClaude() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default

            let codex = Account(tool: .codex, displayName: "codex-alice", email: "c@x.com")
            try acctStore.save(codex)

            var cmd = try MigrateToV31Command.parse([])
            try cmd.run()

            // No claude symlinks for the codex slot.
            let codexDir = acctStore.accountDir(id: codex.id, tool: .codex)
            #expect(!FileManager.default.fileExists(
                atPath: codexDir.appendingPathComponent("projects").path))
        }
    }

    @Test("empty pool — runs without error")
    func emptyPoolNoError() throws {
        try withIsolatedHome {
            var cmd = try MigrateToV31Command.parse([])
            #expect(throws: Never.self) {
                try cmd.run()
            }
        }
    }
}
