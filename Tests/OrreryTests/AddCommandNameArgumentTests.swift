import ArgumentParser
import Foundation
import Testing
@testable import OrreryCore

/// `orrery add` took its name as `--name <name>` while `orrery remove` took it
/// positionally, so the two halves of the same workflow read differently:
///
///     orrery add --claude --name demo-1
///     orrery remove --claude demo-1
///
/// `add` now matches `remove`. `--name` is gone rather than deprecated: the
/// releases that carried it were never announced, so there is no install base
/// to keep limping along, and a hidden alias would just preserve the ambiguity
/// this change exists to remove.
@Suite("orrery add — positional name")
struct AddCommandNameArgumentTests {

    @Test("takes the name positionally, matching `orrery remove`")
    func positionalName() throws {
        try withIsolatedHome {
            try AddCommand.parse(["--claude", "positional-test", "--skip-login"]).run()
            let accounts = try AccountStore.default.list(tool: .claude)
            #expect(accounts.contains { $0.displayName == "positional-test" })
        }
    }

    @Test("positional name works for every tool flag")
    func positionalNamePerTool() throws {
        try withIsolatedHome {
            try AddCommand.parse(["--codex", "codex-positional", "--skip-login"]).run()
            try AddCommand.parse(["--gemini", "gemini-positional", "--skip-login"]).run()

            #expect(try AccountStore.default.list(tool: .codex)
                .contains { $0.displayName == "codex-positional" })
            #expect(try AccountStore.default.list(tool: .gemini)
                .contains { $0.displayName == "gemini-positional" })
        }
    }

    @Test("positional name works with no tool flag (defaults to claude)")
    func positionalNameDefaultsToClaude() throws {
        try withIsolatedHome {
            try AddCommand.parse(["default-tool-positional", "--skip-login"]).run()
            #expect(try AccountStore.default.list(tool: .claude)
                .contains { $0.displayName == "default-tool-positional" })
        }
    }

    @Test("--name is rejected outright, not silently accepted as an alias")
    func nameOptionIsGone() {
        #expect(throws: (any Error).self) {
            try AddCommand.parse(["--claude", "--name", "gone", "--skip-login"])
        }
    }

    /// The claude add path does not run `AddCommand` at all — the shell wrapper
    /// routes it through `_account-add-prepare` so the login can happen inside a
    /// real interactive `claude`. That command parses the same user-typed
    /// arguments, so it has to accept the positional too, or `orrery add
    /// --claude demo-1` breaks for the one tool it matters most for.
    @Test("_account-add-prepare accepts the positional name as well")
    func prepareCommandAcceptsPositionalName() throws {
        let cmd = try AccountAddPrepareCommand.parse(["--claude", "prepare-positional"])
        #expect(cmd.name == "prepare-positional")
    }

    @Test("_account-add-prepare rejects --name too, so both entry points agree")
    func prepareCommandRejectsNameOption() {
        #expect(throws: (any Error).self) {
            try AccountAddPrepareCommand.parse(["--claude", "--name", "gone"])
        }
    }
}
