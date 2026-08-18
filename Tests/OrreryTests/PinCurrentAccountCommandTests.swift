import ArgumentParser
import Foundation
import Testing
@testable import OrreryCore

@Suite("PinCurrentAccountCommand")
struct PinCurrentAccountCommandTests {

    @Test("persists the account as the origin-wide current pin for its tool")
    func persistsToOrigin() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)

            var cmd = try PinCurrentAccountCommand.parse(["alice"])
            try cmd.run()

            let origin = EnvironmentStore.default.loadOriginWorkspace()
            #expect(origin.account(for: .claude) == acct.id)
        }
    }

    @Test("respects the --codex flag")
    func respectsToolFlag() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let acct = Account(tool: .codex, displayName: "bob")
            try acctStore.save(acct)

            var cmd = try PinCurrentAccountCommand.parse(["bob", "--codex"])
            try cmd.run()

            let origin = EnvironmentStore.default.loadOriginWorkspace()
            #expect(origin.account(for: .codex) == acct.id)
            #expect(origin.account(for: .claude) == nil)
        }
    }

    @Test("throws ValidationError for an unknown account")
    func throwsForUnknown() throws {
        try withIsolatedHome {
            var cmd = try PinCurrentAccountCommand.parse(["no-such-account"])
            #expect(throws: ValidationError.self) {
                try cmd.run()
            }
        }
    }

    @Test("rejects multiple tool flags")
    func rejectsMultipleFlags() throws {
        try withIsolatedHome {
            var cmd = try PinCurrentAccountCommand.parse(["alice", "--claude", "--codex"])
            #expect(throws: ValidationError.self) {
                try cmd.run()
            }
        }
    }

    @Test("re-pinning overwrites the previous pin for the same tool")
    func overwritesPreviousPin() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let alice = Account(tool: .claude, displayName: "alice")
            let carol = Account(tool: .claude, displayName: "carol")
            try acctStore.save(alice)
            try acctStore.save(carol)

            var first = try PinCurrentAccountCommand.parse(["alice"])
            try first.run()
            var second = try PinCurrentAccountCommand.parse(["carol"])
            try second.run()

            let origin = EnvironmentStore.default.loadOriginWorkspace()
            #expect(origin.account(for: .claude) == carol.id)
        }
    }
}
