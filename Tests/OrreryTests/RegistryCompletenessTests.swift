import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

/// The registry is total only once registration has run. Four one-shot
/// migrations in AccountMigration mark themselves complete for whichever tools
/// they saw, so registering late means a tool is skipped and locked out
/// permanently. These tests pin the invariant that makes that impossible.
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
