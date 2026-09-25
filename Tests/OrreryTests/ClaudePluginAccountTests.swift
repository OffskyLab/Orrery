import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

/// The first time a plugin owns something rather than answering about it.
///
/// Driven through the shipped `orrery-claude` binary, because an in-process
/// conformer would pass while the artifact was broken. What is being checked is
/// not only that the five methods work, but that the host got its answers
/// without knowing where anything lives: every path in this suite is a temporary
/// state directory handed to the plugin, and nothing here names `.claude`,
/// `accounts/` or `metadata.json`.
@Suite("ClaudePluginAccounts")
struct ClaudePluginAccountTests {

    private final class BundleMarker {}

    private var pluginURL: URL {
        Bundle(for: BundleMarker.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("orrery-claude")
    }

    /// A plugin with a state directory of its own, as orrery will spawn it.
    private func connect() async throws -> (any AIToolAccounts, StdioTransport, URL) {
        let state = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plugin-accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)

        let transport = StdioTransport(
            executable: pluginURL, arguments: [],
            environment: [PluginState.directoryEnvVar: state.path])
        let tool = try await RemoteAITool.connect(transport: transport, timeout: .seconds(5))
        let accounts = try #require(ToolCapability.accounts(of: tool),
                                    "the shipped plugin must advertise the account capability")
        return (accounts, transport, state)
    }

    @Test("the shipped binary advertises the account capability")
    func advertisesTheCapability() async throws {
        let (_, transport, _) = try await connect()
        await transport.terminate()
    }

    @Test("a fresh state directory holds no accounts, and that is not an error")
    func emptyPool() async throws {
        let (accounts, transport, _) = try await connect()
        defer { Task { await transport.terminate() } }
        #expect(try await accounts.list().isEmpty)
    }

    @Test("nothing pinned yet comes back as nil across the wire")
    func noCurrent() async throws {
        let (accounts, transport, _) = try await connect()
        defer { Task { await transport.terminate() } }
        _ = try await accounts.addAccount(id: "a1", name: "work")
        #expect(try await accounts.current() == nil)
    }

    @Test("adding an account makes it appear in the listing")
    func addThenList() async throws {
        let (accounts, transport, _) = try await connect()
        defer { Task { await transport.terminate() } }

        let created = try await accounts.addAccount(id: "a1", name: "work")
        #expect(created.id == "a1")
        #expect(created.name == "work")

        let listed = try await accounts.list()
        #expect(listed.map(\.id) == ["a1"])
    }

    /// The host names accounts; the plugin stores what it is given. If the plugin
    /// minted its own ids, the host would have nothing to refer to an account by
    /// until after creating one.
    @Test("the id and name the host chose are what come back")
    func hostNamesTheAccount() async throws {
        let (accounts, transport, _) = try await connect()
        defer { Task { await transport.terminate() } }
        let created = try await accounts.addAccount(id: "chosen-by-host", name: "a name")
        #expect(created.id == "chosen-by-host")
        #expect(created.name == "a name")
    }

    @Test("a listing comes back sorted by name, so rows do not move between runs")
    func listingIsStable() async throws {
        let (accounts, transport, _) = try await connect()
        defer { Task { await transport.terminate() } }
        _ = try await accounts.addAccount(id: "z", name: "alpha")
        _ = try await accounts.addAccount(id: "a", name: "zulu")
        #expect(try await accounts.list().map(\.name) == ["alpha", "zulu"])
    }

    @Test("pinning round-trips through the plugin's own storage")
    func setThenGetCurrent() async throws {
        let (accounts, transport, _) = try await connect()
        defer { Task { await transport.terminate() } }
        _ = try await accounts.addAccount(id: "a1", name: "work")
        _ = try await accounts.addAccount(id: "a2", name: "personal")
        try await accounts.setCurrent(id: "a2")
        #expect(try await accounts.current()?.id == "a2")
    }

    /// The pin must survive the process that recorded it, or `orrery use` would
    /// only hold for as long as one command ran.
    @Test("a pin outlives the plugin process")
    func pinPersists() async throws {
        let state = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plugin-accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)

        func session() async throws -> (any AIToolAccounts, StdioTransport) {
            let transport = StdioTransport(
                executable: pluginURL, arguments: [],
                environment: [PluginState.directoryEnvVar: state.path])
            let tool = try await RemoteAITool.connect(transport: transport, timeout: .seconds(5))
            return (try #require(ToolCapability.accounts(of: tool)), transport)
        }

        let (first, firstTransport) = try await session()
        _ = try await first.addAccount(id: "a1", name: "work")
        try await first.setCurrent(id: "a1")
        await firstTransport.terminate()

        let (second, secondTransport) = try await session()
        defer { Task { await secondTransport.terminate() } }
        #expect(try await second.current()?.id == "a1")
        #expect(try await second.list().map(\.id) == ["a1"])
    }

    @Test("adding over an existing id fails instead of quietly returning it")
    func duplicateAddFails() async throws {
        let (accounts, transport, _) = try await connect()
        defer { Task { await transport.terminate() } }
        _ = try await accounts.addAccount(id: "a1", name: "work")

        await #expect(throws: (any Error).self) {
            _ = try await accounts.addAccount(id: "a1", name: "again")
        }
        #expect(try await accounts.list().count == 1)
    }

    @Test("pinning an account that does not exist fails and leaves the pin alone")
    func pinUnknownFails() async throws {
        let (accounts, transport, _) = try await connect()
        defer { Task { await transport.terminate() } }
        _ = try await accounts.addAccount(id: "a1", name: "work")
        try await accounts.setCurrent(id: "a1")

        await #expect(throws: (any Error).self) {
            try await accounts.setCurrent(id: "ghost")
        }
        #expect(try await accounts.current()?.id == "a1")
    }

    @Test("deleting removes the account, and deleting again fails")
    func deleteAccount() async throws {
        let (accounts, transport, _) = try await connect()
        defer { Task { await transport.terminate() } }
        _ = try await accounts.addAccount(id: "a1", name: "work")

        try await accounts.deleteAccount(id: "a1")
        #expect(try await accounts.list().isEmpty)

        await #expect(throws: (any Error).self) {
            try await accounts.deleteAccount(id: "a1")
        }
    }

    /// Leaving `current()` naming a deleted account would have the host render a
    /// row for something that is gone.
    @Test("deleting the pinned account clears the pin")
    func deleteClearsPin() async throws {
        let (accounts, transport, _) = try await connect()
        defer { Task { await transport.terminate() } }
        _ = try await accounts.addAccount(id: "a1", name: "work")
        try await accounts.setCurrent(id: "a1")

        try await accounts.deleteAccount(id: "a1")
        #expect(try await accounts.current() == nil)
    }

    /// Deleting an account takes its config directory with it. The host does not
    /// know that directory exists, so nothing else is in a position to.
    @Test("an account's storage is created and removed with it")
    func storageFollowsTheAccount() async throws {
        let (accounts, transport, state) = try await connect()
        defer { Task { await transport.terminate() } }

        _ = try await accounts.addAccount(id: "a1", name: "work")
        let contentsAfterAdd = try FileManager.default
            .subpathsOfDirectory(atPath: state.path)
        #expect(!contentsAfterAdd.isEmpty, "adding an account must put something on disk")

        try await accounts.deleteAccount(id: "a1")
        let remaining = try FileManager.default
            .subpathsOfDirectory(atPath: state.path)
            .filter { $0.contains("a1") }
        #expect(remaining.isEmpty, "deleting an account must take its storage with it")
    }

    /// Without a state directory the plugin has nowhere to store anything, and
    /// must say so rather than picking a location — which on a developer's
    /// machine would be their real config.
    @Test("a plugin spawned with no state directory fails instead of guessing")
    func noStateDirectoryIsAnError() async throws {
        let transport = StdioTransport(
            executable: pluginURL, arguments: [],
            environment: [PluginState.directoryEnvVar: ""])
        let tool = try await RemoteAITool.connect(transport: transport, timeout: .seconds(5))
        defer { Task { await transport.terminate() } }
        let accounts = try #require(ToolCapability.accounts(of: tool))

        await #expect(throws: (any Error).self) {
            _ = try await accounts.list()
        }
    }
}
