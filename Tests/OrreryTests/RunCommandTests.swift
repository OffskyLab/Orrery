import Testing
import Foundation
@testable import OrreryCore

// MARK: - Isolation helpers (mirrored from AccountCommandsTests)

private func makeRunCmdTempHome() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-run-cmd-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

/// Run body with a fresh isolated ORRERY_HOME directory, cleaning up afterwards.
private func withIsolatedHome(_ body: () throws -> Void) throws {
    let tmpDir = try makeRunCmdTempHome()
    let saved = ProcessInfo.processInfo.environment["ORRERY_HOME"]
    setenv("ORRERY_HOME", tmpDir.path, 1)
    defer {
        if let saved { setenv("ORRERY_HOME", saved, 1) } else { unsetenv("ORRERY_HOME") }
        try? FileManager.default.removeItem(at: tmpDir)
    }
    try body()
}

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

            // Create an OrreryEnvironment and pin the account
            var env = OrreryEnvironment(name: "work")
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
            var env = OrreryEnvironment(name: "work")
            env.setAccount("ghost-id", for: .codex)
            try envStore.save(env)

            // prepareMaterialize must throw because the account load fails
            #expect(throws: (any Error).self) {
                try RunCommand.prepareMaterialize(tool: .codex, envName: "work")
            }
        }
    }
}
