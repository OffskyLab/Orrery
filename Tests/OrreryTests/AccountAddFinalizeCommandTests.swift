import ArgumentParser
import Foundation
import Testing
@testable import OrreryCore

#if os(macOS)
// .serialized: mutates the global ORRERY_HOME via withIsolatedHome, same
// requirement as AccountLoginFlowTests.
@Suite("AccountAddFinalizeCommand --keep-staging", .serialized)
struct AccountAddFinalizeCommandTests {

    @Test(
        "hook-triggered finalize (--keep-staging) leaves the staging dir in place; the later exit-time finalize cleans it up",
        .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil)
    )
    func keepStagingThenExitCleansUp() throws {
        try withIsolatedHome {
            let store = AccountStore.default
            let accountID = UUID().uuidString
            let orreryService = ClaudeKeychain.serviceName(forOrreryAccount: accountID)
            let account = Account(
                id: accountID, tool: .claude, displayName: "auto-hook", keychainItem: orreryService
            )
            try store.save(account)

            let stagingDir = makeStagingDir()
            let stagingService = ClaudeKeychain.service(for: stagingDir.path)
            defer {
                try? FileManager.default.removeItem(at: stagingDir)
                _ = KeychainTestSupport.delete(service: stagingService)
                _ = KeychainTestSupport.delete(service: orreryService)
            }

            try writeMetadata(
                accountID: accountID, tool: .claude, displayName: "auto-hook", stagingDir: stagingDir
            )
            // Simulate claude having written its live credential to the
            // staging-derived Keychain service after /login.
            #expect(ClaudeKeychain.setPassword("claude-token", service: stagingService))

            // Simulate the auth_success hook firing while claude is still running
            // (CLAUDE_CONFIG_DIR still points at stagingDir).
            var hookFinalize = try AccountAddFinalizeCommand.parse(
                ["--staging", stagingDir.path, "--keep-staging"]
            )
            try hookFinalize.run()

            #expect(
                FileManager.default.fileExists(atPath: stagingDir.path),
                "hook-triggered finalize must not delete the staging dir out from under the running claude session"
            )
            #expect(ClaudeKeychain.password(forService: orreryService) == "claude-token")

            // Simulate the shell wrapper's own finalize call once the user
            // eventually exits claude — same staging dir, no --keep-staging.
            // Must not throw even though the hook already imported everything.
            var exitFinalize = try AccountAddFinalizeCommand.parse(["--staging", stagingDir.path])
            try exitFinalize.run()

            #expect(
                !FileManager.default.fileExists(atPath: stagingDir.path),
                "exit-time finalize still cleans up the staging dir"
            )
        }
    }

    @Test(
        "re-finalizing after a /login to a different account overwrites the identity's oauthAccount, not the reverse",
        .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil)
    )
    func reloginOverwritesStaleIdentity() throws {
        try withIsolatedHome {
            let store = AccountStore.default
            let accountID = UUID().uuidString
            let orreryService = ClaudeKeychain.serviceName(forOrreryAccount: accountID)
            let account = Account(
                id: accountID, tool: .claude, displayName: "capture-relogin", keychainItem: orreryService
            )
            try store.save(account)

            let stagingDir = makeStagingDir()
            let stagingService = ClaudeKeychain.service(for: stagingDir.path)
            defer {
                try? FileManager.default.removeItem(at: stagingDir)
                _ = KeychainTestSupport.delete(service: stagingService)
                _ = KeychainTestSupport.delete(service: orreryService)
            }
            try writeMetadata(accountID: accountID, tool: .claude, displayName: "capture-relogin", stagingDir: stagingDir)

            // First login: account A. Both the live credential and the
            // staging .claude.json's session capture reflect A.
            #expect(ClaudeKeychain.setPassword(
                #"{"claudeAiOauth":{"accessToken":"at-a","refreshToken":"token-a","expiresAt":9999999999999,"subscriptionType":"team"}}"#,
                service: stagingService
            ))
            try writeStagingClaudeJSON(stagingDir: stagingDir, email: "a@example.com", subscriptionType: "team")

            let firstFinalize = try AccountAddFinalizeCommand.parse(["--staging", stagingDir.path, "--keep-staging"])
            try firstFinalize.run()

            let accountDir = store.accountDir(id: accountID, tool: .claude)
            let identityURL = ClaudeJsonMerge.identityFileURL(accountDir: accountDir)
            var identity = try #require(ClaudeJsonMerge.loadJSON(at: identityURL))
            var oauth = try #require(identity["oauthAccount"] as? [String: Any])
            #expect(oauth["emailAddress"] as? String == "a@example.com")

            // User runs /login inside the same still-open session and
            // switches to account B — a completely different login, not a
            // token refresh of A. Both the live credential and the staging
            // .claude.json now reflect B.
            #expect(ClaudeKeychain.setPassword(
                #"{"claudeAiOauth":{"accessToken":"at-b","refreshToken":"token-b","expiresAt":9999999999999,"subscriptionType":"pro"}}"#,
                service: stagingService
            ))
            try writeStagingClaudeJSON(stagingDir: stagingDir, email: "b@example.com", subscriptionType: "pro")

            let secondFinalize = try AccountAddFinalizeCommand.parse(["--staging", stagingDir.path, "--keep-staging"])
            try secondFinalize.run()

            identity = try #require(ClaudeJsonMerge.loadJSON(at: identityURL))
            oauth = try #require(identity["oauthAccount"] as? [String: Any])
            #expect(
                oauth["emailAddress"] as? String == "b@example.com",
                "the persisted identity must reflect account B, not stay frozen on account A's profile"
            )
            #expect(oauth["subscriptionType"] as? String == "pro")
            #expect(oauth["refreshToken"] as? String == "token-b")
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

    /// Minimal staging `.claude.json` with just enough shape for
    /// `ClaudeJsonMerge.split` + `captureLoginState` to pick up a session
    /// capture with the given account's profile info.
    private func writeStagingClaudeJSON(stagingDir: URL, email: String, subscriptionType: String) throws {
        let claudeJSON: [String: Any] = [
            "hasCompletedOnboarding": true,
            "oauthAccount": [
                "emailAddress": email,
                "subscriptionType": subscriptionType,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: claudeJSON, options: [.sortedKeys])
        try data.write(to: stagingDir.appendingPathComponent(".claude.json"))
    }
}
#endif
