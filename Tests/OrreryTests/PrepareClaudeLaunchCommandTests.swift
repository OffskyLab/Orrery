import ArgumentParser
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
        #expect(throws: ValidationError.self) {
            try cmd.run()
        }
    }

    @Test("launch links a new shareable account dir into the workspace")
    func linksNewShareableDir() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)
            try PinCommand.parse(["alice", "--workspace", "work"]).run()

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let wsDir = envStore.claudeWorkspaceDir(workspace: "work")

            // Simulate claude having created a brand-new folder in the account dir.
            let skills = acctDir.appendingPathComponent("skills")
            try FileManager.default.createDirectory(
                at: skills, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: skills.appendingPathComponent("a.md"))

            var cmd = try PrepareClaudeLaunchCommand.parse(["--account-dir", acctDir.path])
            try cmd.run()

            let fm = FileManager.default
            let dest = try fm.destinationOfSymbolicLink(
                atPath: acctDir.appendingPathComponent("skills").path)
            #expect(dest == wsDir.appendingPathComponent("skills").path)
            #expect(fm.fileExists(
                atPath: wsDir.appendingPathComponent("skills/a.md").path))
        }
    }
}

@Suite("v3.1 launch+capture round trip")
struct V31LaunchCaptureRoundTripTests {

    @Test("prepare → simulated claude mutation → capture preserves partitioning")
    func roundTrip() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)
            var pin = try PinCommand.parse(["alice", "--workspace", "team"])
            try pin.run()

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let wsDir = envStore.claudeWorkspaceDir(workspace: "team")

            // Seed initial state in both stores.
            try ClaudeJsonMerge.saveJSON(
                ["oauthAccount": ["emailAddress": "alice@x.com"], "numStartups": 1],
                at: ClaudeJsonMerge.identityFileURL(accountDir: acctDir))
            try ClaudeJsonMerge.saveJSON(
                ["projects": [:] as [String: Any], "tipsHistory": [:] as [String: Any]],
                at: ClaudeJsonMerge.sharedFileURL(workspaceDir: wsDir))

            // Step 1: prepare — merges stores into .claude.json.
            var prep = try PrepareClaudeLaunchCommand.parse(
                ["--account-dir", acctDir.path])
            try prep.run()

            // Step 2: simulate claude mutating .claude.json — bumps numStartups
            // (per-account) and adds a project entry (shared).
            let claudeJSONURL = acctDir.appendingPathComponent(".claude.json")
            var live = ClaudeJsonMerge.loadJSON(at: claudeJSONURL) ?? [:]
            live["numStartups"] = 2
            var projects = (live["projects"] as? [String: Any]) ?? [:]
            projects["/work/repo"] = ["allowedTools": ["bash"]]
            live["projects"] = projects
            try ClaudeJsonMerge.saveJSON(live, at: claudeJSONURL)

            // Step 3: capture — splits .claude.json back to the two stores.
            var cap = try CaptureClaudeExitCommand.parse(
                ["--account-dir", acctDir.path])
            try cap.run()

            // Verify partitioning: numStartups went to identity (per-account),
            // projects went to shared (workspace).
            let identity = ClaudeJsonMerge.loadJSON(
                at: ClaudeJsonMerge.identityFileURL(accountDir: acctDir))
            let shared = ClaudeJsonMerge.loadJSON(
                at: ClaudeJsonMerge.sharedFileURL(workspaceDir: wsDir))

            #expect(identity?["numStartups"] as? Int == 2,
                "per-account counter should land in identity store")
            #expect(identity?["projects"] == nil,
                "projects should NOT be in identity store")

            #expect((shared?["projects"] as? [String: Any])?["/work/repo"] != nil,
                "shared project should land in shared store")
            #expect(shared?["numStartups"] == nil,
                "numStartups should NOT be in shared store")
        }
    }

    @Test("two accounts pinned to same workspace see each other's shared changes after their prep")
    func crossAccountSharing() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            // Two accounts, both pinned to "team".
            let alice = Account(tool: .claude, displayName: "alice")
            let bob = Account(tool: .claude, displayName: "bob")
            try acctStore.save(alice)
            try acctStore.save(bob)
            try PinCommand.parse(["alice", "--workspace", "team"]).run()
            try PinCommand.parse(["bob", "--workspace", "team"]).run()

            let aliceDir = acctStore.accountDir(id: alice.id, tool: .claude)
            let bobDir = acctStore.accountDir(id: bob.id, tool: .claude)
            let wsDir = envStore.claudeWorkspaceDir(workspace: "team")

            // Alice runs (prep + simulated mutation + capture).
            try PrepareClaudeLaunchCommand.parse(["--account-dir", aliceDir.path]).run()
            var aliceClaudeJSON = ClaudeJsonMerge.loadJSON(
                at: aliceDir.appendingPathComponent(".claude.json")) ?? [:]
            aliceClaudeJSON["projects"] = ["/team/repo": ["k": "v"]]
            try ClaudeJsonMerge.saveJSON(aliceClaudeJSON,
                at: aliceDir.appendingPathComponent(".claude.json"))
            try CaptureClaudeExitCommand.parse(["--account-dir", aliceDir.path]).run()

            // Bob runs prep — should see alice's project in its merged view.
            try PrepareClaudeLaunchCommand.parse(["--account-dir", bobDir.path]).run()
            let bobClaudeJSON = ClaudeJsonMerge.loadJSON(
                at: bobDir.appendingPathComponent(".claude.json"))
            #expect((bobClaudeJSON?["projects"] as? [String: Any])?["/team/repo"] != nil,
                "bob's prep should pull in alice's shared project from team workspace")

            // Both accounts' identity stores remain separate.
            let aliceIdentity = ClaudeJsonMerge.loadJSON(
                at: ClaudeJsonMerge.identityFileURL(accountDir: aliceDir))
            let bobIdentity = ClaudeJsonMerge.loadJSON(
                at: ClaudeJsonMerge.identityFileURL(accountDir: bobDir))
            // Alice's identity exists (she captured). Bob's identity may be empty.
            #expect(aliceIdentity != nil)
            // Whatever was in bob's, projects MUST NOT be there.
            #expect(bobIdentity?["projects"] == nil)

            // Shared store visible from wsDir as before.
            let shared = ClaudeJsonMerge.loadJSON(
                at: ClaudeJsonMerge.sharedFileURL(workspaceDir: wsDir))
            #expect((shared?["projects"] as? [String: Any])?["/team/repo"] != nil)
        }
    }
}
