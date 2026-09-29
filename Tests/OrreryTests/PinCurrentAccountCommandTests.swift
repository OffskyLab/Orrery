import ArgumentParser
import Foundation
import Testing
@testable import OrreryCore

@Suite("PinCurrentAccountCommand")
struct PinCurrentAccountCommandTests {

    @Test("persists the account as the origin-wide current pin for its tool")
    func persistsToOrigin() async throws {
        try await withIsolatedHome {
            let acctStore = AccountStore.default
            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)

            var cmd = try PinCurrentAccountCommand.parse(["alice"])
            try await cmd.run()

            let origin = EnvironmentStore.default.loadOriginWorkspace()
            #expect(origin.account(for: .claude) == acct.id)
        }
    }

    @Test("respects the --codex flag")
    func respectsToolFlag() async throws {
        try await withIsolatedHome {
            let acctStore = AccountStore.default
            let acct = Account(tool: .codex, displayName: "bob")
            try acctStore.save(acct)

            var cmd = try PinCurrentAccountCommand.parse(["bob", "--codex"])
            try await cmd.run()

            let origin = EnvironmentStore.default.loadOriginWorkspace()
            #expect(origin.account(for: .codex) == acct.id)
            #expect(origin.account(for: .claude) == nil)
        }
    }

    @Test("throws ValidationError for an unknown account")
    func throwsForUnknown() async throws {
        try await withIsolatedHome {
            var cmd = try PinCurrentAccountCommand.parse(["no-such-account"])
            await #expect(throws: ValidationError.self) {
                try await cmd.run()
            }
        }
    }

    @Test("rejects multiple tool flags")
    func rejectsMultipleFlags() async throws {
        try await withIsolatedHome {
            var cmd = try PinCurrentAccountCommand.parse(["alice", "--claude", "--codex"])
            await #expect(throws: ValidationError.self) {
                try await cmd.run()
            }
        }
    }

    @Test("re-pinning overwrites the previous pin for the same tool")
    func overwritesPreviousPin() async throws {
        try await withIsolatedHome {
            let acctStore = AccountStore.default
            let alice = Account(tool: .claude, displayName: "alice")
            let carol = Account(tool: .claude, displayName: "carol")
            try acctStore.save(alice)
            try acctStore.save(carol)

            var first = try PinCurrentAccountCommand.parse(["alice"])
            try await first.run()
            var second = try PinCurrentAccountCommand.parse(["carol"])
            try await second.run()

            let origin = EnvironmentStore.default.loadOriginWorkspace()
            #expect(origin.account(for: .claude) == carol.id)
        }
    }
}
