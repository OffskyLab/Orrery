import Testing
import Foundation
@testable import OrreryCore

// MARK: - RunCommand.prepareMaterialize tests

@Suite("RunCommand.prepareMaterialize", .serialized)
struct RunCommandPrepareMaterializeTests {

    @Test("materializeNamedEnvSymlinksCodexAuth: symlink is created in env config dir")
    func materializeNamedEnvSymlinksCodexAuth() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            // Create a codex account
            let acct = Account(tool: .codex, displayName: "work-codex")
            try acctStore.save(acct)

            // Write a credential file into the account dir
            let accountDir = acctStore.accountDir(id: acct.id, tool: .codex)
            let credsURL = accountDir.appendingPathComponent("auth.json")
            try "{}".data(using: .utf8)!.write(to: credsURL)

            // Create an Workspace and pin the account
            var env = Workspace(name: "work")
            env.setAccount(acct.id, for: .codex)
            try envStore.save(env)

            // Call prepareMaterialize
            try RunCommand.prepareMaterialize(tool: .codex, envName: "work")

            // Assert the symlink was created in the env config dir
            let expectedLink = envStore.toolConfigDir(tool: .codex, environment: "work")
                .appendingPathComponent("auth.json")
            let attrs = try FileManager.default.attributesOfItem(atPath: expectedLink.path)
            #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
            let dest = try FileManager.default.destinationOfSymbolicLink(atPath: expectedLink.path)
            #expect(dest == credsURL.path)
        }
    }

    @Test("noPinnedAccountIsNoOp: no account pinned, prepareMaterialize does not throw")
    func noPinnedAccountIsNoOp() throws {
        try withIsolatedHome {
            // No account pinned — prepareMaterialize should be a silent no-op
            try RunCommand.prepareMaterialize(tool: .codex, envName: nil)
            // No assertion needed beyond "it doesn't throw"
        }
    }

    @Test("materializeThrowsWhenPinnedAccountMissing: throws when pinned account is absent from store")
    func materializeThrowsWhenPinnedAccountMissing() throws {
        try withIsolatedHome {
            let envStore = EnvironmentStore.default

            // Pin a ghost account id — do NOT create the account in AccountStore
            var env = Workspace(name: "work")
            env.setAccount("ghost-id", for: .codex)
            try envStore.save(env)

            // prepareMaterialize must throw because the account load fails
            #expect(throws: (any Error).self) {
                try RunCommand.prepareMaterialize(tool: .codex, envName: "work")
            }
        }
    }

    @Test("claude: prepareMaterialize is a no-op (v3.1 shell-function managed)")
    func claudePrepareMaterializeIsNoOp() throws {
        try withIsolatedHome {
            // Even with a pinned claude account, prepareMaterialize must be a no-op.
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            let acct = Account(tool: .claude, displayName: "claude-noop")
            try acctStore.save(acct)
            var env = Workspace(name: "noop-env")
            env.setAccount(acct.id, for: .claude)
            try envStore.save(env)
            // Must not throw and must not touch any files beyond what's already there.
            try RunCommand.prepareMaterialize(tool: .claude, envName: "noop-env")
        }
    }

    // NOTE: The origin happy-path (materializing a real credential) is intentionally
    // NOT tested here. The origin target is the user's real environment (~/.codex,
    // real Keychain entries) and must never be mutated or read by automated tests.

    @Test("origin: throws when origin pins a missing account")
    func originPinnedAccountMissingThrows() throws {
        try withIsolatedHome {
            var origin = EnvironmentStore.default.loadOriginWorkspace()
            origin.setAccount("ghost-origin-id", for: .codex)
            try EnvironmentStore.default.saveOriginWorkspace(origin)

            #expect(throws: (any Error).self) {
                try RunCommand.prepareMaterialize(tool: .codex, envName: nil)
            }
        }
    }
}
