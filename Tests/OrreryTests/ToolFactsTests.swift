import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

/// The seam that moves a tool's config directory from the enum to the registry.
///
/// The registry is passed explicitly in every test here rather than defaulted to
/// `.shared`, so nothing depends on whether startup has run or on the order the
/// suite happens to execute in.
@Suite("Tool facts from the registry")
struct ToolFactsTests {

    /// A tool describing a directory the enum would never produce, so a test can
    /// tell which of the two sources answered.
    private struct Impostor: AITool {
        let id: String
        let displayName = "Impostor"
        let configDirectoryName = ".not-what-the-enum-says"
    }

    @Test("a registered tool's config dir is built from the registry's answer")
    func configDirComesFromTheRegistry() throws {
        let registry = AIToolRegistry()
        try registry.register(Impostor(id: "claude"))

        let dir = try #require(Tool.claude.configDir(in: registry))

        // The assertion that distinguishes the two sources. Comparing against
        // `Tool.claude.defaultConfigDir` would pass whichever one answered,
        // because a healthy plugin and the enum agree by construction — that
        // agreement is what `ClaudePluginParityTests` exists to keep.
        #expect(dir.lastPathComponent == ".not-what-the-enum-says")
        #expect(dir != Tool.claude.defaultConfigDir)
    }

    @Test("the config dir is resolved against the isolation seam, not the real home")
    func configDirHonoursTheHomeSeam() throws {
        let registry = AIToolRegistry()
        try registry.register(Impostor(id: "codex"))

        let dir = try #require(Tool.codex.configDir(in: registry))

        // `userHomeURL()` is what ORRERY_USER_HOME redirects. A seam that
        // reached for the real home instead would put this test's answer in the
        // developer's home directory — the incident RealHomeIsolationTests
        // guards, arriving through a new door.
        #expect(dir.deletingLastPathComponent().path == userHomeURL().path)
    }

    @Test("a tool that is not registered has no config dir")
    func unregisteredToolHasNoConfigDir() {
        let registry = AIToolRegistry()

        // The shape of a broken install: claude's plugin did not load, so
        // nothing can answer for claude. Falling back to the enum here would
        // make the plugin unobservable — you could delete orrery-claude and
        // every path would keep working as though nothing had happened.
        #expect(Tool.claude.configDir(in: registry) == nil)
    }

    @Test("the registry's description is reachable whole, not just its config dir")
    func describedReturnsTheWholeTool() throws {
        let registry = AIToolRegistry()
        try registry.register(Impostor(id: "gemini"))

        let described = try #require(Tool.gemini.described(in: registry))
        #expect(described.id == "gemini")
        #expect(described.displayName == "Impostor")
        #expect(Tool.claude.described(in: registry) == nil)
    }

    /// The production shape, end to end: after a real bootstrap, claude's config
    /// directory is an answer that crossed a pipe.
    @Test("after a bootstrap with the plugin installed, claude's config dir comes from it")
    func bootstrapResolvesClaudeThroughThePlugin() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toolfacts-\(UUID().uuidString)")
        let tools = home.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let built = Bundle(for: BundleMarker.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("orrery-claude")
        try FileManager.default.copyItem(
            at: built, to: tools.appendingPathComponent("orrery-claude"))

        let registry = AIToolRegistry()
        try AIToolRegistration.registerBuiltInTools(into: registry)
        await AIToolRegistration.registerPlugins(
            into: registry,
            toolIDs: AIToolRegistration.pluginProvidedTools.map { $0.rawValue },
            timeout: .seconds(5),
            environment: ["ORRERY_HOME": home.path, "PATH": ""],
            warn: { _ in })

        #expect(registry.tool(id: "claude") is RemoteAITool, "the premise: claude is remote")
        // Here the plugin and the enum do agree, and that is the point: the
        // migration must not change what any call site sees.
        #expect(Tool.claude.configDir(in: registry) == Tool.claude.defaultConfigDir)
        #expect(Tool.codex.configDir(in: registry) == Tool.codex.defaultConfigDir)
    }

    private final class BundleMarker {}
}
