import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

/// The one place that knows whether a tool's accounts come from its plugin.
///
/// What these pin is that the two paths are indistinguishable to a caller, and
/// that the plugin path does not fall back. A fallback is the failure worth
/// guarding against here: it would make the plugin unobservable — deleting
/// `orrery-claude` and having everything keep working exactly as before is
/// indistinguishable from never having asked it.
@Suite("AccountListing")
struct AccountListingTests {

    private final class BundleMarker {}

    private var pluginURL: URL {
        Bundle(for: BundleMarker.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("orrery-claude")
    }

    private func makeHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("account-listing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A registry holding the real claude plugin, pointed at a state directory
    /// of its own.
    ///
    /// The binary is pinned by env var: `PluginDiscovery.locate` would otherwise
    /// prefer `~/.orrery/tools/orrery-claude`, and on a machine with orrery
    /// installed the suite would silently exercise that build instead.
    private func registryWithPlugin(stateRoot: URL) async -> AIToolRegistry {
        let registry = AIToolRegistry()
        await AIToolRegistration.registerPlugins(
            into: registry,
            toolIDs: ["claude"],
            timeout: .seconds(5),
            environment: [PluginDiscovery.envVarName(toolID: "claude"): pluginURL.path],
            stateRoot: stateRoot,
            warn: { _ in })
        return registry
    }

    @Test("a tool whose plugin owns its accounts is answered by the plugin")
    func pluginOwnedToolIsAsked() async throws {
        let home = try makeHome()
        let stateRoot = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: stateRoot)
        }

        let registry = await registryWithPlugin(stateRoot: stateRoot)
        let listing = AccountListing(store: AccountStore(homeURL: home), registry: registry)
        #expect(listing.isPluginOwned(.claude))

        let claude = try #require(registry.tool(id: "claude"))
        let accounts = try #require(ToolCapability.accounts(of: claude))
        _ = try await accounts.addAccount(id: "a1", name: "work")

        let rows = try await listing.rows(for: .claude, liveAccountID: nil)
        #expect(rows.map(\.id) == ["a1"])
        #expect(rows.map(\.displayName) == ["work"])
    }

    /// The account exists only in the plugin's storage, and orrery's own pool is
    /// empty — so a row coming back proves the answer was not read locally.
    @Test("the plugin's accounts are returned even though orrery's pool is empty")
    func poolIsNotConsultedForAPluginOwnedTool() async throws {
        let home = try makeHome()
        let stateRoot = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: stateRoot)
        }

        let registry = await registryWithPlugin(stateRoot: stateRoot)
        let store = AccountStore(homeURL: home)
        let claude = try #require(registry.tool(id: "claude"))
        let accounts = try #require(ToolCapability.accounts(of: claude))
        _ = try await accounts.addAccount(id: "only-in-plugin", name: "work")

        #expect(try store.list(tool: .claude).isEmpty, "orrery's own pool must be untouched")

        let listing = AccountListing(store: store, registry: registry)
        let rows = try await listing.rows(for: .claude, liveAccountID: nil)
        #expect(rows.map(\.id) == ["only-in-plugin"])
    }

    /// An account in orrery's pool must **not** appear for a plugin-owned tool.
    /// If it did, the host would be merging its own records into the plugin's
    /// answer, which is the second copy of the truth this whole change removes.
    @Test("orrery's own records do not leak into a plugin-owned tool's listing")
    func storeDoesNotShadowThePlugin() async throws {
        let home = try makeHome()
        let stateRoot = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: stateRoot)
        }

        let store = AccountStore(homeURL: home)
        try store.save(OrreryCore.Account(
            tool: .claude, displayName: "left-over", workspace: "origin"))

        let registry = await registryWithPlugin(stateRoot: stateRoot)
        let listing = AccountListing(store: store, registry: registry)

        let rows = try await listing.rows(for: .claude, liveAccountID: nil)
        #expect(rows.isEmpty, "the plugin holds no accounts, so neither does the listing")
    }

    /// A tool with no plugin still works, out of orrery's pool. This is the path
    /// codex and gemini take until codex is reimplemented and gemini returns.
    @Test("a tool without a plugin is read from orrery's pool")
    func toolWithoutPluginUsesTheStore() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let store = AccountStore(homeURL: home)
        let account = OrreryCore.Account(
            tool: .codex, displayName: "work", workspace: "origin")
        try store.save(account)

        // An empty registry: no plugin for any tool.
        let listing = AccountListing(store: store, registry: AIToolRegistry())
        #expect(!listing.isPluginOwned(.codex))

        let rows = try await listing.rows(for: .codex, liveAccountID: nil)
        #expect(rows.map(\.displayName) == ["work"])
        #expect(rows.map(\.id) == [account.id])
    }

    @Test("no accounts is an empty listing on either path")
    func emptyOnBothPaths() async throws {
        let home = try makeHome()
        let stateRoot = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: stateRoot)
        }

        let store = AccountStore(homeURL: home)
        let registry = await registryWithPlugin(stateRoot: stateRoot)

        #expect(try await AccountListing(store: store, registry: registry)
            .rows(for: .claude, liveAccountID: nil).isEmpty)
        #expect(try await AccountListing(store: store, registry: AIToolRegistry())
            .rows(for: .codex, liveAccountID: nil).isEmpty)
    }

    @Test("a detail row comes back for an account the plugin holds")
    func detailRowFromPlugin() async throws {
        let home = try makeHome()
        let stateRoot = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: stateRoot)
        }

        let registry = await registryWithPlugin(stateRoot: stateRoot)
        let claude = try #require(registry.tool(id: "claude"))
        let accounts = try #require(ToolCapability.accounts(of: claude))
        _ = try await accounts.addAccount(id: "a1", name: "work")

        let listing = AccountListing(store: AccountStore(homeURL: home), registry: registry)
        let row = try await listing.row(for: .claude, id: "a1", isLiveInThisShell: false)
        #expect(row?.displayName == "work")

        #expect(try await listing.row(
            for: .claude, id: "nope", isLiveInThisShell: false) == nil)
    }
}
