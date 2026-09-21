import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

/// The first capability the plugin *performs* rather than describes, and the
/// first time the whole chain runs end to end: orrery asks, a separate process
/// reads claude's own records, the answer comes back over a pipe.
///
/// Driven through the real binary rather than a conformer built in-process. The
/// point is that the shipped artifact answers — an in-process double would pass
/// while the binary was broken, which is exactly the gap
/// `ClaudePluginParityTests` was written to close for the description.
@Suite("ClaudePluginIdentity")
struct ClaudePluginIdentityTests {

    private final class BundleMarker {}

    private var pluginURL: URL {
        Bundle(for: BundleMarker.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("orrery-claude")
    }

    private func connect() async throws -> (any AITool, StdioTransport) {
        let transport = StdioTransport(executable: pluginURL, arguments: [], environment: [:])
        let tool = try await RemoteAITool.connect(transport: transport, timeout: .seconds(5))
        return (tool, transport)
    }

    private func makeDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plugin-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// What claude writes into a live config directory.
    private func writeClaudeJSON(_ dir: URL, email: String) throws {
        let json: [String: Any] = ["oauthAccount": ["emailAddress": email]]
        try JSONSerialization.data(withJSONObject: json)
            .write(to: dir.appendingPathComponent(".claude.json"))
    }

    /// What orrery persists into a pooled account directory.
    private func writeIdentityFile(_ dir: URL, email: String, plan: String) throws {
        let json: [String: Any] = [
            "oauthAccount": ["emailAddress": email, "subscriptionType": plan],
        ]
        try JSONSerialization.data(withJSONObject: json)
            .write(to: dir.appendingPathComponent("claude-identity.json"))
    }

    @Test("the plugin advertises that it can report identities")
    func advertisesTheCapability() async throws {
        let (tool, transport) = try await connect()
        defer { Task { await transport.terminate() } }

        #expect(ToolCapability.identityReporting(of: tool) != nil,
                "orrery decides whether to ask by this; a plugin that can answer must say so")
    }

    @Test("a pooled account directory answers with the persisted identity")
    func readsPersistedIdentity() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeIdentityFile(dir, email: "pooled@example.com", plan: "Max")

        let (tool, transport) = try await connect()
        defer { Task { await transport.terminate() } }
        let reporter = try #require(ToolCapability.identityReporting(of: tool))

        let identity = try await reporter.showIdentity(in: dir)

        #expect(identity?.email == "pooled@example.com")
        #expect(identity?.plan == "Max")
    }

    @Test("a live config directory answers from the file claude itself writes")
    func readsLiveClaudeJSON() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeClaudeJSON(dir, email: "live@example.com")

        let (tool, transport) = try await connect()
        defer { Task { await transport.terminate() } }
        let reporter = try #require(ToolCapability.identityReporting(of: tool))

        #expect(try await reporter.showIdentity(in: dir)?.email == "live@example.com")
    }

    /// Both files can be present — a pooled directory that has also been used
    /// live. The persisted record is orrery's own snapshot and the one claude
    /// keeps current is `.claude.json`, so the fresher of the two wins.
    @Test("when both records exist the detail view prefers what claude wrote")
    func liveRecordWinsForDetail() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeIdentityFile(dir, email: "stale@example.com", plan: "Pro")
        try writeClaudeJSON(dir, email: "current@example.com")

        let (tool, transport) = try await connect()
        defer { Task { await transport.terminate() } }
        let reporter = try #require(ToolCapability.identityReporting(of: tool))

        let identity = try await reporter.showIdentity(in: dir)

        #expect(identity?.email == "current@example.com")
        // The plan still comes from the persisted record — `.claude.json` does
        // not carry one, and a missing field must not erase a known one.
        #expect(identity?.plan == "Pro")
    }

    @Test("a directory with no claude records answers nil, not empty fields")
    func absentIdentityIsNil() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (tool, transport) = try await connect()
        defer { Task { await transport.terminate() } }
        let reporter = try #require(ToolCapability.identityReporting(of: tool))

        #expect(try await reporter.showIdentity(in: dir) == nil,
                "nil means 'no login here'; an all-nil identity would mean 'logged in, cannot say who'")
    }

    @Test("a listing answers every directory positionally, gaps in place")
    func listingIsPositional() async throws {
        let a = try makeDir(), b = try makeDir(), c = try makeDir()
        defer { for d in [a, b, c] { try? FileManager.default.removeItem(at: d) } }
        try writeIdentityFile(a, email: "a@example.com", plan: "Pro")
        // b deliberately left empty
        try writeIdentityFile(c, email: "c@example.com", plan: "Max")

        let (tool, transport) = try await connect()
        defer { Task { await transport.terminate() } }
        let reporter = try #require(ToolCapability.identityReporting(of: tool))

        let found = try await reporter.listIdentities(in: [a, b, c])

        #expect(found.count == 3)
        #expect(found[0]?.email == "a@example.com")
        #expect(found[1] == nil, "the gap must stay in place or every later row is mispaired")
        #expect(found[2]?.email == "c@example.com")
    }

    /// The duplication guard.
    ///
    /// The plugin reads claude's identity records with its own code, while
    /// `ClaudeKeychain` in the host still reads them for ten other call sites.
    /// Two implementations of one format drift — that is what `ToolFlow`'s own
    /// comment warns about — so this pins them together until the host's copy
    /// goes. If the plugin and the host ever disagree about the same directory,
    /// this goes red rather than a user seeing the wrong account.
    @Test("the plugin and the host agree about the same directory")
    func pluginMatchesHost() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeClaudeJSON(dir, email: "parity@example.com")

        let (tool, transport) = try await connect()
        defer { Task { await transport.terminate() } }
        let reporter = try #require(ToolCapability.identityReporting(of: tool))

        let fromPlugin = try await reporter.showIdentity(in: dir)
        let fromHost = ClaudeKeychain.accountInfo(for: dir.path)

        #expect(fromPlugin?.email == fromHost.email)
    }

    /// The other half of the duplication, and the half a functional test would
    /// miss: both sides derive claude's Keychain service name themselves, and
    /// that derivation only shows up in an answer when a real credential is
    /// stored under it. Nothing in the suite stores one, so the two could
    /// disagree completely and every test above would still pass.
    ///
    /// Compared here directly. A drift means the plugin reads a Keychain item
    /// nobody wrote and reports no plan at all — silently, and only on the
    /// machines that actually have a credential.
    @Test("the plugin derives claude's credential service name exactly as the host does")
    func serviceNameMatchesHost() throws {
        #if os(macOS)
        // Several shapes, because the derivation hashes the path: a trailing
        // component, a space, and a composed character each change the bytes.
        for path in ["/tmp/a", "/tmp/with space", "/tmp/café", NSTemporaryDirectory()] {
            let dir = URL(fileURLWithPath: path)
            #expect(pluginServiceName(for: dir) == ClaudeKeychain.service(for: dir.path),
                    "plugin and host disagree about the service name for \(path)")
        }
        #endif
    }

    /// Asks the shipped binary what it derives, through the diagnostic entry
    /// point it exposes for exactly this. Driving the real artifact rather than
    /// re-deriving here: a copy of the algorithm in the test would agree with
    /// itself forever and pin nothing.
    private func pluginServiceName(for dir: URL) -> String? {
        let process = Process()
        process.executableURL = pluginURL
        process.arguments = ["--keychain-service", dir.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
