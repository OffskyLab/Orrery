import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

/// orrery handing each plugin a directory of its own.
///
/// The claim being pinned is a separation: orrery supplies the root — because a
/// plugin that derived its own home would read the developer's real config during
/// an isolated run — and then does not look inside it. So these check that the
/// plugin *received* somewhere to write and that the directories are separate,
/// never what a plugin put in one.
///
/// ## Why the binary is pinned by environment variable
///
/// `PluginDiscovery.locate` searches an env var, then `$ORRERY_HOME/tools`, then
/// `PATH`. Supplying only `PATH` is not enough: on any machine with orrery
/// installed, `~/.orrery/tools/orrery-claude` wins and the suite silently tests
/// *that* build. It happened while writing this file — the installed plugin was
/// weeks old and advertised `tool/describe` alone, so the capability under test
/// was simply absent and the failure pointed at the wrong thing.
///
/// The other plugin suites drive `StdioTransport` directly and never reach
/// `locate`, which is why none of them caught it.
@Suite("PluginStateDirectory")
struct PluginStateDirectoryTests {

    private final class BundleMarker {}

    private var pluginURL: URL {
        Bundle(for: BundleMarker.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("orrery-claude")
    }

    /// The environment that makes discovery find the binary just built, and
    /// nothing else on this machine.
    private var pinnedEnvironment: [String: String] {
        [PluginDiscovery.envVarName(toolID: "claude"): pluginURL.path]
    }

    private func makeRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plugin-state-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func register(stateRoot: URL) async throws -> any AIToolAccounts {
        let registry = AIToolRegistry()
        await AIToolRegistration.registerPlugins(
            into: registry,
            toolIDs: ["claude"],
            timeout: .seconds(5),
            environment: pinnedEnvironment,
            stateRoot: stateRoot,
            warn: { _ in })
        let tool = try #require(registry.tool(id: "claude"))
        return try #require(ToolCapability.accounts(of: tool))
    }

    /// A plugin registered through the real path must come back able to store
    /// things. Before the state directory was passed, `environment` was `[:]` and
    /// every account call failed — which registration itself would not have
    /// revealed, because it succeeds either way.
    @Test("a registered plugin can store accounts, so it was given somewhere to")
    func registrationSuppliesAStateDirectory() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let accounts = try await register(stateRoot: root)

        // Succeeding at all is the assertion: given no state directory the plugin
        // refuses rather than choosing a location itself.
        _ = try await accounts.addAccount(id: "a1", name: "work")
        #expect(try await accounts.list().map(\.id) == ["a1"])
    }

    /// Checked through the plugin rather than by looking for a directory. The
    /// directory is created before the process is spawned, so its existence would
    /// hold even if nothing were handed over; what distinguishes the two is that
    /// an account stored under one root does not appear under another.
    @Test("storage is per state directory, so two plugins cannot collide")
    func storageIsSeparate() async throws {
        let root = try makeRoot()
        let otherRoot = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: otherRoot)
        }

        let first = try await register(stateRoot: root)
        _ = try await first.addAccount(id: "a1", name: "work")

        let second = try await register(stateRoot: otherRoot)
        #expect(try await second.list().isEmpty)
        #expect(try await first.list().map(\.id) == ["a1"])
    }

    @Test("the directory handed over is named for the plugin")
    func directoryIsNamedForThePlugin() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let accounts = try await register(stateRoot: root)
        _ = try await accounts.addAccount(id: "a1", name: "work")

        // Asserted after a write, so this is the directory the plugin actually
        // used rather than one orrery created and nobody wrote to.
        let claudeDir = root.appendingPathComponent("claude")
        let contents = try FileManager.default.subpathsOfDirectory(atPath: claudeDir.path)
        #expect(!contents.isEmpty)
    }
}
