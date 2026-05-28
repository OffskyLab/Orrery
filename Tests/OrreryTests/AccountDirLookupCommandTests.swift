import ArgumentParser
import Foundation
import Testing
@testable import OrreryCore

@Suite("AccountDirLookupCommand")
struct AccountDirLookupCommandTests {

    @Test("prints account dir path for v3.1-migrated account")
    func printsDirForMigrated() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            var acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)
            try ClaudeAccountMigration.migrateAccount(
                acct, accountStore: acctStore, environmentStore: envStore)

            let dir = try captureStdout {
                var cmd = try AccountDirLookupCommand.parse(["alice"])
                try cmd.run()
            }.trimmingCharacters(in: .whitespacesAndNewlines)

            let expected = acctStore.accountDir(id: acct.id, tool: .claude).path
            #expect(dir == expected)
        }
    }

    @Test("throws ValidationError when account is not migrated to v3.1")
    func throwsForUnmigrated() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            var acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)
            // No migration — no symlinks, no identity file.

            var cmd = try AccountDirLookupCommand.parse(["alice"])
            #expect(throws: ValidationError.self) {
                try cmd.run()
            }
        }
    }

    @Test("throws ValidationError when account does not exist")
    func throwsForUnknown() throws {
        try withIsolatedHome {
            var cmd = try AccountDirLookupCommand.parse(["no-such-acct"])
            #expect(throws: ValidationError.self) {
                try cmd.run()
            }
        }
    }
}

// captureStdout is defined in AccountCommandsTests.swift (module-level helper).
