import ArgumentParser
import Foundation
import Testing
@testable import OrreryCore

@Suite("CurrentExportCommand")
struct CurrentExportCommandTests {

    @Test("prints an export line for a pinned, v3.1-migrated account")
    func exportsForMigratedPin() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)
            try ClaudeAccountMigration.migrateAccount(
                acct, accountStore: acctStore, environmentStore: envStore)

            var origin = envStore.loadOriginWorkspace()
            origin.setAccount(acct.id, for: .claude)
            try envStore.saveOriginWorkspace(origin)

            let output = try captureStdout {
                var cmd = try CurrentExportCommand.parse([])
                try cmd.run()
            }

            let expectedDir = acctStore.accountDir(id: acct.id, tool: .claude).path
            #expect(output.contains("export CLAUDE_CONFIG_DIR=\"\(expectedDir)\""))
        }
    }

    @Test("prints nothing when no tool has a pin")
    func emptyWhenUnpinned() throws {
        try withIsolatedHome {
            let output = try captureStdout {
                var cmd = try CurrentExportCommand.parse([])
                try cmd.run()
            }
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test("skips a tool whose account isn't in v3.1 layout")
    func skipsUnmigratedPin() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            // Save the account but never migrate it — no symlinks, no identity.
            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)

            var origin = envStore.loadOriginWorkspace()
            origin.setAccount(acct.id, for: .claude)
            try envStore.saveOriginWorkspace(origin)

            let output = try captureStdout {
                var cmd = try CurrentExportCommand.parse([])
                try cmd.run()
            }
            #expect(!output.contains("CLAUDE_CONFIG_DIR"))
        }
    }

    @Test("skips a tool whose export var is already set in this shell")
    func skipsAlreadySetVar() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)
            try ClaudeAccountMigration.migrateAccount(
                acct, accountStore: acctStore, environmentStore: envStore)

            var origin = envStore.loadOriginWorkspace()
            origin.setAccount(acct.id, for: .claude)
            try envStore.saveOriginWorkspace(origin)

            setenv("CLAUDE_CONFIG_DIR", "/some/explicit/override", 1)
            defer { unsetenv("CLAUDE_CONFIG_DIR") }

            let output = try captureStdout {
                var cmd = try CurrentExportCommand.parse([])
                try cmd.run()
            }
            #expect(!output.contains("CLAUDE_CONFIG_DIR"))
        }
    }
}
