import Testing
import Foundation
@testable import OrreryCore

#if os(macOS)

/// Test-only mutable call recorder. Confined to a single synchronous test
/// body (never actually shared across threads) — `@unchecked Sendable` just
/// satisfies the closures' `@Sendable` requirement.
fileprivate final class Recorder: @unchecked Sendable {
    var transportCalls: [String] = []
    var updateCalls: [(service: String, accessToken: String, refreshToken: String, expiresAt: Date)] = []
}

@Suite("TokenRefreshRunner")
struct TokenRefreshRunnerTests {
    static let fixedNow = Date(timeIntervalSince1970: 1_000_000)

    static func account(id: String = "acct-1", keychainItem: String? = "svc-1") -> Account {
        Account(id: id, tool: .claude, displayName: "Test Account", keychainItem: keychainItem)
    }

    static func credential(expiresIn: TimeInterval, refreshToken: String = "old-refresh") -> ClaudeKeychain.OAuthCredential {
        ClaudeKeychain.OAuthCredential(
            accessToken: "old-access",
            refreshToken: refreshToken,
            expiresAt: fixedNow.addingTimeInterval(expiresIn),
            subscriptionType: "pro"
        )
    }

    fileprivate static func runner(
        recorder: Recorder,
        credential: ClaudeKeychain.OAuthCredential?,
        transportResult: TokenRefreshOutcome,
        accountDir: @escaping @Sendable (Account) -> URL = { _ in FileManager.default.temporaryDirectory }
    ) -> TokenRefreshRunner {
        TokenRefreshRunner(
            oauthCredential: { service in
                recorder.transportCalls.append("oauthCredential:\(service)")
                return credential
            },
            updateCredential: { service, accessToken, refreshToken, expiresAt in
                recorder.updateCalls.append((service, accessToken, refreshToken, expiresAt))
                return true
            },
            transport: TokenRefreshTransport(refresh: { refreshToken in
                recorder.transportCalls.append("transport:\(refreshToken)")
                return transportResult
            }),
            now: { fixedNow },
            accountDir: accountDir
        )
    }

    @Test("excludingOrigin filters out only the account matching originAccountID")
    func excludingOriginFiltersOnlyOriginAccount() {
        let origin = Self.account(id: "origin-acct")
        let other = Self.account(id: "other-acct")
        let result = TokenRefreshRunner.excludingOrigin([origin, other], originAccountID: "origin-acct")
        #expect(result.map(\.id) == ["other-acct"])
    }

    @Test("excludingOrigin is a no-op when there's no origin account")
    func excludingOriginNoOpWhenNilOriginID() {
        let a = Self.account(id: "a")
        let b = Self.account(id: "b")
        let result = TokenRefreshRunner.excludingOrigin([a, b], originAccountID: nil)
        #expect(result.map(\.id) == ["a", "b"])
    }

    @Test("skips accounts with no keychain item — never touches the transport")
    func skipsMissingKeychainItem() {
        let recorder = Recorder()
        let runner = Self.runner(
            recorder: recorder,
            credential: Self.credential(expiresIn: 10),
            transportResult: .failure(reason: "should not be called")
        )
        let results = runner.sweep(accounts: [Self.account(keychainItem: nil)], threshold: 3600)
        #expect(results.map(\.1) == [.skipped])
        #expect(recorder.transportCalls.isEmpty)
    }

    @Test("skips accounts with unreadable credential")
    func skipsUnreadableCredential() {
        let recorder = Recorder()
        let runner = Self.runner(recorder: recorder, credential: nil, transportResult: .failure(reason: "n/a"))
        let results = runner.sweep(accounts: [Self.account()], threshold: 3600)
        #expect(results.map(\.1) == [.skipped])
        #expect(recorder.transportCalls == ["oauthCredential:svc-1"])
    }

    @Test("skips accounts whose token is not near expiry")
    func skipsFarFromExpiry() {
        let recorder = Recorder()
        let runner = Self.runner(
            recorder: recorder,
            credential: Self.credential(expiresIn: 4 * 3600),
            transportResult: .failure(reason: "should not be called")
        )
        let results = runner.sweep(accounts: [Self.account()], threshold: 3600)
        #expect(results.map(\.1) == [.skipped])
        #expect(!recorder.transportCalls.contains { $0.hasPrefix("transport:") })
    }

    @Test("refreshes and writes back accounts near expiry")
    func refreshesNearExpiry() {
        let recorder = Recorder()
        let runner = Self.runner(
            recorder: recorder,
            credential: Self.credential(expiresIn: 300, refreshToken: "old-refresh"),
            transportResult: .success(accessToken: "new-access", refreshToken: "new-refresh", expiresIn: 28800)
        )
        let results = runner.sweep(accounts: [Self.account()], threshold: 3600)
        #expect(results.map(\.1) == [.refreshed])
        #expect(recorder.transportCalls.contains("transport:old-refresh"))
        #expect(recorder.updateCalls.count == 1)
        let update = recorder.updateCalls[0]
        #expect(update.service == "svc-1")
        #expect(update.accessToken == "new-access")
        #expect(update.refreshToken == "new-refresh")
        #expect(update.expiresAt == Self.fixedNow.addingTimeInterval(28800))
    }

