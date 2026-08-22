import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

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
        let claudeDisplayName = registry.tool(id: "claude")?.displayName

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
        #expect(registry.tool(id: "claude")?.displayName == claudeDisplayName)
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
        try AIToolRegistration.registerBuiltInTools(into: registry)
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
        let claudeDisplayName = registry.tool(id: "claude")?.displayName

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
        #expect(registry.tool(id: "claude")?.displayName == claudeDisplayName)
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
}
