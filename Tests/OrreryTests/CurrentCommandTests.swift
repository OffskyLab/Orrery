import ArgumentParser
import Foundation
import Testing
@testable import OrreryCore

@Suite("CurrentCommand", .serialized)
struct CurrentCommandTests {

    @Test("shows all three tools as unpinned when nothing is pinned")
    func allUnpinned() throws {
        try withIsolatedHome {
            let output = try captureStdout {
                var cmd = try CurrentCommand.parse([])
                try cmd.run()
            }
            #expect(output.contains(L10n.Account.showRowUnpinned("claude")))
            #expect(output.contains(L10n.Account.showRowUnpinned("codex")))
            #expect(output.contains(L10n.Account.showRowUnpinned("gemini")))
        }
    }

    @Test("shows the pinned account's display name for its tool")
    func showsPinnedAccount() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)

            var pin = try PinCurrentAccountCommand.parse(["alice"])
            try pin.run()

            let output = try captureStdout {
                var cmd = try CurrentCommand.parse([])
                try cmd.run()
            }
            #expect(output.contains(L10n.Account.showRowHeader("claude", "alice")))
            _ = envStore
        }
    }

    @Test("filters to a single tool when its flag is given")
    func filtersByFlag() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)
            var pin = try PinCurrentAccountCommand.parse(["alice"])
            try pin.run()

            let output = try captureStdout {
                var cmd = try CurrentCommand.parse(["--claude"])
                try cmd.run()
            }
            #expect(output.contains("claude:"))
            #expect(!output.contains("codex:"))
            #expect(!output.contains("gemini:"))
        }
    }

    @Test("rejects multiple tool flags")
    func rejectsMultipleFlags() throws {
        try withIsolatedHome {
            var cmd = try CurrentCommand.parse(["--claude", "--codex"])
            #expect(throws: ValidationError.self) {
                try cmd.run()
            }
        }
    }
}
