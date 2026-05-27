import Foundation
import Testing
import ArgumentParser
@testable import OrreryCore

@Suite("PinCommand")
struct PinCommandTests {
    @Test("pins account to a freshly named workspace, sets workspace + creates symlinks")
    func pinsToFreshWorkspace() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)

            let cmd = try PinCommand.parse(["alice", "--workspace", "work"])
            try cmd.run()

            let reloaded = try acctStore.load(id: acct.id, tool: .claude)
            #expect(reloaded.workspace == "work")

            let status = ClaudeAccountDirectory.verifySymlinks(
                account: reloaded, accountStore: acctStore, environmentStore: envStore)
            #expect(status == .ok)
        }
    }

    @Test("repointing a previously pinned account updates symlinks")
    func repointsAccount() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)

            // Pin once to origin
            let first = try PinCommand.parse(["alice", "--workspace", "origin"])
            try first.run()

            // Pin again to work
            let second = try PinCommand.parse(["alice", "--workspace", "work"])
            try second.run()

            let reloaded = try acctStore.load(id: acct.id, tool: .claude)
            #expect(reloaded.workspace == "work")
            #expect(ClaudeAccountDirectory.verifySymlinks(
                account: reloaded, accountStore: acctStore, environmentStore: envStore) == .ok)
        }
    }

    @Test("unknown account throws ValidationError")
    func unknownAccount() throws {
        try withIsolatedHome {
            let cmd = try PinCommand.parse(["no-such-acct", "--workspace", "origin"])
            #expect(throws: (any Error).self) {
                try cmd.run()
            }
        }
    }

    @Test("requires accountName argument — missing throws parse error")
    func requiresAccountNameArgument() throws {
        // ArgumentParser surfaces missing required args as a parse error.
        // We expect parse to throw, not a runtime nil-find error.
        #expect(throws: (any Error).self) {
            _ = try PinCommand.parse(["--workspace", "work"])
        }
    }

    @Test("rejects multiple tool flags with ValidationError")
    func rejectsMultipleToolFlags() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)

            let cmd = try PinCommand.parse(["alice", "--workspace", "origin", "--claude", "--codex"])
            #expect(throws: ValidationError.self) {
                try cmd.run()
            }
        }
    }
}

@Suite("PinCommand integration")
struct PinCommandIntegrationTests {
    @Test("pin produces complete v3.1 account dir layout")
    func endToEndLayout() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)

            // Use the public parse(...).run() entry point like other tests.
            var cmd = try PinCommand.parse(
                ["alice", "--workspace", "shared-team"])
            try cmd.run()

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let wsDir = envStore.claudeWorkspaceDir(workspace: "shared-team")
            let fm = FileManager.default

            // Account dir exists.
            #expect(fm.fileExists(atPath: acctDir.path))

            // Workspace dir + 5 subdirs exist.
            #expect(fm.fileExists(atPath: wsDir.path))
            for sub in ClaudeAccountDirectory.sharedSubdirs {
                #expect(fm.fileExists(atPath: wsDir.appendingPathComponent(sub).path),
                    "missing workspace subdir: \(sub)")
            }

            // 5 symlinks in account dir, each pointing at the right workspace subdir.
            for sub in ClaudeAccountDirectory.sharedSubdirs {
                let linkPath = acctDir.appendingPathComponent(sub).path
                let dest = try fm.destinationOfSymbolicLink(atPath: linkPath)
                #expect(dest == wsDir.appendingPathComponent(sub).path,
                    "symlink for \(sub) points to wrong target")
            }

            // metadata.json on disk has workspace = "shared-team".
            let metadataURL = acctDir.appendingPathComponent("metadata.json")
            let data = try Data(contentsOf: metadataURL)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(json?["workspace"] as? String == "shared-team")

            // Two accounts pinned to the same workspace share the same symlink targets.
            let bob = Account(tool: .claude, displayName: "bob")
            try acctStore.save(bob)
            var cmd2 = try PinCommand.parse(
                ["bob", "--workspace", "shared-team"])
            try cmd2.run()

            let bobDir = acctStore.accountDir(id: bob.id, tool: .claude)
            for sub in ClaudeAccountDirectory.sharedSubdirs {
                let aliceLink = try fm.destinationOfSymbolicLink(
                    atPath: acctDir.appendingPathComponent(sub).path)
                let bobLink = try fm.destinationOfSymbolicLink(
                    atPath: bobDir.appendingPathComponent(sub).path)
                #expect(aliceLink == bobLink, "alice and bob's \(sub) symlinks should match")
            }
        }
    }
}
