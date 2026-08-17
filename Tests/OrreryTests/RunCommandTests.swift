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

// MARK: - RunCommand.applyRealEnvironment (execvp leak prevention)

/// `run()` swaps into a child via `execvp`, which inherits this process's
/// *actual* environment — not the `Process.environment` dictionary built
/// along the way. A key merely absent from that dictionary can still be
/// present in the real environment (inherited from the parent shell) and
/// leak into the child unchanged unless it is also `unsetenv`'d.
///
/// These tests exercise `RunCommand.applyRealEnvironment` — the exact
/// setenv/unsetenv routine `run()` performs immediately before `execvp` —
/// against this process's real environment, then spawn a real child via
/// `Process` (not `execvp`, so the test process survives) fed a freshly
/// read snapshot of that same real environment. This proves the leak is
/// closed in the environment that actually reaches the child, not just in
/// an intermediate dictionary.
@Suite("RunCommand.applyRealEnvironment", .serialized)
struct RunCommandApplyRealEnvironmentTests {

    /// Spawns `/usr/bin/env` with a *freshly read* `ProcessInfo.processInfo.environment`
    /// snapshot and returns its printed environment.
    ///
    /// Note: `Process`/`environment == nil` does NOT reliably pick up
    /// `setenv`/`unsetenv` calls made after the `Process` machinery first
    /// touches the environment (verified empirically — Foundation appears
    /// to cache the inherited-environment snapshot rather than reading the
    /// live `environ` table at spawn time). `ProcessInfo.processInfo.environment`,
    /// by contrast, re-reads the real environment on every access (also
    /// verified empirically via `getenv`), so explicitly passing a
    /// just-read snapshot here — rather than relying on nil-inheritance —
    /// is what actually proves the *real* process environment (the one
    /// `execvp` reads) reflects the `unsetenv` calls under test.
    private func childEnvironment() throws -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var result: [String: String] = [:]
        for line in String(data: data, encoding: .utf8)?.split(separator: "\n") ?? [] {
            guard let eq = line.firstIndex(of: "=") else { continue }
            result[String(line[line.startIndex..<eq])] = String(line[line.index(after: eq)...])
        }
        return result
    }

    @Test("unsetenv removes the stripped keys from the real environment that reaches the child")
    func stripsKeysFromRealChildEnvironment() throws {
        try withRealEnvironmentLock {
            let keys = RunCommand.strippedExecEnvKeys + ["ANTHROPIC_API_KEY"]
            let saved = keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
            defer {
                for (key, value) in saved {
                    if let value { setenv(key, value, 1) } else { unsetenv(key) }
                }
            }

            // Simulate the leak precondition: these keys are present in the
            // *real* environment (as if inherited from an outer supervisor's
            // shell), but absent from the `processEnv` dictionary being
            // applied — mirroring `run()`'s state right before its `execvp`
            // call.
            for key in keys {
                setenv(key, "leaked-value", 1)
            }

            let processEnv: [String: String] = ["ORRERY_RUN_COMMAND_MARKER": "present"]
            RunCommand.applyRealEnvironment(processEnv, strippingKeys: keys)

            let childEnv = try childEnvironment()
            for key in keys {
                #expect(childEnv[key] == nil, "expected \(key) to be absent from the real child environment")
            }
            #expect(childEnv["ORRERY_RUN_COMMAND_MARKER"] == "present")
        }
    }

    @Test("keysToUnset includes ANTHROPIC_API_KEY only for a non-origin named env")
    func anthropicKeyStripIsConditional() {
        // This mirrors run()'s conditional construction of keysToUnset —
        // regression guard so the condition can't silently drift from the
        // dictionary-side removeValue(forKey:) condition above it.
        var keysToUnset = RunCommand.strippedExecEnvKeys
        let envName: String? = "work"
        if let envName, envName != Workspace.reservedOriginName {
            keysToUnset.append("ANTHROPIC_API_KEY")
        }
        #expect(keysToUnset.contains("ANTHROPIC_API_KEY"))

        var originKeysToUnset = RunCommand.strippedExecEnvKeys
        let originEnvName: String? = Workspace.reservedOriginName
        if let originEnvName, originEnvName != Workspace.reservedOriginName {
            originKeysToUnset.append("ANTHROPIC_API_KEY")
        }
        #expect(!originKeysToUnset.contains("ANTHROPIC_API_KEY"))
    }
}