    @Test("force bypasses the expiry threshold")
    func forceBypassesThreshold() {
        let recorder = Recorder()
        let runner = Self.runner(
            recorder: recorder,
            credential: Self.credential(expiresIn: 4 * 3600),
            transportResult: .success(accessToken: "new-access", refreshToken: "new-refresh", expiresIn: 28800)
        )
        let results = runner.sweep(accounts: [Self.account()], threshold: 3600, force: true)
        #expect(results.map(\.1) == [.refreshed])
        #expect(recorder.updateCalls.count == 1)
    }

    @Test("transport failure leaves the credential untouched and reports the reason")
    func transportFailureLeavesCredentialUntouched() {
        let recorder = Recorder()
        let runner = Self.runner(
            recorder: recorder,
            credential: Self.credential(expiresIn: 300),
            transportResult: .failure(reason: "network unreachable")
        )
        let results = runner.sweep(accounts: [Self.account()], threshold: 3600)
        #expect(results.map(\.1) == [.failed("network unreachable")])
        #expect(recorder.updateCalls.isEmpty)
    }

    @Test("one account's failure doesn't stop the sweep for the rest")
    func oneFailureDoesNotStopSweep() {
        let credentials: [String: ClaudeKeychain.OAuthCredential] = [
            "svc-fail": Self.credential(expiresIn: 300, refreshToken: "refresh-fail"),
            "svc-ok": Self.credential(expiresIn: 300, refreshToken: "refresh-ok"),
        ]
        let recorder = Recorder()
        let runner = TokenRefreshRunner(
            oauthCredential: { service in credentials[service] },
            updateCredential: { service, accessToken, refreshToken, expiresAt in
                recorder.updateCalls.append((service, accessToken, refreshToken, expiresAt))
                return true
            },
            transport: TokenRefreshTransport(refresh: { token in
                token == "refresh-fail"
                    ? .failure(reason: "boom")
                    : .success(accessToken: "new-access", refreshToken: "new-refresh", expiresIn: 28800)
            }),
            now: { Self.fixedNow },
            accountDir: { _ in FileManager.default.temporaryDirectory }
        )

        let accounts = [
            Self.account(id: "a", keychainItem: "svc-fail"),
            Self.account(id: "b", keychainItem: "svc-ok"),
        ]
        let results = runner.sweep(accounts: accounts, threshold: 3600)
        #expect(results.map(\.1) == [.failed("boom"), .refreshed])
        #expect(recorder.updateCalls.map(\.service) == ["svc-ok"])
    }

    @Test("patches claude-identity.json's oauthAccount when the identity file already exists")
    func patchesIdentityFileWhenPresent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-refresh-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let identityURL = ClaudeJsonMerge.identityFileURL(accountDir: tempDir)
        try ClaudeJsonMerge.saveJSON([
            "oauthAccount": [
                "accessToken": "old-access",
                "refreshToken": "old-refresh",
                "expiresAt": 1_000_000_000,
                "emailAddress": "user@example.com",
            ],
            "numStartups": 3,
        ], at: identityURL)

        let recorder = Recorder()
        let runner = Self.runner(
            recorder: recorder,
            credential: Self.credential(expiresIn: 300, refreshToken: "old-refresh"),
            transportResult: .success(accessToken: "new-access", refreshToken: "new-refresh", expiresIn: 28800),
            accountDir: { _ in tempDir }
        )

        let results = runner.sweep(accounts: [Self.account()], threshold: 3600)
        #expect(results.map(\.1) == [.refreshed])

        let identity = try #require(ClaudeJsonMerge.loadJSON(at: identityURL))
        let oauthAccount = try #require(identity["oauthAccount"] as? [String: Any])
        #expect(oauthAccount["accessToken"] as? String == "new-access")
        #expect(oauthAccount["refreshToken"] as? String == "new-refresh")
        #expect(oauthAccount["emailAddress"] as? String == "user@example.com") // sibling key preserved
        #expect(identity["numStartups"] as? Int == 3) // sibling top-level key preserved
    }

    @Test("does not create claude-identity.json when it doesn't already exist")
    func doesNotCreateIdentityFile() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-refresh-test-\(UUID().uuidString)")
        let recorder = Recorder()
        let runner = Self.runner(
            recorder: recorder,
            credential: Self.credential(expiresIn: 300),
            transportResult: .success(accessToken: "new-access", refreshToken: "new-refresh", expiresIn: 28800),
            accountDir: { _ in tempDir }
        )
        let results = runner.sweep(accounts: [Self.account()], threshold: 3600)
        #expect(results.map(\.1) == [.refreshed])
        let identityURL = ClaudeJsonMerge.identityFileURL(accountDir: tempDir)
        #expect(!FileManager.default.fileExists(atPath: identityURL.path))
    }
}

#endif
