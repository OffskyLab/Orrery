import Foundation
import Testing
@testable import OrreryCore

@Suite("OriginAccountSeeder")
struct OriginAccountSeederTests {

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

            OriginAccountSeeder.seedOriginAccountsIfNeeded()

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

            OriginAccountSeeder.seedOriginAccountsIfNeeded()

            let acctStore = AccountStore.default
            let acct = try #require(try acctStore.findByDisplayName("origin", tool: .gemini))
            #expect(FileManager.default.fileExists(
                atPath: acctStore.accountDir(id: acct.id, tool: .gemini)
                    .appendingPathComponent("oauth_creds.json").path))
            #expect(EnvironmentStore.default.loadOriginWorkspace().account(for: .gemini) == acct.id)
        }
    }
}
