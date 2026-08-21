import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

/// A `CaseIterable` enum is total at compile time; a registry is total only
/// once registration has run. Nothing depends on that difference yet — the four
/// one-shot migrations in `AccountMigration` still read `Tool.allCases`. Once
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
    func registrationIsComplete() {
        let registry = AIToolRegistry()
        AIToolRegistration.registerBuiltInTools(into: registry)

        #expect(Set(registry.all.map(\.id)) == Set(Tool.allCases.map(\.rawValue)))
    }

    @Test("registration is idempotent")
    func registrationIsIdempotent() {
        let registry = AIToolRegistry()
        AIToolRegistration.registerBuiltInTools(into: registry)
        AIToolRegistration.registerBuiltInTools(into: registry)

        #expect(registry.all.count == Tool.allCases.count)
    }

    @Test("each registered tool carries its bridged description, not a stub")
    func registeredToolsAreFullyDescribed() {
        let registry = AIToolRegistry()
        AIToolRegistration.registerBuiltInTools(into: registry)

        let claude = registry.tool(id: "claude")
        #expect(claude?.configDirectoryName == ".claude")
        #expect(claude?.configDirEnvVar == "CLAUDE_CONFIG_DIR")
        #expect(claude?.displayName == Tool.claude.displayName)
    }
}
