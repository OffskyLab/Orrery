import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

/// The second tool to implement the protocol, and the point of it.
///
/// The protocol was designed while looking at claude. Until something else
/// implements it, "a third party could do this" rests on one example — the one
/// the design was fitted to. Codex is a useful second case because it is
/// *unlike* claude: one file instead of a platform keychain, identity inside a
/// JWT instead of a JSON field, and an API-key mode with no identity at all.
///
/// Driven through the real binary, like `ClaudePluginIdentityTests`: what is
/// being checked is that the shipped artifact answers, not that a conformer
/// built in-process does.
@Suite("CodexPlugin")
struct CodexPluginTests {

    private final class BundleMarker {}

    private var pluginURL: URL {
        Bundle(for: BundleMarker.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("orrery-codex")
    }

    private func connect() async throws -> (any AITool, StdioTransport) {
        let transport = StdioTransport(executable: pluginURL, arguments: [], environment: [:])
        let tool = try await RemoteAITool.connect(transport: transport, timeout: .seconds(5))
        return (tool, transport)
    }

    private func makeDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A JWT whose payload is `claims`. Only the payload segment is read, so the
    /// header and signature are placeholders — codex never verifies them here
    /// and neither does the host it replaces.
    private func jwt(_ claims: [String: Any]) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: claims)
        var b64 = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while b64.hasSuffix("=") { b64.removeLast() }   // JWTs are unpadded
        return "header.\(b64).signature"
    }

    private func writeOAuthAuth(_ dir: URL, email: String, plan: String?) throws {
        var claims: [String: Any] = ["email": email]
        if let plan {
            claims["https://api.openai.com/auth"] = ["chatgpt_plan_type": plan]
        }
        let auth: [String: Any] = ["tokens": ["id_token": try jwt(claims)]]
        try JSONSerialization.data(withJSONObject: auth)
            .write(to: dir.appendingPathComponent("auth.json"))
    }

    // MARK: - Description

    /// The plugin must describe codex exactly as the enum does, for the same
    /// reason `ClaudePluginParityTests` exists: a disagreement here sends the
    /// host at the wrong config directory, and that is not a thing a user should
    /// discover.
    @Test("the plugin describes codex exactly as the built-in bridge does")
    func describesCodexLikeTheBridge() async throws {
        let (remote, transport) = try await connect()
        defer { Task { await transport.terminate() } }
        let local = Tool.codex.aiTool

        #expect(remote.id == local.id)
        #expect(remote.displayName == local.displayName)
        #expect(remote.configDirectoryName == local.configDirectoryName)
        #expect(remote.configDirEnvVar == local.configDirEnvVar)
        #expect(remote.authLoginCommand == local.authLoginCommand)
        #expect(remote.installCommand == local.installCommand)
        #expect(remote.sessionSubdirectories == local.sessionSubdirectories)
        #expect(remote.ansiColor == local.ansiColor)
    }

    @Test("the plugin advertises that it can report identities")
    func advertisesIdentityReporting() async throws {
        let (tool, transport) = try await connect()
        defer { Task { await transport.terminate() } }

        #expect(ToolCapability.identityReporting(of: tool) != nil)
    }

    // MARK: - Identity

    @Test("an OAuth login answers with the email and plan from its token")
    func readsOAuthIdentity() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeOAuthAuth(dir, email: "dev@example.com", plan: "plus")

        let (tool, transport) = try await connect()
        defer { Task { await transport.terminate() } }
        let reporter = try #require(ToolCapability.identityReporting(of: tool))

        let identity = try await reporter.showIdentity(in: dir)

        #expect(identity?.email == "dev@example.com")
        #expect(identity?.plan == "plus")
    }

    /// The case claude does not have, and the reason codex is a good second
    /// implementation: an API-key login has no email at all. That is a real
    /// identity — the account exists and is usable — so it must not read as
    /// "nothing here".
    @Test("an API-key login reports its mode, not an absent identity")
    func readsAPIKeyIdentity() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let auth: [String: Any] = ["auth_mode": "api", "OPENAI_API_KEY": "sk-test"]
        try JSONSerialization.data(withJSONObject: auth)
            .write(to: dir.appendingPathComponent("auth.json"))

        let (tool, transport) = try await connect()
        defer { Task { await transport.terminate() } }
        let reporter = try #require(ToolCapability.identityReporting(of: tool))

        let identity = try await reporter.showIdentity(in: dir)

        #expect(identity?.plan == "api key")
        #expect(identity?.email == nil, "an API key carries no email, and inventing one would be worse")
    }

    @Test("a token with an email but no plan answers with just the email")
    func readsIdentityWithoutPlan() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeOAuthAuth(dir, email: "noplan@example.com", plan: nil)

        let (tool, transport) = try await connect()
        defer { Task { await transport.terminate() } }
        let reporter = try #require(ToolCapability.identityReporting(of: tool))

        let identity = try await reporter.showIdentity(in: dir)

        #expect(identity?.email == "noplan@example.com")
        #expect(identity?.plan == nil)
    }

    @Test("a directory with no auth file answers nil")
    func absentAuthIsNil() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (tool, transport) = try await connect()
        defer { Task { await transport.terminate() } }
        let reporter = try #require(ToolCapability.identityReporting(of: tool))

        #expect(try await reporter.showIdentity(in: dir) == nil)
    }

    /// Codex writes this file itself, so a malformed one means a partial write
    /// or a version this build does not understand. Either way it is not an
    /// identity, and it must not take the plugin down — one unreadable account
    /// would otherwise cost the listing every other row.
    @Test("an unreadable auth file answers nil rather than failing")
    func malformedAuthIsNil() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("auth.json"))

        let (tool, transport) = try await connect()
        defer { Task { await transport.terminate() } }
        let reporter = try #require(ToolCapability.identityReporting(of: tool))

        #expect(try await reporter.showIdentity(in: dir) == nil)
    }

    @Test("a listing answers every directory positionally, gaps in place")
    func listingIsPositional() async throws {
        let a = try makeDir(), b = try makeDir(), c = try makeDir()
        defer { for d in [a, b, c] { try? FileManager.default.removeItem(at: d) } }
        try writeOAuthAuth(a, email: "a@example.com", plan: "pro")
        try writeOAuthAuth(c, email: "c@example.com", plan: "free")

        let (tool, transport) = try await connect()
        defer { Task { await transport.terminate() } }
        let reporter = try #require(ToolCapability.identityReporting(of: tool))

        let found = try await reporter.listIdentities(in: [a, b, c])

        #expect(found.count == 3)
        #expect(found[0]?.email == "a@example.com")
        #expect(found[1] == nil)
        #expect(found[2]?.email == "c@example.com")
    }

    /// The duplication guard, as for claude: the host still reads codex's
    /// `auth.json` for `Account.refreshInfo`, so two readers of one format
    /// exist until that call site moves. They are pinned rather than trusted.
    @Test("the plugin and the host agree about the same directory")
    func pluginMatchesHost() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let store = AccountStore(homeURL: home)
        let account = Account(tool: .codex, displayName: "acct", workspace: "origin")
        try store.save(account)
        let dir = store.accountDir(id: account.id, tool: .codex)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeOAuthAuth(dir, email: "parity@example.com", plan: "pro")

        let (tool, transport) = try await connect()
        defer { Task { await transport.terminate() } }
        let reporter = try #require(ToolCapability.identityReporting(of: tool))

        let fromPlugin = try await reporter.showIdentity(in: dir)
        let fromHost = ToolAuth.accountInfo(forPoolAccount: account, accountStore: store)

        #expect(fromPlugin?.email == fromHost.email)
        #expect(fromPlugin?.plan == fromHost.plan)
    }
}
