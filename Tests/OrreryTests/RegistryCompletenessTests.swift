import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

/// A `CaseIterable` enum is total at compile time; a registry is total only
/// once registration has run. Nothing depends on that difference yet — the five
/// one-shot migrations in `AccountMigration` still read the `Tool` enum. Once
/// they take their tool set from the registry instead, a registry that is
/// missing a tool when a migration runs means the migration skips it and marks
/// itself complete regardless, and that tool never migrates on the machine
/// again. These tests assert the completeness that will make that impossible,
/// so the guarantee is already in place when the call sites move.
///
/// Every test builds its own `AIToolRegistry` rather than touching
/// `.shared`, so nothing here depends on whether startup has run or on the
/// order the suite happens to execute in.
@Suite("registry completeness")
struct RegistryCompletenessTests {

    @Test("registering built-ins covers every tool the enum knows")
    func registrationIsComplete() throws {
        let registry = AIToolRegistry()
        try AIToolRegistration.registerBuiltInTools(into: registry, providedByPlugin: [])

        #expect(Set(registry.all.map(\.id)) == Set(Tool.allCases.map(\.rawValue)))
    }

    /// The production default leaves claude's id free.
    ///
    /// This is what lets `registerPlugins` register `orrery-claude` at all: the
    /// duplicate-id guard in `AIToolRegistration` refuses a plugin whose id is
    /// taken, and it must keep refusing — that rule is what stops a third party
    /// displacing a tool orrery ships. So claude cannot be *both* a built-in and
    /// plugin-provided; the enum bridge stops describing it instead.
    ///
    /// The consequence is deliberate and worth stating: after this,
    /// `registerBuiltInTools` alone no longer produces a complete registry.
    /// Completeness now requires the plugins to have registered too, which is
    /// exactly why a failed claude plugin must never be recorded as covered by a
    /// one-shot migration — see `absentPluginIsNotRecordedAsCovered`.
    @Test("a tool provided by a plugin is not registered from the enum")
    func pluginProvidedToolIsNotBuiltIn() throws {
        let registry = AIToolRegistry()
        try AIToolRegistration.registerBuiltInTools(into: registry)

        #expect(AIToolRegistration.pluginProvidedTools == [.claude])
        #expect(registry.tool(id: "claude") == nil,
                "claude is described by orrery-claude, so the bridge must leave its id free")

        let expected = Set(Tool.allCases.map(\.rawValue))
            .subtracting(AIToolRegistration.pluginProvidedTools.map { $0.rawValue })
        #expect(Set(registry.all.map(\.id)) == expected)
        // Naming the survivors, so a future change that empties the registry
        // entirely cannot satisfy the subtraction above by accident.
        #expect(registry.tool(id: "codex") != nil)
        #expect(registry.tool(id: "gemini") != nil)
    }

    /// Stated as "the second call changes nothing", not as a literal count:
    /// tying it to `Tool.allCases.count` made it a test of *which* tools are
    /// built-in, which is now `pluginProvidedTools`' business and is asserted by
    /// `pluginProvidedToolIsNotBuiltIn`. Two assertions of the same fact drift
    /// apart; one of them owns it.
    @Test("registration is idempotent")
    func registrationIsIdempotent() throws {
        let registry = AIToolRegistry()
        try AIToolRegistration.registerBuiltInTools(into: registry)
        let afterFirst = Set(registry.all.map(\.id))
        try AIToolRegistration.registerBuiltInTools(into: registry)

        #expect(Set(registry.all.map(\.id)) == afterFirst)
        #expect(registry.all.count == afterFirst.count,
                "a repeat registration must replace, not append a duplicate entry")
        #expect(!afterFirst.isEmpty, "an empty registry would satisfy the above vacuously")
    }

    /// Checks codex rather than claude because claude is no longer registered
    /// from the enum. The bridge for claude still exists and still matters — it
    /// is what `ClaudePluginParityTests` compares the plugin's description
    /// against — so it is pinned there rather than duplicated here.
    @Test("each registered tool carries its bridged description, not a stub")
    func registeredToolsAreFullyDescribed() throws {
        let registry = AIToolRegistry()
        try AIToolRegistration.registerBuiltInTools(into: registry)

        let codex = registry.tool(id: "codex")
        #expect(codex?.configDirectoryName == Tool.codex.defaultConfigDir.lastPathComponent)
        #expect(codex?.configDirEnvVar == "CODEX_HOME")
        #expect(codex?.displayName == Tool.codex.displayName)
        #expect(codex?.sessionSubdirectories == Tool.codex.sessionSubdirectories)
    }

    @Test("a tool whose plugin is absent is never recorded as covered")
    func absentPluginIsNotRecordedAsCovered() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // Only claude is present; a hypothetical "cursor" plugin failed to load,
        // so it is not in the registry and must not be claimed as covered.
        let flag = MigrationFlag(
            url: home.appendingPathComponent(".test-flag"),
            legacyCoverage: AccountMigration.legacyBuiltInTools)
        let present: Set<String> = ["claude"]
        let pending = try flag.pending(among: present)
        try flag.markCovered(pending)

        #expect(flag.coverage() == .ids(["claude"]))

        // Later, the cursor plugin is fixed and registers.
        let laterPending = try flag.pending(among: ["claude", "cursor"])
        #expect(laterPending == ["cursor"],
                "a tool absent at migration time must become pending once it registers")
    }
}
