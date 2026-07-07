import Foundation
import Testing
@testable import OrreryCore

@Suite("OriginAccountSeeder")
struct OriginAccountSeederTests {

    /// A fake keychain that reports NO claude login. Every test injects a fake so
    /// the seeder's claude branch never touches the real macOS login keychain
    /// (which is global — not isolated by ORRERY_HOME — so `.live` in a test
    /// would create stray `Claude Code-orrery-*` items in the developer's keychain).
    private let noClaudeLogin = KeychainAccess(
        itemExists: { _ in false }, copyItem: { _, _ in false })

    /// Simulate post-takeover state: a credential file sitting in the origin
    /// workspace's <tool> dir, and no origin account for that tool yet.
    private func seedWorkspaceCredential(tool: Tool, fileName: String, contents: String) throws {
        let ws = EnvironmentStore.default.originConfigDir(tool: tool)  // workspaces/origin/<tool>
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: ws.appendingPathComponent(fileName))
    }

    @Test("creates a codex origin account capturing auth.json from the workspace")
    func seedsCodex() throws {
        try withIsolatedHome {
            try seedWorkspaceCredential(tool: .codex, fileName: "auth.json", contents: #"{"OPENAI_API_KEY":"x"}"#)

            OriginAccountSeeder.seedOriginAccountsIfNeeded(keychain: noClaudeLogin)

            let acctStore = AccountStore.default
            let acct = try #require(try acctStore.findByDisplayName("origin", tool: .codex))
            #expect(FileManager.default.fileExists(
                atPath: acctStore.accountDir(id: acct.id, tool: .codex)
                    .appendingPathComponent("auth.json").path))
            #expect(EnvironmentStore.default.loadOriginWorkspace().account(for: .codex) == acct.id)
        }
    }

    @Test("creates a gemini origin account capturing oauth_creds.json")
    func seedsGemini() throws {
        try withIsolatedHome {
            try seedWorkspaceCredential(tool: .gemini, fileName: "oauth_creds.json", contents: #"{"access_token":"x"}"#)

            OriginAccountSeeder.seedOriginAccountsIfNeeded(keychain: noClaudeLogin)

            let acctStore = AccountStore.default
            let acct = try #require(try acctStore.findByDisplayName("origin", tool: .gemini))
            #expect(FileManager.default.fileExists(
                atPath: acctStore.accountDir(id: acct.id, tool: .gemini)
                    .appendingPathComponent("oauth_creds.json").path))
            #expect(EnvironmentStore.default.loadOriginWorkspace().account(for: .gemini) == acct.id)
        }
    }

    @Test("creates a claude origin account: pinned, link-only; keychain copied with correct services")
    func seedsClaude() throws {
        try withIsolatedHome {
            let envStore = EnvironmentStore.default
            let acctStore = AccountStore.default
            // Post-takeover: origin workspace claude dir exists (with a shared dir to mirror).
            let wsClaude = envStore.originConfigDir(tool: .claude)  // workspaces/origin/claude
            try FileManager.default.createDirectory(
                at: wsClaude.appendingPathComponent("plugins"), withIntermediateDirectories: true)

            // Recording fake: pretend the default login exists; capture copy calls.
            // Reference box so the @Sendable closure can record without a mutable capture.
            final class Rec: @unchecked Sendable { var calls: [(from: String, to: String)] = [] }
            let rec = Rec()
            let fake = KeychainAccess(
                itemExists: { _ in true },
                copyItem: { from, to in rec.calls.append((from, to)); return true })

            OriginAccountSeeder.seedOriginAccountsIfNeeded(keychain: fake)

            let acct = try #require(try acctStore.findByDisplayName("origin", tool: .claude))
            // pinned to origin
            #expect(envStore.loadOriginWorkspace().account(for: .claude) == acct.id)
            // migrateAccount ran: account mirrors the workspace (plugins is a symlink)
            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            #expect((try? FileManager.default.destinationOfSymbolicLink(
                atPath: acctDir.appendingPathComponent("plugins").path))
                == wsClaude.appendingPathComponent("plugins").path)
            // keychain copied from the default service to the per-account service
            #expect(rec.calls.count == 1)
            #expect(rec.calls.first?.from == ClaudeKeychain.service(for: nil))       // "Claude Code-credentials"
            #expect(rec.calls.first?.to == ClaudeKeychain.serviceName(forOrreryAccount: acct.id))
        }
    }

    @Test("no capturable login → no account created")
    func skipsWhenNoLogin() throws {
        try withIsolatedHome {
            OriginAccountSeeder.seedOriginAccountsIfNeeded(keychain: noClaudeLogin)
            let codexAcct = try AccountStore.default.findByDisplayName("origin", tool: .codex)
            let claudeAcct = try AccountStore.default.findByDisplayName("origin", tool: .claude)
            #expect(codexAcct == nil)
            #expect(claudeAcct == nil)
        }
    }

    @Test("existing origin account → no-op (idempotent, existing installs untouched)")
    func skipsWhenOriginAccountExists() throws {
        try withIsolatedHome {
            let envStore = EnvironmentStore.default
            let acctStore = AccountStore.default
            // Pre-existing origin codex account + pin.
            let existing = Account(tool: .codex, displayName: "origin")
            try acctStore.save(existing)
            var origin = envStore.loadOriginWorkspace()
            origin.setAccount(existing.id, for: .codex)
            try envStore.saveOriginWorkspace(origin)
            // A workspace credential is present, but the pin already exists.
            let ws = envStore.originConfigDir(tool: .codex)
            try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: ws.appendingPathComponent("auth.json"))

            OriginAccountSeeder.seedOriginAccountsIfNeeded(keychain: noClaudeLogin)

            let count = try acctStore.list(tool: .codex).count
            #expect(count == 1)
            #expect(envStore.loadOriginWorkspace().account(for: .codex) == existing.id)
        }
    }

    @Test("running twice creates the account only once")
    func idempotentAcrossRuns() throws {
        try withIsolatedHome {
            let ws = EnvironmentStore.default.originConfigDir(tool: .codex)
            try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: ws.appendingPathComponent("auth.json"))

            OriginAccountSeeder.seedOriginAccountsIfNeeded(keychain: noClaudeLogin)
            OriginAccountSeeder.seedOriginAccountsIfNeeded(keychain: noClaudeLogin)

            let count = try AccountStore.default.list(tool: .codex).count
            #expect(count == 1)
        }
    }
}
