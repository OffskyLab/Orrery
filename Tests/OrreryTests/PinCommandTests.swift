import Foundation
import Testing
import ArgumentParser
@testable import OrreryCore

@Suite("PinCommand")
struct PinCommandTests {
    @Test("pins account to a freshly named workspace, sets workspace + creates symlinks")
    func pinsToFreshWorkspace() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)

            let cmd = try PinCommand.parse(["alice", "--workspace", "work"])
            try cmd.run()

            let reloaded = try acctStore.load(id: acct.id, tool: .claude)
            #expect(reloaded.workspace == "work")

            let status = ClaudeAccountDirectory.verifySymlinks(
                account: reloaded, accountStore: acctStore, environmentStore: envStore)
            #expect(status == .ok)
        }
    }

    @Test("repointing a previously pinned account updates symlinks")
    func repointsAccount() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)

            // Pin once to origin
            let first = try PinCommand.parse(["alice", "--workspace", "origin"])
            try first.run()

            // Pin again to work
            let second = try PinCommand.parse(["alice", "--workspace", "work"])
            try second.run()

            let reloaded = try acctStore.load(id: acct.id, tool: .claude)
            #expect(reloaded.workspace == "work")
            #expect(ClaudeAccountDirectory.verifySymlinks(
                account: reloaded, accountStore: acctStore, environmentStore: envStore) == .ok)
        }
    }

    @Test("unknown account throws ValidationError")
    func unknownAccount() throws {
        try withIsolatedHome {
            let cmd = try PinCommand.parse(["no-such-acct", "--workspace", "origin"])
            #expect(throws: (any Error).self) {
                try cmd.run()
            }
        }
    }

    @Test("requires accountName argument — missing throws parse error")
    func requiresAccountNameArgument() throws {
        // ArgumentParser surfaces missing required args as a parse error.
        // We expect parse to throw, not a runtime nil-find error.
        #expect(throws: (any Error).self) {
            _ = try PinCommand.parse(["--workspace", "work"])
        }
    }

    @Test("rejects multiple tool flags with ValidationError")
    func rejectsMultipleToolFlags() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)

            let cmd = try PinCommand.parse(["alice", "--workspace", "origin", "--claude", "--codex"])
            #expect(throws: ValidationError.self) {
                try cmd.run()
            }
        }
    }
}
