import Testing
import Foundation
import ArgumentParser
@testable import OrreryCore

// MARK: - stdout capture helper

/// Redirect stdout to a temp file, run body, restore stdout, and return output.
/// Uses a file (not a pipe) to avoid blocking when the pipe write end is still open.
/// The caller is responsible for ensuring this does not run concurrently with another
/// call (e.g. by nesting inside a .serialized suite).
func captureStdout(_ body: () throws -> Void) throws -> String {
    let tmpPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-cap-\(UUID().uuidString).txt").path
    FileManager.default.createFile(atPath: tmpPath, contents: nil)
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    let savedFD = dup(fileno(stdout))
    fflush(stdout)
    let capFD = open(tmpPath, O_WRONLY | O_TRUNC)
    precondition(capFD != -1, "captureStdout: open failed: \(String(cString: strerror(errno)))")
    dup2(capFD, fileno(stdout))
    close(capFD)
    defer {
        fflush(stdout)
        dup2(savedFD, fileno(stdout))
        close(savedFD)
    }
    try body()
    fflush(stdout)
    return (try? String(contentsOfFile: tmpPath, encoding: .utf8)) ?? ""
}

// MARK: - All account command tests
//
// Wrapped in a single .serialized parent to prevent concurrent:
//   - ORRERY_HOME setenv/unsetenv races between suites, AND
//   - captureStdout FD-1 redirection races.

@Suite("AccountCommands", .serialized)
struct AccountCommandsAllTests {

    // MARK: AccountAddCommand

    @Suite("AccountAddCommand")
    struct AccountAddTests {
        init() {}

        @Test("multiple tool flags throws ValidationError")
        func multipleToolFlags() throws {
            try withIsolatedHome {
                #expect(throws: (any Error).self) {
                    try AccountAddCommand.resolveTool(claude: true, codex: true, gemini: false)
                }
            }
        }

        @Test("defaults to claude when no tool flag is set")
        func defaultsToClaude() throws {
            try withIsolatedHome {
                let cmd = try AccountAddCommand.parse(["--name", "default-claude-test", "--skip-login"])
                try cmd.run()
                let accounts = try AccountStore.default.list(tool: .claude)
                #expect(accounts.contains { $0.displayName == "default-claude-test" })
            }
        }

        @Test("--codex flag creates a codex account")
        func codexFlag() throws {
            try withIsolatedHome {
                let cmd = try AccountAddCommand.parse(["--codex", "--name", "codex-test", "--skip-login"])
                try cmd.run()
                let accounts = try AccountStore.default.list(tool: .codex)
                #expect(accounts.contains { $0.displayName == "codex-test" })
            }
        }

        #if os(macOS)
        @Test("claude account created via add has non-nil keychainItem")
        func claudeAccountHasKeychainItem() throws {
            try withIsolatedHome {
                let tmpDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORRERY_HOME"]!)
                let cmd = try AccountAddCommand.parse(["--name", "keychain-test", "--skip-login"])
                try cmd.run()
                let store = AccountStore(homeURL: tmpDir)
                let accounts = try store.list(tool: .claude)
                guard let account = accounts.first(where: { $0.displayName == "keychain-test" }) else {
                    Issue.record("Account not found in store")
                    return
                }
                #expect(account.keychainItem != nil)
            }
        }
        #endif

