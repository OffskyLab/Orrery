import Foundation
import Testing
@testable import OrreryCore

/// What orrery installed, as a recorded fact.
///
/// The rule under test is the one that makes deleting the `Tool` enum possible:
/// the set of tools comes from something orrery decided and wrote down, never
/// from looking at the filesystem to see what might be there. So the tests care
/// as much about what the config does *not* do — no scanning, no forgetting — as
/// about round-tripping.
@Suite("PluginRegistryConfig")
struct PluginRegistryConfigTests {

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// A real executable, because availability is decided by stat-ing the path.
    private func makeBinary(in home: URL, named name: String) throws -> URL {
        let tools = home.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let url = tools.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("a fresh install has registered nothing, and that is not an error")
    func emptyByDefault() throws {
        let config = PluginRegistryConfig(homeURL: try makeHome())
        #expect(try config.entries().isEmpty)
    }

    @Test("a registration round-trips through the file")
    func roundTrip() throws {
        let home = try makeHome()
        let binary = try makeBinary(in: home, named: "orrery-claude")
        let config = PluginRegistryConfig(homeURL: home)

        try config.register(id: "claude", binaryPath: binary,
                            capabilities: ["tool/describe", "tool/list"])

        let entries = try config.entries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.id == "claude")
        #expect(entry.binaryPath == binary)
        #expect(entry.capabilities == ["tool/describe", "tool/list"])
    }

    /// The config records *capabilities*, not mere presence, so orrery can answer
    /// "can this tool do X" without spawning it.
    @Test("capabilities are recorded, so presence is not the only thing known")
    func recordsCapabilities() throws {
        let home = try makeHome()
        let binary = try makeBinary(in: home, named: "orrery-claude")
        let config = PluginRegistryConfig(homeURL: home)
        try config.register(id: "claude", binaryPath: binary,
                            capabilities: ["tool/describe", "tool/addAccount"])

        let entry = try #require(try config.entries().first)
        #expect(entry.can("tool/addAccount"))
        #expect(!entry.can("tool/deleteAccount"))
    }

    @Test("re-registering the same id replaces it rather than duplicating")
    func registerIsIdempotent() throws {
        let home = try makeHome()
        let binary = try makeBinary(in: home, named: "orrery-claude")
        let config = PluginRegistryConfig(homeURL: home)

        try config.register(id: "claude", binaryPath: binary, capabilities: ["tool/describe"])
        try config.register(id: "claude", binaryPath: binary,
                            capabilities: ["tool/describe", "tool/list"])

        let entries = try config.entries()
        #expect(entries.count == 1)
        #expect(try #require(entries.first).capabilities.contains("tool/list"))
    }

    @Test("several plugins coexist, and the ids come back")
    func severalPlugins() throws {
        let home = try makeHome()
        let claude = try makeBinary(in: home, named: "orrery-claude")
        let codex = try makeBinary(in: home, named: "orrery-codex")
        let config = PluginRegistryConfig(homeURL: home)

        try config.register(id: "claude", binaryPath: claude, capabilities: ["tool/describe"])
        try config.register(id: "codex", binaryPath: codex, capabilities: ["tool/describe"])

        #expect(Set(try config.entries().map(\.id)) == ["claude", "codex"])
    }

    @Test("a registered plugin whose binary is present is available")
    func availableWhenPresent() throws {
        let home = try makeHome()
        let binary = try makeBinary(in: home, named: "orrery-claude")
        let config = PluginRegistryConfig(homeURL: home)
        try config.register(id: "claude", binaryPath: binary, capabilities: [])

        #expect(try #require(try config.entries().first).isAvailable)
    }

    /// A vanished binary is marked, never forgotten. "Never installed" and
    /// "installed, then something removed it" are different situations with
    /// different fixes, and deleting the entry would collapse them into a
    /// message the user cannot act on.
    @Test("a vanished binary marks the entry unavailable and keeps it")
    func vanishedBinaryIsMarkedNotForgotten() throws {
        let home = try makeHome()
        let binary = try makeBinary(in: home, named: "orrery-claude")
        let config = PluginRegistryConfig(homeURL: home)
        try config.register(id: "claude", binaryPath: binary, capabilities: ["tool/describe"])

        try FileManager.default.removeItem(at: binary)

        let entries = try config.entries()
        #expect(entries.count == 1, "the entry must survive its binary")
        let entry = try #require(entries.first)
        #expect(entry.id == "claude")
        #expect(!entry.isAvailable)
        #expect(entry.capabilities == ["tool/describe"],
                "what it could do is still recorded — the binary went, the fact did not")
    }

    /// The whole point of the config. A binary sitting in the tools directory
    /// that was never registered must not appear: what is installed is orrery's
    /// decision, not an inference from the filesystem.
    @Test("an unregistered binary in the tools directory is not discovered")
    func doesNotScan() throws {
        let home = try makeHome()
        _ = try makeBinary(in: home, named: "orrery-rogue")
        let config = PluginRegistryConfig(homeURL: home)

        #expect(try config.entries().isEmpty)
    }

    @Test("unregistering forgets deliberately, which is different from a lost binary")
    func unregisterRemoves() throws {
        let home = try makeHome()
        let binary = try makeBinary(in: home, named: "orrery-claude")
        let config = PluginRegistryConfig(homeURL: home)
        try config.register(id: "claude", binaryPath: binary, capabilities: [])

        try config.unregister(id: "claude")
        #expect(try config.entries().isEmpty)
    }

    @Test("a corrupt config is reported, not silently treated as empty")
    func corruptConfigThrows() throws {
        let home = try makeHome()
        let config = PluginRegistryConfig(homeURL: home)
        try Data("not json".utf8).write(to: config.fileURL)

        #expect(throws: (any Error).self) {
            _ = try config.entries()
        }
    }
}
