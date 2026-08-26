import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

/// Production code reads `AIToolRegistry.shared`, which `main.swift` populates
/// during bootstrap. A test process has no bootstrap, so without something like
/// this the shared registry is empty and every migrated fact reader silently
/// takes its "tool unavailable" branch — tests would keep passing while
/// asserting the degraded path instead of the real one.
///
/// This is the hazard that arrives the moment a call site moves from the enum to
/// the registry, and it is worth a test of its own rather than a helper nobody
/// remembers to call.
@Suite("shared registry seeding")
struct SharedRegistrySeedTests {

    @Test("the suite seeds the shared registry, so migrated readers see the real answer")
    func sharedRegistryIsPopulated() throws {
        seedSharedRegistryForTests()

        #expect(AIToolRegistry.shared.tool(id: "codex") != nil,
                "a built-in must be present, or every migrated reader is testing the nil branch")

        // claude comes from a plugin in production. The test process seeds it
        // from the bridge instead of spawning orrery-claude for every suite:
        // the two describe claude identically — pinned by
        // ClaudePluginParityTests — and paying a process spawn per test run to
        // re-establish that is cost without coverage.
        #expect(AIToolRegistry.shared.tool(id: "claude") != nil)

        // Compares the directory *name*, not the whole path. Both sides resolve
        // `userHomeURL()` on their own, and other suites move ORRERY_USER_HOME
        // while this one runs — comparing full paths passed alone and failed in
        // a full run, which is the shape of a test that reports the suite's
        // scheduling rather than the behaviour it names.
        #expect(Tool.claude.configDir()?.lastPathComponent
                == Tool.claude.defaultConfigDir.lastPathComponent)
    }
}
