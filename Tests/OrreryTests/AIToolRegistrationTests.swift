import Foundation
import Synchronization
import Testing
import AIToolKit
@testable import OrreryCore

/// Collects diagnostics instead of letting them reach stderr.
///
/// `registerPlugins` takes its sink as a parameter rather than these tests
/// redirecting FD 2: FD 2 is process-wide and these tests spawn real child
/// processes — the exact combination that already forced `captureStdout` to grow
/// a lock and a post-mortem comment. An injected sink cannot interleave with
/// another suite's output, and asserting on a value beats parsing a temp file.
private final class Diagnostics: Sendable {
    private let lines = Mutex<[String]>([])

    /// Captures `self`, not `lines`: a `Mutex` is non-copyable, so naming it in
    /// a capture list is a consume the compiler refuses. The class is the
    /// `Sendable` thing worth passing around anyway.
    var record: @Sendable (String) -> Void {
        { [self] line in lines.withLock { $0.append(line) } }
    }

    var joined: String { lines.withLock { $0.joined() } }
}

/// Exercises `AIToolRegistration.registerPlugins`'s failure paths directly —
/// the ones carrying the "one broken plugin must not cost the host its
/// working tools" rule and the "built-ins cannot be displaced" rule. Reading
/// the implementation is not enough: without tests here, deleting a
/// `terminate()` call or the duplicate-id guard would not turn anything red.
///
/// None of these plugins is a working one — a broken plugin is enough to
/// exercise the rule, and is far cheaper to write than a real one. Each is a
/// tiny shell script spawned as a real child process, because the failure
/// modes under test (a process that exits before answering, one that writes
/// garbage before exiting) live in the real `StdioTransport`/`Process`
/// plumbing, not in anything an in-memory transport double would exercise.
@Suite("AIToolRegistration.registerPlugins")
struct AIToolRegistrationTests {

    private let timeout: Duration = .milliseconds(500)

    private func makeScript(_ contents: String, named name: String = "plugin") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("registerPlugins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A script that completes a real handshake and `tool/describe`, always
    /// claiming id `"claude"` with a displayName distinct from the built-in's
    /// — so a test can tell whether the surviving registry entry is the
    /// original built-in or this plugin.
    private func fakeClaudePlugin() throws -> URL {
        try makeScript("""
            #!/bin/sh
            read -r _
            printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"\(PluginServer.protocolVersion)","capabilities":{"tool/describe":true}}}\\n'
            read -r _
            printf '{"jsonrpc":"2.0","id":2,"result":{"id":"claude","displayName":"Fake Claude Plugin","configDirectoryName":".claude","configDirEnvVar":null,"authLoginCommand":null,"installCommand":null,"sessionSubdirectories":[],"ansiColor":""}}\\n'
            """)
    }

    @Test("a plugin that exits immediately does not register, and a previously registered built-in survives")
    func exitsImmediately() async throws {
        let script = try makeScript("#!/bin/sh\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let registry = AIToolRegistry()
        try AIToolRegistration.registerBuiltInTools(into: registry)
        let builtInIDs = Set(registry.all.map(\.id))
        // codex, not claude: claude is plugin-provided in production, so
        // reading its displayName here would compare nil to nil and assert
        // nothing. The survivor has to be a tool that is actually registered.
        let survivorDisplayName = try #require(registry.tool(id: "codex")?.displayName)

        // Proves the script actually became a located, executable binary —
        // without this, a script that failed to become executable would
        // reach the same "cursor" absence via the missing-binary path
        // instead of the one this test claims to exercise.
        #expect(PluginDiscovery.locate(
            toolID: "cursor", environment: ["ORRERY_CURSOR_PATH": script.path]) != nil)

        await AIToolRegistration.registerPlugins(
            into: registry, toolIDs: ["cursor"], timeout: timeout,
            environment: ["ORRERY_CURSOR_PATH": script.path])

        #expect(registry.tool(id: "cursor") == nil)
        #expect(Set(registry.all.map(\.id)) == builtInIDs)
        #expect(registry.tool(id: "codex")?.displayName == survivorDisplayName)
    }

    @Test("a plugin that prints non-JSON and exits does not register, other tools unaffected")
    func printsGarbageThenExits() async throws {
        let script = try makeScript("#!/bin/sh\nread -r _\necho 'not json'\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let registry = AIToolRegistry()
        try AIToolRegistration.registerBuiltInTools(into: registry)
        let builtInIDs = Set(registry.all.map(\.id))

        // See exitsImmediately: without this, a script that never became
        // executable would silently exercise the missing-binary path
        // instead of the garbage-output path this test is named for.
        #expect(PluginDiscovery.locate(
            toolID: "cursor", environment: ["ORRERY_CURSOR_PATH": script.path]) != nil)