        @Test("rejects a duplicate display name for the same tool")
        func rejectsDuplicateName() throws {
            try withIsolatedHome {
                try AccountAddCommand.parse(["--name", "dup", "--skip-login"]).run()
                // second add with the same name + tool must throw
                #expect(throws: ValidationError.self) {
                    try AccountAddCommand.parse(["--name", "dup", "--skip-login"]).run()
                }
                // a same-name account under a DIFFERENT tool is still allowed
                try AccountAddCommand.parse(["--codex", "--name", "dup", "--skip-login"]).run()
            }
        }
    }

    // MARK: AccountListCommand

    @Suite("AccountListCommand")
    struct AccountListTests {
        init() {}

        @Test("empty store prints listEmpty message")
        func empty() throws {
            try withIsolatedHome {
                let cmd = try AccountListCommand.parse([])
                let output = try captureStdout { try cmd.run() }
                #expect(output.contains("No accounts"))
            }
        }

        @Test("grouped by tool shows all accounts")
        func groupedByTool() throws {
            try withIsolatedHome {
                try AccountStore.default.save(Account(tool: .claude, displayName: "work"))
                try AccountStore.default.save(Account(tool: .codex, displayName: "personal"))
                let cmd = try AccountListCommand.parse([])
                let output = try captureStdout { try cmd.run() }
                #expect(output.contains("work"))
                #expect(output.contains("personal"))
                #expect(output.contains("claude"))
                #expect(output.contains("codex"))
            }
        }

        @Test("--codex filter shows only codex accounts")
        func filterByTool() throws {
            try withIsolatedHome {
                try AccountStore.default.save(Account(tool: .claude, displayName: "should-not-show"))
                try AccountStore.default.save(Account(tool: .codex, displayName: "yes-show"))
                let cmd = try AccountListCommand.parse(["--codex"])
                let output = try captureStdout { try cmd.run() }
                #expect(output.contains("yes-show"))
                #expect(!output.contains("should-not-show"))
            }
        }

        // MARK: - Info suffix tests

        @Test("codex account with email and plan stored shows both in list")
        func codexAccountWithStoredEmailAndPlan() throws {
            try withIsolatedHome {
                let store = AccountStore.default
                // Simulate what write paths (login/syncback/backfill) do: store
                // email and plan directly on the Account before saving.
                var acct = Account(tool: .codex, displayName: "work-codex")
                acct.email = "test@example.com"
                acct.plan = "free"
                try store.save(acct)

                let cmd = try AccountListCommand.parse(["--codex"])
                let output = try captureStdout { try cmd.run() }
                #expect(output.contains("work-codex"))
                #expect(output.contains("test@example.com"))
                #expect(output.contains("free"))
            }
        }

        @Test("gemini account with stored email shows email in list")
        func geminiAccountWithStoredEmail() throws {
            try withIsolatedHome {
                let store = AccountStore.default
                // Simulate what write paths do: store email directly on Account.
                var acct = Account(tool: .gemini, displayName: "gemini-personal")
                acct.email = "gemini@example.com"
                try store.save(acct)

                let cmd = try AccountListCommand.parse(["--gemini"])
                let output = try captureStdout { try cmd.run() }
                #expect(output.contains("gemini-personal"))
                #expect(output.contains("gemini@example.com"))
            }
        }

        @Test("account list does not crash with no credentials in pool dirs")
        func noCrashWithNoCredentials() throws {
            try withIsolatedHome {
                let store = AccountStore.default
                try store.save(Account(tool: .claude, displayName: "no-creds-claude"))
                try store.save(Account(tool: .codex, displayName: "no-creds-codex"))
                try store.save(Account(tool: .gemini, displayName: "no-creds-gemini"))
                let cmd = try AccountListCommand.parse([])
                let output = try captureStdout { try cmd.run() }
                // Must not crash; all account names should appear.
                #expect(output.contains("no-creds-claude"))
                #expect(output.contains("no-creds-codex"))
                #expect(output.contains("no-creds-gemini"))
            }
        }
    }

    // MARK: AccountShowCommand

    @Suite("AccountShowCommand")
    struct AccountShowTests {
        init() {}

        @Test("unpinned rows show origin and unpinned text")
        func unpinnedRows() throws {
            try withIsolatedHome {
                let cmd = try AccountShowCommand.parse([])
                let output = try captureStdout { try cmd.run() }
                #expect(output.contains("origin"))
                #expect(output.contains("no account pinned"))
            }
        }

        @Test("pinned account shows displayName")
        func pinnedShowsDisplayName() throws {
            try withIsolatedHome {
                let acct = Account(tool: .claude, displayName: "pinned-account")
                try AccountStore.default.save(acct)
                var origin = EnvironmentStore.default.loadOriginConfig()
                origin.accounts["claude"] = acct.id
                try EnvironmentStore.default.saveOriginConfig(origin)
                let cmd = try AccountShowCommand.parse([])
                let output = try captureStdout { try cmd.run() }
                #expect(output.contains("pinned-account"))
            }
        }

        @Test("pinned codex account with stored email and plan shows both")
        func pinnedCodexShowsStoredEmailAndPlan() throws {
            try withIsolatedHome {
                let acctStore = AccountStore.default
                // Simulate what write paths do: store email/plan directly on Account.
                var acct = Account(tool: .codex, displayName: "show-codex")
                acct.email = "codex-show@example.com"
                acct.plan = "pro"
                try acctStore.save(acct)

                // Pin the account to origin.
                var origin = EnvironmentStore.default.loadOriginConfig()
                origin.accounts["codex"] = acct.id
                try EnvironmentStore.default.saveOriginConfig(origin)

                let cmd = try AccountShowCommand.parse([])
                let output = try captureStdout { try cmd.run() }
                #expect(output.contains("show-codex"))
                #expect(output.contains("codex-show@example.com"))
                #expect(output.contains("pro"))
            }
        }

        @Test("pinned account with no credentials shows name without parens")
        func pinnedNoCredentialsShowsNameOnly() throws {
            try withIsolatedHome {
                let acct = Account(tool: .claude, displayName: "bare-account")
                try AccountStore.default.save(acct)
                var origin = EnvironmentStore.default.loadOriginConfig()
                origin.accounts["claude"] = acct.id
                try EnvironmentStore.default.saveOriginConfig(origin)
                let cmd = try AccountShowCommand.parse([])
                let output = try captureStdout { try cmd.run() }
                #expect(output.contains("bare-account"))
                // No trailing " ()" — suffix is empty so no parens added.
                #expect(!output.contains("bare-account ()"))
            }
        }

        @Test("ORRERY_ACTIVE_ENV named env: shows env name and pinned account")
        func activeEnvVarNamedEnv() throws {
            try withIsolatedHome {
                let envStore = EnvironmentStore.default
                let acctStore = AccountStore.default

                // Create account and a named env, then pin the account in that env
                let acct = Account(tool: .claude, displayName: "env-pinned-account")
                try acctStore.save(acct)

                var env = OrreryEnvironment(name: "work-env")
                env.accounts["claude"] = acct.id
                try envStore.save(env)

                // Set ORRERY_ACTIVE_ENV to the named env
                setenv("ORRERY_ACTIVE_ENV", "work-env", 1)
                defer { unsetenv("ORRERY_ACTIVE_ENV") }

                let cmd = try AccountShowCommand.parse([])
                let output = try captureStdout { try cmd.run() }
                #expect(output.contains("work-env"))
                #expect(output.contains("env-pinned-account"))
            }
        }
    }

    // MARK: AccountUseCommand

    @Suite("AccountUseCommand")
    struct AccountUseTests {
        init() {}

        @Test("pinsToOrigin: pins claude account to origin when ORRERY_ACTIVE_ENV is unset")
        func pinsToOrigin() throws {
            try withIsolatedHome {
                // Ensure ORRERY_ACTIVE_ENV is unset
                let savedEnv = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
                unsetenv("ORRERY_ACTIVE_ENV")
                defer {
                    if let saved = savedEnv { setenv("ORRERY_ACTIVE_ENV", saved, 1) }
                }

                let acct = Account(tool: .claude, displayName: "work")
                try AccountStore.default.save(acct)

                let cmd = try AccountUseCommand.parse(["--name", "work"])
                try cmd.run()

                let pinned = EnvironmentStore.default.loadOriginConfig().account(for: .claude)
                #expect(pinned == acct.id)
            }
        }

        @Test("pinsToNamedEnv: pins account to named env without touching origin")
        func pinsToNamedEnv() throws {
            try withIsolatedHome {
                let envStore = EnvironmentStore.default

                // Create the named env
                try envStore.save(OrreryEnvironment(name: "work-env"))

                // Create the account
                let acct = Account(tool: .claude, displayName: "personal")
                try AccountStore.default.save(acct)

                // Set ORRERY_ACTIVE_ENV to the named env
                setenv("ORRERY_ACTIVE_ENV", "work-env", 1)
                defer { unsetenv("ORRERY_ACTIVE_ENV") }

                let cmd = try AccountUseCommand.parse(["--name", "personal"])
                try cmd.run()

                // Named env should have the pin
                let loadedEnv = try envStore.load(named: "work-env")
                #expect(loadedEnv.account(for: .claude) == acct.id)

                // Origin should be untouched
                let originPin = envStore.loadOriginConfig().account(for: .claude)
                #expect(originPin == nil)
            }
        }

        @Test("notFound: throws when account does not exist")
        func notFound() throws {
            try withIsolatedHome {
                let savedEnv = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
                unsetenv("ORRERY_ACTIVE_ENV")
                defer {
                    if let saved = savedEnv { setenv("ORRERY_ACTIVE_ENV", saved, 1) }
                }

                let cmd = try AccountUseCommand.parse(["--name", "ghost"])
                #expect(throws: ValidationError.self) {
                    try cmd.run()
                }
            }
        }

        #if os(macOS)
        @Test("syncBack: account use writes the live token into the OLD account's pool before repinning",
              .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil))
        func syncBackBeforeRepin() throws {
            try withIsolatedHome {
                let envStore = EnvironmentStore.default
                let acctStore = AccountStore.default

                // Create a named env so all live keychain services are env-specific
                // (not "Claude Code-credentials") — hermetic, cannot harm the real credential.
                let envName = "sync-back-env"
                try envStore.save(OrreryEnvironment(name: envName))

                setenv("ORRERY_ACTIVE_ENV", envName, 1)
                defer { unsetenv("ORRERY_ACTIVE_ENV") }

                // Create OLD and NEW accounts.
                let oldID = UUID().uuidString
                let newID = UUID().uuidString
                let oldPoolService = ClaudeKeychain.serviceName(forOrreryAccount: oldID)
                let newPoolService = ClaudeKeychain.serviceName(forOrreryAccount: newID)

                let old = Account(id: oldID, tool: .claude, displayName: "old-account",
                                  keychainItem: oldPoolService)
                let new = Account(id: newID, tool: .claude, displayName: "new-account",
                                  keychainItem: newPoolService)
                try acctStore.save(old)
                try acctStore.save(new)

                // Seed pool tokens so materialize has something to work with.
                #expect(ClaudeKeychain.storePassword("old-pool-token", forOrreryAccount: oldID))
                #expect(ClaudeKeychain.storePassword("new-pool-token", forOrreryAccount: newID))

                // The live slot for this named env.
                let liveConfigDir = envStore.toolConfigDir(tool: .claude, environment: envName)
                let liveService = ClaudeKeychain.service(for: liveConfigDir.path)

                defer {
                    _ = KeychainTestSupport.delete(service: oldPoolService)
                    _ = KeychainTestSupport.delete(service: newPoolService)
                    _ = KeychainTestSupport.delete(service: liveService)
                }

                // Pin OLD in the named env.
                var env = try envStore.load(named: envName)
                env.setAccount(old.id, for: .claude)
                try envStore.save(env)

                // Simulate Claude having refreshed its token in the live slot.
                #expect(ClaudeKeychain.setPassword("live-fresh-token", service: liveService))

                // Run `account use --name new-account` — must sync-back live→old first.
                try AccountUseCommand.parse(["--name", "new-account"]).run()

                // Assert: old's pool entry now holds the live slot's pre-switch token.
                #expect(ClaudeKeychain.password(forService: oldPoolService) == "live-fresh-token")
            }
        }
        #endif

        @Test("materializes: account use places the codex credential into the live config dir")
        func materializesCredential() throws {
            try withIsolatedHome {
                let envStore = EnvironmentStore.default
                let acctStore = AccountStore.default

                // A named env so the live config dir is inside the isolated home
                // (origin would resolve to the real ~/.codex). The materialize
                // path is identical for origin and named envs.
                try envStore.save(OrreryEnvironment(name: "work-env"))

                // Create the codex account and seed a credential file in its pool dir.
                let acct = Account(tool: .codex, displayName: "codex-work")
                try acctStore.save(acct)
                let poolCred = acctStore.accountDir(id: acct.id, tool: .codex)
                    .appendingPathComponent("auth.json")
                try Data("{}".utf8).write(to: poolCred)

                setenv("ORRERY_ACTIVE_ENV", "work-env", 1)
                defer { unsetenv("ORRERY_ACTIVE_ENV") }

                try AccountUseCommand.parse(["--codex", "--name", "codex-work"]).run()

                // account use must have materialized: the live codex config dir
                // now holds auth.json as a symlink pointing into the pool.
                let liveCred = envStore.toolConfigDir(tool: .codex, environment: "work-env")
                    .appendingPathComponent("auth.json")
                let dest = try FileManager.default.destinationOfSymbolicLink(atPath: liveCred.path)
                #expect(dest == poolCred.path)
            }
        }
    }

    // MARK: AccountAddPrepareCommand

    @Suite("AccountAddPrepareCommand")
    struct AccountAddPrepareTests {
        init() {}

        @Test("creates account in store, staging dir on disk, and prints staging path")
        func prepareClaude() throws {
            try withIsolatedHome {
                let output = try captureStdout {
                    let cmd = try AccountAddPrepareCommand.parse(["--name", "prep-test"])
                    try cmd.run()
                }
                let stagingPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(!stagingPath.isEmpty)
                #expect(FileManager.default.fileExists(atPath: stagingPath))

                // The prepare metadata file must exist.
                let metadataURL = URL(fileURLWithPath: stagingPath)
                    .appendingPathComponent(".orrery-prepare.json")
                #expect(FileManager.default.fileExists(atPath: metadataURL.path))

                // Parse and verify metadata content.
                let data = try Data(contentsOf: metadataURL)
                let json = try JSONSerialization.jsonObject(with: data) as! [String: String]
                #expect(json["tool"] == "claude")
                #expect(json["displayName"] == "prep-test")
                #expect(json["accountID"] != nil && !json["accountID"]!.isEmpty)

                // The account must be in the store.
                let accounts = try AccountStore.default.list(tool: .claude)
                #expect(accounts.contains { $0.displayName == "prep-test" })

                // Cleanup staging dir.
                try? FileManager.default.removeItem(atPath: stagingPath)
            }
        }

        @Test("stdout contains only the staging path when --name is given")
        func stdoutOnlyStagingPath() throws {
            try withIsolatedHome {
                let output = try captureStdout {
                    let cmd = try AccountAddPrepareCommand.parse(["--name", "stdout-only-test"])
                    try cmd.run()
                }
                let stagingPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
                // stdout must be exactly the staging path — no extra chatter
                #expect(!stagingPath.isEmpty)
                #expect(!stagingPath.contains("\n"), "stdout must be a single line (the staging path)")
                #expect(FileManager.default.fileExists(atPath: stagingPath))
                // Cleanup
                try? FileManager.default.removeItem(atPath: stagingPath)
            }
        }

        @Test("rejects duplicate display name")
        func prepareDuplicate() throws {
            try withIsolatedHome {
                let output = try captureStdout {
                    let cmd = try AccountAddPrepareCommand.parse(["--name", "dup-prep"])
                    try cmd.run()
                }
                let stagingPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
                defer { try? FileManager.default.removeItem(atPath: stagingPath) }

                // Second call with same name must throw.
                #expect(throws: ValidationError.self) {
                    try AccountAddPrepareCommand.parse(["--name", "dup-prep"]).run()
                }
            }
        }
    }

    // MARK: AccountAddFinalizeCommand

    @Suite("AccountAddFinalizeCommand")
    struct AccountAddFinalizeTests {
        init() {}

        private func makeCodexStagingDir(accountID: String, displayName: String) throws -> URL {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("orrery-login-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

            // Write the prepare metadata.
            let metadata: [String: String] = [
                "accountID": accountID,
                "tool": "codex",
                "displayName": displayName,
            ]
            let metaData = try JSONSerialization.data(withJSONObject: metadata)
            try metaData.write(to: staging.appendingPathComponent(".orrery-prepare.json"))

            return staging
        }

        @Test("finalize imports credential and prints success, removes staging dir")
        func finalizeImportsCredential() throws {
            try withIsolatedHome {
                let store = AccountStore.default
                var acct = Account(tool: .codex, displayName: "finalize-test")
                try store.save(acct)

                let staging = try makeCodexStagingDir(
                    accountID: acct.id,
                    displayName: acct.displayName
                )
                // Write a fake auth.json so importFrom succeeds.
                let authURL = staging.appendingPathComponent("auth.json")
                try Data(#"{"token":"fake"}"#.utf8).write(to: authURL)

                let output = try captureStdout {
                    let cmd = try AccountAddFinalizeCommand.parse(["--staging", staging.path])
                    try cmd.run()
                }

                // Staging dir must be cleaned up by finalize.
                #expect(!FileManager.default.fileExists(atPath: staging.path))

                // Output should mention the account.
                #expect(output.contains("finalize-test"))

                // The credential must be in the pool.
                let poolCred = store.accountDir(id: acct.id, tool: .codex)
                    .appendingPathComponent("auth.json")
                #expect(FileManager.default.fileExists(atPath: poolCred.path))
            }
        }

        @Test("finalize rolls back account when importFrom fails (no credential)")
        func finalizeRollsBackOnFailure() throws {
            try withIsolatedHome {
                let store = AccountStore.default
                let acct = Account(tool: .codex, displayName: "rollback-test")
                try store.save(acct)

                // Staging dir with metadata but NO auth.json — importFrom will fail.
                let staging = try makeCodexStagingDir(
                    accountID: acct.id,
                    displayName: acct.displayName
                )

                // Finalize must throw because there is no credential.
                #expect(throws: (any Error).self) {
                    try AccountAddFinalizeCommand.parse(["--staging", staging.path]).run()
                }

                // Staging dir should be cleaned up even on failure.
                #expect(!FileManager.default.fileExists(atPath: staging.path))

                // Account should have been removed from the store (rollback).
                let accounts = try store.list(tool: .codex)
                #expect(!accounts.contains { $0.displayName == "rollback-test" })
            }
        }
    }

    // MARK: AccountRemoveCommand

    @Suite("AccountRemoveCommand")
    struct AccountRemoveTests {
        init() {}

        @Test("removesUnreferenced: removes account that is not pinned to any env")
        func removesUnreferenced() throws {
            try withIsolatedHome {
                let acct = Account(tool: .claude, displayName: "to-delete")
                try AccountStore.default.save(acct)

                let cmd = try AccountRemoveCommand.parse(["--name", "to-delete"])
                try cmd.run()

                let accounts = try AccountStore.default.list(tool: .claude)
                #expect(!accounts.contains { $0.displayName == "to-delete" })
            }
        }

        @Test("blocksWhenReferenced: throws ValidationError when account is pinned to an env")
        func blocksWhenReferenced() throws {
            try withIsolatedHome {
                let acct = Account(tool: .claude, displayName: "in-use")
                try AccountStore.default.save(acct)

                var origin = EnvironmentStore.default.loadOriginConfig()
                origin.setAccount(acct.id, for: .claude)
                try EnvironmentStore.default.saveOriginConfig(origin)

                let cmd = try AccountRemoveCommand.parse(["--name", "in-use"])
                #expect(throws: ValidationError.self) {
                    try cmd.run()
                }

                let accounts = try AccountStore.default.list(tool: .claude)
                #expect(accounts.contains { $0.displayName == "in-use" })
            }
        }

        @Test("blocks removal when a named env references the account")
        func blocksWhenNamedEnvReferences() throws {
            try withIsolatedHome {
                let acct = Account(tool: .claude, displayName: "named-ref")
                try AccountStore.default.save(acct)

                var env = OrreryEnvironment(name: "work-env")
                env.setAccount(acct.id, for: .claude)
                try EnvironmentStore.default.save(env)

                #expect(throws: ValidationError.self) {
                    try AccountRemoveCommand.parse(["--name", "named-ref"]).run()
                }
                // account must still be in the pool
                #expect(try AccountStore.default.findByDisplayName("named-ref", tool: .claude) != nil)
            }
        }

        @Test("notFound: throws ValidationError when account does not exist")
        func notFound() throws {
            try withIsolatedHome {
                let cmd = try AccountRemoveCommand.parse(["--name", "ghost"])
                #expect(throws: ValidationError.self) {
                    try cmd.run()
                }
            }
        }
    }
}
