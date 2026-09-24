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

    /// Inside `withIsolatedHome`, which this test needs for two reasons.
    ///
    /// It holds the gate that serializes `ORRERY_USER_HOME`, so no other suite
    /// can move the home between the two resolutions below — without it this
    /// compares two different moments and reports the suite's scheduling. And it
    /// pins the home to a known temporary directory, which lets the assertion be
    /// the stronger one: the answer lands under the *isolated* home, rather than
    /// under whatever `userHomeURL()` happens to return at that instant.
    @Test("the config dir is resolved against the isolation seam, not the real home")
    func configDirHonoursTheHomeSeam() async throws {
        try await withIsolatedHome {
            let registry = AIToolRegistry()
            try registry.register(Impostor(id: "codex"))

            let dir = try #require(Tool.codex.configDir(in: registry))
            let isolated = try #require(
                ProcessInfo.processInfo.environment["ORRERY_USER_HOME"])

            // A seam that reached for the real home instead would put this
            // answer in the developer's home directory — the incident
            // `RealHomeIsolationTests` guards, arriving through a new door.
            #expect(dir.deletingLastPathComponent().path == isolated)
            #expect(dir.lastPathComponent == ".not-what-the-enum-says")
        }
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
        //
        // The *directory name*, not the whole path. Both sides resolve
        // `userHomeURL()` on their own, and other suites move
        // `ORRERY_USER_HOME` while this one runs — so comparing full paths
        // compares two different moments and reports the suite's scheduling
        // rather than the behaviour this test is named for. It failed exactly
        // that way on CI, with one side on the runner's real home and the other
        // on an isolated one, having passed on the same commit minutes earlier.
        #expect(Tool.claude.configDir(in: registry)?.lastPathComponent
                == Tool.claude.defaultConfigDir.lastPathComponent)
        #expect(Tool.codex.configDir(in: registry)?.lastPathComponent
                == Tool.codex.defaultConfigDir.lastPathComponent)
    }

    /// Why the assertions above compare directory names rather than paths.
    ///
    /// Both `configDir(in:)` and `defaultConfigDir` resolve the home themselves,
    /// so a full-path comparison spans two resolutions. The suite runs in
    /// parallel and other tests move `ORRERY_USER_HOME`, so those two moments
    /// can see different homes — and then the comparison reports the scheduler
    /// rather than the behaviour under test.
    ///
    /// That is not a hypothesis: CI printed both values on a commit that had
    /// passed minutes earlier on the same code, one side on the runner's real
    /// home and the other on an isolated one. It could not be reproduced
    /// locally, so this demonstrates the mechanism deterministically instead,
    /// by moving the home between the two reads on purpose.
    ///
    /// Holds the home gate: it mutates `ORRERY_USER_HOME` itself, and doing that
    /// outside the gate is the very race it documents.
    @Test("a full-path comparison would span two home resolutions; a name comparison does not")
    func pathComparisonSpansTwoResolutions() async throws {
        try await withIsolatedHome {
            let registry = AIToolRegistry()
            try AIToolRegistration.registerBuiltInTools(into: registry)

            let first = try #require(Tool.codex.configDir(in: registry))

            // Exactly what a concurrent suite's `withIsolatedHome` does, at the
            // instant that makes the difference visible.
            let moved = NSTemporaryDirectory() + "moved-home-\(UUID().uuidString)"
            setenv("ORRERY_USER_HOME", moved, 1)
            let second = Tool.codex.defaultConfigDir

            #expect(first.path != second.path,
                    "the paths differ once the home moves — which is the failure CI saw")
            #expect(first.lastPathComponent == second.lastPathComponent,
                    "the directory name is what both sides actually agree about")
        }
    }

    private final class BundleMarker {}
}