        await AIToolRegistration.registerPlugins(
            into: registry, toolIDs: ["cursor"], timeout: timeout,
            environment: ["ORRERY_CURSOR_PATH": script.path])

        #expect(registry.tool(id: "cursor") == nil)
        #expect(Set(registry.all.map(\.id)) == builtInIDs)
    }

    @Test("a plugin id that is already registered leaves the existing entry unchanged, not displaced")
    func duplicateIDLeavesBuiltInUnchanged() async throws {
        let script = try fakeClaudePlugin()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let registry = AIToolRegistry()
        // `providedByPlugin: []` so claude really is a built-in here. The rule
        // under test is "a plugin cannot displace a built-in", which is about
        // built-ins in general — not about whichever tool is plugin-provided
        // this month. Production leaves claude out (see
        // `AIToolRegistration.pluginProvidedTools`), and pinning this test to
        // that choice would have deleted the coverage instead of moving it.
        try AIToolRegistration.registerBuiltInTools(into: registry, providedByPlugin: [])
        let builtInClaude = try #require(registry.tool(id: "claude"))

        // See exitsImmediately: without this, a script that never became
        // executable would silently exercise the missing-binary path
        // instead of the duplicate-id path this test is named for.
        #expect(PluginDiscovery.locate(
            toolID: "claude", environment: ["ORRERY_CLAUDE_PATH": script.path]) != nil)

        await AIToolRegistration.registerPlugins(
            into: registry, toolIDs: ["claude"], timeout: timeout,
            environment: ["ORRERY_CLAUDE_PATH": script.path])

        let survivor = try #require(registry.tool(id: "claude"))
        // The point of this assertion: prove the surviving entry is the
        // original built-in object, not a same-id replacement that merely
        // happens to answer to "claude". The plugin's displayName
        // ("Fake Claude Plugin") never appears in the registry.
        #expect(survivor.displayName == builtInClaude.displayName)
        #expect(survivor.displayName != "Fake Claude Plugin")
        #expect(registry.all.count == Tool.allCases.count)
    }

    @Test("a plugin that hangs mid-handshake does not hang registerPlugins, and a previously registered built-in survives")
    func hangingPluginDoesNotHang() async throws {
        // Reads one line (the "initialize" request) and then blocks for an
        // hour instead of replying — a plugin wedged deep inside a
        // `read(2)` that no amount of task cancellation can interrupt. Only
        // killing the process unblocks it, which is exactly what the
        // watchdog in `registerPlugins` must do.
        let script = try makeScript("#!/bin/sh\nread x\nsleep 3600\n")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let registry = AIToolRegistry()
        try AIToolRegistration.registerBuiltInTools(into: registry)
        let builtInIDs = Set(registry.all.map(\.id))
        // codex, not claude: claude is plugin-provided in production, so
        // reading its displayName here would compare nil to nil and assert
        // nothing. The survivor has to be a tool that is actually registered.
        let survivorDisplayName = try #require(registry.tool(id: "codex")?.displayName)

        #expect(PluginDiscovery.locate(
            toolID: "cursor", environment: ["ORRERY_CURSOR_PATH": script.path]) != nil)

        // A short timeout keeps the suite fast: the watchdog fires at
        // 2x this, so registerPlugins returns in well under a second even
        // though the plugin itself would otherwise block for an hour.
        await AIToolRegistration.registerPlugins(
            into: registry, toolIDs: ["cursor"], timeout: .milliseconds(50),
            environment: ["ORRERY_CURSOR_PATH": script.path])

        #expect(registry.tool(id: "cursor") == nil)
        #expect(Set(registry.all.map(\.id)) == builtInIDs)
        #expect(registry.tool(id: "codex")?.displayName == survivorDisplayName)
    }

    /// The distinction the spec draws under *An installation-time distinction*:
    /// `orrery-claude` ships with orrery, so its absence is a broken install and
    /// must be said out loud. A third party's absence is that tool quietly not
    /// being there.
    ///
    /// Asserts on the binary name and the repair command rather than on the
    /// prose, so translating the message does not turn this red — while still
    /// failing if the message stops naming either.
    @Test("a shipped plugin that cannot be located is reported as a broken install")
    func shippedPluginAbsenceIsLoud() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("registerPlugins-shipped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let registry = AIToolRegistry()
        try AIToolRegistration.registerBuiltInTools(into: registry)
        let builtInIDs = Set(registry.all.map(\.id))
        let diagnostics = Diagnostics()

        #expect(AIToolRegistration.pluginProvidedTools.map { $0.rawValue }.contains("claude"),
                "this test is meaningless unless claude is one of the shipped plugins")

        await AIToolRegistration.registerPlugins(
            into: registry, toolIDs: ["claude"], timeout: timeout,
            environment: ["ORRERY_HOME": home.path, "PATH": ""],
            warn: diagnostics.record)

        let text = diagnostics.joined
        #expect(text.contains("orrery-claude"), "must name the binary that is missing, got: \(text)")
        #expect(text.contains("orrery update"), "must name the repair, got: \(text)")

        // Loud, but still scoped: claude is absent and everything else stands.
        #expect(registry.tool(id: "claude") == nil)
        #expect(Set(registry.all.map(\.id)) == builtInIDs)
        #expect(registry.tool(id: "codex") != nil)
    }

    @Test("a third-party plugin that cannot be located says nothing")
    func thirdPartyAbsenceIsSilent() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("registerPlugins-third-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let registry = AIToolRegistry()
        try AIToolRegistration.registerBuiltInTools(into: registry)
        let diagnostics = Diagnostics()

        #expect(!AIToolRegistration.pluginProvidedTools.map { $0.rawValue }.contains("cursor"))

        await AIToolRegistration.registerPlugins(
            into: registry, toolIDs: ["cursor"], timeout: timeout,
            environment: ["ORRERY_HOME": home.path, "PATH": ""],
            warn: diagnostics.record)

        #expect(diagnostics.joined.isEmpty,
                "an absent third-party plugin is that tool not being installed, not a fault to report")
    }

    @Test("a missing binary is skipped silently, other tools unaffected")
    func missingBinarySkipped() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("registerPlugins-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let registry = AIToolRegistry()
        try AIToolRegistration.registerBuiltInTools(into: registry)
        let builtInIDs = Set(registry.all.map(\.id))

        await AIToolRegistration.registerPlugins(
            into: registry, toolIDs: ["cursor"], timeout: timeout,
            environment: ["ORRERY_HOME": home.path, "PATH": ""])

        #expect(registry.tool(id: "cursor") == nil)
        #expect(Set(registry.all.map(\.id)) == builtInIDs)
    }

    /// Anchors `Bundle(for:)` to the loaded test bundle, whose directory is the
    /// build-products directory `orrery-claude` lands in. See
    /// ClaudePluginParityTests for why `Bundle.main` does not work here.
    private final class BundleMarker {}

    /// The case every other test in this file skips: a plugin that **works**.
    ///
    /// An external review found this gap and it was the expensive one. The
    /// failure matrix above is thorough — seven behaviours, each asserting that
    /// the other tools survive — and none of it ever registered a new id
    /// successfully. That let a defect through in which every successfully
    /// connected plugin had its process killed the instant it registered,
    /// because cancelling the watchdog that guarded the connect ran the
    /// termination it was supposed to skip.
    ///
    /// The binary is `orrery-claude` rather than a shell script. The scripts
    /// above are right for breakage — a broken plugin is cheapest written as
    /// three lines of sh — but a *working* plugin has to be the real shape: a
    /// Swift executable driven by `PluginServer.serve(tool:)`, which is what a
    /// third party's would be. Modelling the success path on the same fixture
    /// style as the failures is how the failure style's limits leak into it.
    @Test("a working plugin registers, and its connection is still alive afterwards")
    func workingPluginRegistersAndSurvives() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("registerPlugins-live-\(UUID().uuidString)")
        let tools = home.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // Discovery looks for `orrery-<id>`, so the real claude plugin stands in
        // for a third-party tool under an id no built-in uses.
        let built = Bundle(for: BundleMarker.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("orrery-claude")
        let installed = tools.appendingPathComponent("orrery-cursor")
        try FileManager.default.copyItem(at: built, to: installed)

        let registry = AIToolRegistry()
        let builtInIDs = Set(Tool.allCases.map(\.rawValue))

        await AIToolRegistration.registerPlugins(
            into: registry, toolIDs: ["cursor"], timeout: .seconds(5),
            environment: ["ORRERY_HOME": home.path, "PATH": ""])

        // It describes itself as claude, since that is the binary — the id it
        // registers under is its own, not the discovery id.
        let registered = try #require(registry.tool(id: "claude"))
        #expect(registered.displayName == Tool.claude.aiTool.displayName)
        #expect(!builtInIDs.isEmpty)

        // The part that would have caught the watchdog defect: the backing
        // process must still be there. A killed plugin leaves a registry entry
        // whose cached description still answers, so checking the fields alone
        // proves nothing — the process itself has to be alive.
        let remote = try #require(registered as? RemoteAITool)
        #expect(await remote.isConnectionAlive,
                "a registered plugin's process must outlive registration")
    }
}
