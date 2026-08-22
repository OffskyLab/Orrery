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
        try AIToolRegistration.registerBuiltInTools(into: registry)

        #expect(Set(registry.all.map(\.id)) == Set(Tool.allCases.map(\.rawValue)))
    }

    @Test("registration is idempotent")
    func registrationIsIdempotent() throws {
        let registry = AIToolRegistry()
        try AIToolRegistration.registerBuiltInTools(into: registry)
        try AIToolRegistration.registerBuiltInTools(into: registry)

        #expect(registry.all.count == Tool.allCases.count)
    }

    @Test("each registered tool carries its bridged description, not a stub")
    func registeredToolsAreFullyDescribed() throws {
        let registry = AIToolRegistry()
        try AIToolRegistration.registerBuiltInTools(into: registry)

        let claude = registry.tool(id: "claude")
        #expect(claude?.configDirectoryName == ".claude")
        #expect(claude?.configDirEnvVar == "CLAUDE_CONFIG_DIR")
        #expect(claude?.displayName == Tool.claude.displayName)
    }

    @Test("a tool whose plugin is absent is never recorded as covered")
    func absentPluginIsNotRecordedAsCovered() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // Only claude is present; a hypothetical "cursor" plugin failed to load,
        // so it is not in the registry and must not be claimed as covered.
        let flag = MigrationFlag(url: home.appendingPathComponent(".test-flag"))
        let present: Set<String> = ["claude"]
        let pending = flag.pending(among: present)
        try flag.markCovered(pending)

        #expect(flag.coverage() == .ids(["claude"]))

        // Later, the cursor plugin is fixed and registers.
        let laterPending = flag.pending(among: ["claude", "cursor"])
        #expect(laterPending == ["cursor"],
                "a tool absent at migration time must become pending once it registers")
    }
}
