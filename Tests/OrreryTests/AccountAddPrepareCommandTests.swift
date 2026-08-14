import ArgumentParser
import Foundation
import Testing
@testable import OrreryCore

#if os(macOS)
@Suite("AccountAddPrepareCommand.patchAutoFinalizeHook")
struct AccountAddPrepareCommandTests {

    @Test("installs a Notification/auth_success hook pointing at _account-add-finalize --keep-staging")
    func installsAutoFinalizeHook() throws {
        let stagingDir = makeStagingDir()
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        AccountAddPrepareCommand.patchAutoFinalizeHook(
            stagingDir: stagingDir, orreryBinPath: "/usr/local/bin/orrery-bin"
        )

        let settingsURL = stagingDir.appendingPathComponent("settings.json")
        let data = try Data(contentsOf: settingsURL)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(obj["hooks"] as? [String: Any])
        let notifications = try #require(hooks["Notification"] as? [[String: Any]])
        #expect(notifications.count == 1)
        #expect(notifications.first?["matcher"] as? String == "auth_success")
        let innerHooks = try #require(notifications.first?["hooks"] as? [[String: Any]])
        #expect(innerHooks.first?["command"] as? String
            == "/usr/local/bin/orrery-bin _account-add-finalize --staging \(stagingDir.path) --keep-staging")
    }

    @Test("preserves existing settings.json content")
    func preservesExistingSettings() throws {
        let stagingDir = makeStagingDir()
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let settingsURL = stagingDir.appendingPathComponent("settings.json")
        try #"{"theme":"dark"}"#.write(to: settingsURL, atomically: true, encoding: .utf8)

        AccountAddPrepareCommand.patchAutoFinalizeHook(
            stagingDir: stagingDir, orreryBinPath: "/usr/local/bin/orrery-bin"
        )

        let data = try Data(contentsOf: settingsURL)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["theme"] as? String == "dark")
        #expect(obj["hooks"] != nil)
    }

    @Test("is idempotent — a second call with the same staging dir doesn't duplicate the entry")
    func idempotent() throws {
        let stagingDir = makeStagingDir()
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        AccountAddPrepareCommand.patchAutoFinalizeHook(
            stagingDir: stagingDir, orreryBinPath: "/usr/local/bin/orrery-bin"
        )
        AccountAddPrepareCommand.patchAutoFinalizeHook(
            stagingDir: stagingDir, orreryBinPath: "/usr/local/bin/orrery-bin"
        )

        let data = try Data(contentsOf: stagingDir.appendingPathComponent("settings.json"))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(obj["hooks"] as? [String: Any])
        let notifications = try #require(hooks["Notification"] as? [[String: Any]])
        #expect(notifications.count == 1)
    }

    // MARK: - Helpers

    private func makeStagingDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-login-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

@Suite("AccountAddPrepareCommand.healHook")
struct AccountAddPrepareCommandHealHookTests {

    @Test("re-adds the auth_success hook after claude's onboarding wipes settings.json down to just {theme}")
    func reAddsHookAfterOnboardingOverwrite() throws {
        let stagingDir = makeStagingDir()
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        // Simulate claude's own first-run onboarding write, which replaces
        // settings.json wholesale — this is exactly what wipes the hook
        // _account-add-prepare installed before launch.
        let settingsURL = stagingDir.appendingPathComponent("settings.json")
        try #"{"theme":"dark"}"#.write(to: settingsURL, atomically: true, encoding: .utf8)

        AccountAddPrepareCommand.healHook(stagingDir: stagingDir)

        let data = try Data(contentsOf: settingsURL)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["theme"] as? String == "dark")
        let hooks = try #require(obj["hooks"] as? [String: Any])
        let notifications = try #require(hooks["Notification"] as? [[String: Any]])
        #expect(notifications.first?["matcher"] as? String == "auth_success")
        let innerHooks = try #require(notifications.first?["hooks"] as? [[String: Any]])
        let command = try #require(innerHooks.first?["command"] as? String)
        #expect(command.contains("_account-add-finalize --staging \(stagingDir.path) --keep-staging"))
    }

    @Test("calling healHook repeatedly doesn't duplicate the hook entry")
    func repeatedCallsStayIdempotent() throws {
        let stagingDir = makeStagingDir()
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        AccountAddPrepareCommand.healHook(stagingDir: stagingDir)
        AccountAddPrepareCommand.healHook(stagingDir: stagingDir)
        AccountAddPrepareCommand.healHook(stagingDir: stagingDir)

        let data = try Data(contentsOf: stagingDir.appendingPathComponent("settings.json"))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(obj["hooks"] as? [String: Any])
        let notifications = try #require(hooks["Notification"] as? [[String: Any]])
        #expect(notifications.count == 1)
    }

    private func makeStagingDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-login-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

@Suite("AccountAddHealHookCommand")
struct AccountAddHealHookCommandTests {

    @Test("parses --staging into the staging property")
    func parsesStagingOption() throws {
        let command = try AccountAddHealHookCommand.parse(["--staging", "/tmp/orrery-login-abc"])
        #expect(command.staging == "/tmp/orrery-login-abc")
    }
}

// .serialized: mutates the global ORRERY_HOME via withIsolatedHome, same
// requirement as AccountAddFinalizeCommandTests/AccountLoginFlowTests.
@Suite("AccountAddHealHookCommand.run — polls for login completion", .serialized)
struct AccountAddHealHookCommandFinalizeTests {

