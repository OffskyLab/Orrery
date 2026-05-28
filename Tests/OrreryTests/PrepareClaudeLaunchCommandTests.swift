import Foundation
import Testing
@testable import OrreryCore

@Suite("PrepareClaudeLaunchCommand")
struct PrepareClaudeLaunchCommandTests {

    @Test("writes merged .claude.json from identity + shared stores")
    func mergesIdentityAndShared() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            // Set up an account pinned to a workspace via Plan 1's pin command.
            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)
            var pin = try PinCommand.parse(["alice", "--workspace", "work"])
            try pin.run()

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let wsDir = envStore.claudeWorkspaceDir(workspace: "work")

            // Seed identity + shared stores with non-overlapping fields.
            let identity: [String: Any] = [
                "oauthAccount": ["emailAddress": "alice@example.com"],
                "userID": "uid-alice",
                "numStartups": 7,
            ]
            let shared: [String: Any] = [
                "projects": ["/A": ["allowedTools": []]],
                "tipsHistory": ["tip-1": 1],
            ]
            try ClaudeJsonMerge.saveJSON(identity,
                at: ClaudeJsonMerge.identityFileURL(accountDir: acctDir))
            try ClaudeJsonMerge.saveJSON(shared,
                at: ClaudeJsonMerge.sharedFileURL(workspaceDir: wsDir))

            // Run the prepare command targeting this account dir.
            var cmd = try PrepareClaudeLaunchCommand.parse(["--account-dir", acctDir.path])
            try cmd.run()

            // .claude.json now contains the merged union.
            let claudeJSON = ClaudeJsonMerge.loadJSON(
                at: acctDir.appendingPathComponent(".claude.json"))
            #expect(claudeJSON != nil)
            #expect((claudeJSON?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "alice@example.com")
            #expect(claudeJSON?["userID"] as? String == "uid-alice")
            #expect(claudeJSON?["numStartups"] as? Int == 7)
            #expect((claudeJSON?["projects"] as? [String: Any])?.keys.contains("/A") == true)
            #expect((claudeJSON?["tipsHistory"] as? [String: Any])?["tip-1"] as? Int == 1)
        }
    }

    @Test("empty stores produce an empty .claude.json (not an error)")
    func emptyStoresOK() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)
            var pin = try PinCommand.parse(["alice", "--workspace", "origin"])
            try pin.run()

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            var cmd = try PrepareClaudeLaunchCommand.parse(["--account-dir", acctDir.path])
            try cmd.run()

            let claudeJSON = ClaudeJsonMerge.loadJSON(
                at: acctDir.appendingPathComponent(".claude.json"))
            #expect(claudeJSON?.isEmpty == true)
        }
    }

    @Test("non-existent account dir throws clearly")
    func nonexistentAccountDirThrows() throws {
        var cmd = try PrepareClaudeLaunchCommand.parse(
            ["--account-dir", "/tmp/nope-\(UUID().uuidString)"])
        #expect(throws: (any Error).self) {
            try cmd.run()
        }
    }
}
