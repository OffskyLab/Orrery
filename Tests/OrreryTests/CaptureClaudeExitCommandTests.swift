import ArgumentParser
import Foundation
import Testing
@testable import OrreryCore

@Suite("CaptureClaudeExitCommand")
struct CaptureClaudeExitCommandTests {

    @Test("splits .claude.json into identity and shared stores")
    func splitsToStores() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)
            var pin = try PinCommand.parse(["alice", "--workspace", "work"])
            try pin.run()

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let wsDir = envStore.claudeWorkspaceDir(workspace: "work")

            // Simulate claude having written a fully-merged .claude.json.
            let merged: [String: Any] = [
                "oauthAccount": ["emailAddress": "alice@x.com"],
                "userID": "uid-alice",
                "numStartups": 12,
                "projects": ["/repo/a": ["allowedTools": ["bash"]]],
                "tipsHistory": ["seenA": 1],
            ]
            try ClaudeJsonMerge.saveJSON(
                merged,
                at: acctDir.appendingPathComponent(".claude.json"))

            var cmd = try CaptureClaudeExitCommand.parse(["--account-dir", acctDir.path])
            try cmd.run()

            let identity = ClaudeJsonMerge.loadJSON(
                at: ClaudeJsonMerge.identityFileURL(accountDir: acctDir))
            let shared = ClaudeJsonMerge.loadJSON(
                at: ClaudeJsonMerge.sharedFileURL(workspaceDir: wsDir))

            #expect(identity != nil)
            #expect((identity?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "alice@x.com")
            #expect(identity?["userID"] as? String == "uid-alice")
            #expect(identity?["numStartups"] as? Int == 12)
            #expect(identity?["projects"] == nil)
            #expect(identity?["tipsHistory"] == nil)

            #expect(shared != nil)
            #expect((shared?["projects"] as? [String: Any])?["/repo/a"] != nil)
            #expect((shared?["tipsHistory"] as? [String: Any])?["seenA"] as? Int == 1)
            #expect(shared?["oauthAccount"] == nil)
            #expect(shared?["numStartups"] == nil)
        }
    }

    @Test("no .claude.json present is a no-op (not an error)")
    func noClaudeJSONNoop() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)
            var pin = try PinCommand.parse(["alice", "--workspace", "origin"])
            try pin.run()

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            // No .claude.json written.

            var cmd = try CaptureClaudeExitCommand.parse(["--account-dir", acctDir.path])
            #expect(throws: Never.self) {
                try cmd.run()
            }

            // Both stores should remain absent.
            #expect(ClaudeJsonMerge.loadJSON(
                at: ClaudeJsonMerge.identityFileURL(accountDir: acctDir)) == nil)
        }
    }

    @Test("non-existent account dir throws ValidationError")
    func nonexistentAccountDirThrows() throws {
        var cmd = try CaptureClaudeExitCommand.parse(
            ["--account-dir", "/tmp/nope-\(UUID().uuidString)"])
        #expect(throws: ValidationError.self) {
            try cmd.run()
        }
    }

    #if os(macOS)
    @Test("syncs the live (config-dir-hashed) Keychain credential back into the account's pool copy")
    func syncsKeychainToPool() throws {
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

            // Stale pool copy (as if from account-add months ago).
            ClaudeKeychain.storePassword(
                #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"old-refresh","expiresAt":1000}}"#,
                forOrreryAccount: acct.id
            )
            // Fresh credential claude itself wrote during this session (e.g. via `/login`).
            ClaudeKeychain.setPassword(
                #"{"claudeAiOauth":{"accessToken":"new","refreshToken":"new-refresh","expiresAt":2000}}"#,
                service: liveService
            )

            var cmd = try CaptureClaudeExitCommand.parse(["--account-dir", acctDir.path])
            try cmd.run()

            let synced = ClaudeKeychain.oauthCredential(forService: acct.keychainItem!)
            #expect(synced?.refreshToken == "new-refresh")
        }
    }
    #endif
}
