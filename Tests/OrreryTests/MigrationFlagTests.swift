import Foundation
import Testing
@testable import OrreryCore

/// One-shot migration flags used to be a single global "done" marker. That is
/// safe only while the tool list is fixed at compile time. Once it comes from a
/// registry, a tool that was not registered when the migration ran is skipped
/// *and* the flag is written — so it never migrates on that machine again.
/// `MigrationFlag` records which tools a flag actually covered.
@Suite("MigrationFlag")
struct MigrationFlagTests {

    private func tmpFlag() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-flag-\(UUID().uuidString)")
    }

    @Test("a missing flag means nothing has been covered")
    func absentFlag() {
        let url = tmpFlag()
        let flag = MigrationFlag(url: url)

        #expect(flag.coverage() == .absent)
        #expect(flag.pending(among: ["claude", "codex"]) == ["claude", "codex"])
    }

    @Test("marking coverage records exactly those ids")
    func marksCoverage() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        let flag = MigrationFlag(url: url)

        try flag.markCovered(["claude", "codex"])

        #expect(flag.coverage() == .ids(["claude", "codex"]))
        #expect(flag.pending(among: ["claude", "codex"]).isEmpty)
    }

    @Test("a tool absent when the migration ran is still pending afterwards")
    func laterToolIsPending() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        let flag = MigrationFlag(url: url)

        try flag.markCovered(["claude", "codex"])

        // gemini registers later — the whole point of this type.
        #expect(flag.pending(among: ["claude", "codex", "gemini"]) == ["gemini"])
    }

    @Test("marking again unions rather than replaces")
    func markingUnions() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        let flag = MigrationFlag(url: url)

        try flag.markCovered(["claude"])
        try flag.markCovered(["gemini"])

        #expect(flag.coverage() == .ids(["claude", "gemini"]))
    }

    /// Existing installs have flag files holding "v1\n" or "v3\n". Reading one
    /// as "covers nothing" would re-run every migration on upgrade.
    @Test("a legacy version-only flag counts as covering everything")
    func legacyFlagCoversAll() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("v3\n".utf8).write(to: url)
        let flag = MigrationFlag(url: url)

        #expect(flag.coverage() == .legacyCoversAll)
        #expect(flag.pending(among: ["claude", "codex", "gemini"]).isEmpty)
    }

    @Test("legacy detection does not depend on which version string was used")
    func legacyFlagAnyVersion() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("v1\n".utf8).write(to: url)

        #expect(MigrationFlag(url: url).coverage() == .legacyCoversAll)
    }

    @Test("an empty flag file is legacy, not corrupt")
    func emptyFlagIsLegacy() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("".utf8).write(to: url)

        #expect(MigrationFlag(url: url).coverage() == .legacyCoversAll)
    }
}