    @Test(
        "does nothing while no live credential exists yet — must not delete the in-progress account",
        .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil)
    )
    func noOpBeforeLoginCompletes() throws {
        try withIsolatedHome {
            let store = AccountStore.default
            let accountID = UUID().uuidString
            let orreryService = ClaudeKeychain.serviceName(forOrreryAccount: accountID)
            let account = Account(
                id: accountID, tool: .claude, displayName: "watchdog-early-tick", keychainItem: orreryService
            )
            try store.save(account)

            let stagingDir = makeStagingDir()
            defer {
                try? FileManager.default.removeItem(at: stagingDir)
                _ = KeychainTestSupport.delete(service: orreryService)
            }
            try writeMetadata(accountID: accountID, tool: .claude, displayName: "watchdog-early-tick", stagingDir: stagingDir)

            var tick = try AccountAddHealHookCommand.parse(["--staging", stagingDir.path])
            try tick.run()

            #expect(try store.load(id: accountID, tool: .claude).displayName == "watchdog-early-tick")
        }
    }

    @Test(
        "finalizes as soon as the live credential lands, without waiting for claude's auth_success hook to fire",
        .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil)
    )
    func finalizesOnceCredentialLands() throws {
        try withIsolatedHome {
            let store = AccountStore.default
            let accountID = UUID().uuidString
            let orreryService = ClaudeKeychain.serviceName(forOrreryAccount: accountID)
            let account = Account(
                id: accountID, tool: .claude, displayName: "watchdog-poll", keychainItem: orreryService
            )
            try store.save(account)

            let stagingDir = makeStagingDir()
            let stagingService = ClaudeKeychain.service(for: stagingDir.path)
            defer {
                try? FileManager.default.removeItem(at: stagingDir)
                _ = KeychainTestSupport.delete(service: stagingService)
                _ = KeychainTestSupport.delete(service: orreryService)
            }
            try writeMetadata(accountID: accountID, tool: .claude, displayName: "watchdog-poll", stagingDir: stagingDir)

            // Simulate claude's login landing the live credential — but the
            // auth_success hook never fires (the scenario this exists for).
            // Shape matches what `oauthCredential(forService:)` requires
            // (accessToken/refreshToken/expiresAt) so the watchdog's
            // login-completed check actually recognizes it.
            let credentialJSON = #"""
            {"claudeAiOauth":{"accessToken":"at","refreshToken":"claude-token","expiresAt":9999999999999}}
            """#
            #expect(ClaudeKeychain.setPassword(credentialJSON, service: stagingService))

            var tick = try AccountAddHealHookCommand.parse(["--staging", stagingDir.path])
            try tick.run()

            #expect(ClaudeKeychain.password(forService: orreryService) == credentialJSON)
            #expect(
                FileManager.default.fileExists(atPath: stagingDir.path),
                "polled finalize must keep --keep-staging semantics — claude may still be running"
            )

            // A later tick (or the shell's exit-time finalize) must not
            // re-import or error just because it already ran once.
            let secondTick = try AccountAddHealHookCommand.parse(["--staging", stagingDir.path])
            try secondTick.run()
            #expect(ClaudeKeychain.password(forService: orreryService) == credentialJSON)
        }
    }

    @Test(
        "picks up a /login to a different account inside the same still-open session, not just the first login",
        .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil)
    )
    func picksUpReloginToADifferentAccount() throws {
        try withIsolatedHome {
            let store = AccountStore.default
            let accountID = UUID().uuidString
            let orreryService = ClaudeKeychain.serviceName(forOrreryAccount: accountID)
            let account = Account(
                id: accountID, tool: .claude, displayName: "watchdog-relogin", keychainItem: orreryService
            )
            try store.save(account)

            let stagingDir = makeStagingDir()
            let stagingService = ClaudeKeychain.service(for: stagingDir.path)
            defer {
                try? FileManager.default.removeItem(at: stagingDir)
                _ = KeychainTestSupport.delete(service: stagingService)
                _ = KeychainTestSupport.delete(service: orreryService)
            }
            try writeMetadata(accountID: accountID, tool: .claude, displayName: "watchdog-relogin", stagingDir: stagingDir)

            // First login: Account A.
            let credentialA = #"""
            {"claudeAiOauth":{"accessToken":"at-a","refreshToken":"token-a","expiresAt":9999999999999}}
            """#
            #expect(ClaudeKeychain.setPassword(credentialA, service: stagingService))
            var firstTick = try AccountAddHealHookCommand.parse(["--staging", stagingDir.path])
            try firstTick.run()
            #expect(ClaudeKeychain.password(forService: orreryService) == credentialA)

            // User runs `/login` inside the same still-open session and
            // switches to a completely different account, B, before ever
            // exiting claude. The watchdog must notice the refresh token
            // changed and re-import — not freeze on whichever login landed
            // first.
            let credentialB = #"""
            {"claudeAiOauth":{"accessToken":"at-b","refreshToken":"token-b","expiresAt":9999999999999}}
            """#
            #expect(ClaudeKeychain.setPassword(credentialB, service: stagingService))
            let secondTick = try AccountAddHealHookCommand.parse(["--staging", stagingDir.path])
            try secondTick.run()

            #expect(
                ClaudeKeychain.password(forService: orreryService) == credentialB,
                "the pool copy must track account B's credential, not stay frozen on account A's"
            )
        }
    }

    // MARK: - Helpers

    private func makeStagingDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-login-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeMetadata(accountID: String, tool: Tool, displayName: String, stagingDir: URL) throws {
        let metadata: [String: String] = [
            "accountID": accountID,
            "tool": tool.rawValue,
            "displayName": displayName,
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        try data.write(to: stagingDir.appendingPathComponent(".orrery-prepare.json"))
    }
}
#endif
