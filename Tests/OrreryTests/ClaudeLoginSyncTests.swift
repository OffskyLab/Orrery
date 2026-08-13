import Foundation
import Testing
@testable import OrreryCore

#if os(macOS)
@Suite("ClaudeLoginSync.syncIfChanged (isolated $ORRERY_HOME, real Keychain items with cleanup)")
struct ClaudeLoginSyncTests {

    @Test("detects a changed refreshToken, syncs it, and fires AccountLoginHooks")
    func detectsAndSyncsChange() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            var acct = Account(tool: .claude, displayName: "alice")
            acct.keychainItem = ClaudeKeychain.serviceName(forOrreryAccount: acct.id)
            try acctStore.save(acct)
            var pin = try PinCommand.parse(["alice", "--workspace", "origin"])
            try pin.run()

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let liveService = ClaudeKeychain.service(for: acctDir.path)
            defer {
                ClaudeKeychain.deleteKeychainItem(service: liveService)
                ClaudeKeychain.deleteKeychainItem(service: acct.keychainItem!)
            }

            ClaudeKeychain.storePassword(
                #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"old-refresh","expiresAt":1000}}"#,
                forOrreryAccount: acct.id
            )
            ClaudeKeychain.setPassword(
                #"{"claudeAiOauth":{"accessToken":"new","refreshToken":"new-refresh","expiresAt":2000}}"#,
                service: liveService
            )

            // Marker to confirm AccountLoginHooks actually fired.
            let markerURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("orrery-hook-marker-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: markerURL) }
            let scriptURL = AccountLoginHooks.onLoginScriptURL
            try FileManager.default.createDirectory(
                at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try "#!/bin/sh\ntouch \"\(markerURL.path)\"\n".write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let changed = ClaudeLoginSync.syncIfChanged(accountDir: acctDir)

            #expect(changed)
            #expect(ClaudeKeychain.oauthCredential(forService: acct.keychainItem!)?.refreshToken == "new-refresh")
            #expect(FileManager.default.fileExists(atPath: markerURL.path))
        }
    }

    @Test("returns false and touches nothing when the refreshToken is unchanged")
    func noChangeReturnsFalse() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            var acct = Account(tool: .claude, displayName: "alice")
            acct.keychainItem = ClaudeKeychain.serviceName(forOrreryAccount: acct.id)
            try acctStore.save(acct)
            var pin = try PinCommand.parse(["alice", "--workspace", "origin"])
            try pin.run()

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let liveService = ClaudeKeychain.service(for: acctDir.path)
            defer {
                ClaudeKeychain.deleteKeychainItem(service: liveService)
                ClaudeKeychain.deleteKeychainItem(service: acct.keychainItem!)
            }

            let same = #"{"claudeAiOauth":{"accessToken":"same","refreshToken":"same-refresh","expiresAt":1000}}"#
            ClaudeKeychain.storePassword(same, forOrreryAccount: acct.id)
            ClaudeKeychain.setPassword(same, service: liveService)

            #expect(ClaudeLoginSync.syncIfChanged(accountDir: acctDir) == false)
        }
    }

    @Test("returns false when the account has no keychainItem")
    func noKeychainItemReturnsFalse() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let acct = Account(tool: .claude, displayName: "alice") // keychainItem left nil
            try acctStore.save(acct)
            var pin = try PinCommand.parse(["alice", "--workspace", "origin"])
            try pin.run()

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            #expect(ClaudeLoginSync.syncIfChanged(accountDir: acctDir) == false)
        }
    }
}
#endif
