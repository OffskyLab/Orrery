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
    func absentFlag() throws {
        let url = tmpFlag()
        let flag = MigrationFlag(url: url, legacyCoverage: AccountMigration.legacyBuiltInTools)

        #expect(flag.coverage() == .absent)
        #expect(try flag.pending(among: ["claude", "codex"]) == ["claude", "codex"])
    }

    @Test("marking coverage records exactly those ids")
    func marksCoverage() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        let flag = MigrationFlag(url: url, legacyCoverage: AccountMigration.legacyBuiltInTools)

        try flag.markCovered(["claude", "codex"])

        #expect(flag.coverage() == .ids(["claude", "codex"]))
        #expect(try flag.pending(among: ["claude", "codex"]).isEmpty)
    }

    @Test("a tool absent when the migration ran is still pending afterwards")
    func laterToolIsPending() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        let flag = MigrationFlag(url: url, legacyCoverage: AccountMigration.legacyBuiltInTools)

        try flag.markCovered(["claude", "codex"])

        // gemini registers later — the whole point of this type.
        #expect(try flag.pending(among: ["claude", "codex", "gemini"]) == ["gemini"])
    }

    @Test("marking again unions rather than replaces")
    func markingUnions() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        let flag = MigrationFlag(url: url, legacyCoverage: AccountMigration.legacyBuiltInTools)

        try flag.markCovered(["claude"])
        try flag.markCovered(["gemini"])

        #expect(flag.coverage() == .ids(["claude", "gemini"]))
    }

    /// Existing installs have flag files holding "v1\n" or "v3\n". Reading one
    /// as "covers nothing" would re-run every migration on upgrade.
    @Test("a legacy version-only flag counts as covering the tools it historically handled")
    func legacyFlagCoversHistoricalSet() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("v3\n".utf8).write(to: url)
        let flag = MigrationFlag(url: url, legacyCoverage: AccountMigration.legacyBuiltInTools)

        #expect(flag.coverage() == .legacy)
        #expect(try flag.pending(among: ["claude", "codex", "gemini"]).isEmpty)
    }

    /// The P2 this fixes: a legacy marker records that the migration ran in
    /// some earlier version. It cannot record which tools existed then, and
    /// treating it as "covered everything, forever" reintroduces exactly the
    /// permanent-skip bug this type was built to close — for every tool added
    /// after the flag was written.
    @Test("a legacy flag does not mask a tool that did not exist when it was written")
    func legacyFlagDoesNotMaskFutureTools() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("v1\n".utf8).write(to: url)
        let flag = MigrationFlag(url: url, legacyCoverage: AccountMigration.legacyBuiltInTools)

        #expect(try flag.pending(among: ["claude", "codex", "gemini", "cursor"]) == ["cursor"])
    }

    @Test("legacy detection does not depend on which version string was used")
    func legacyFlagAnyVersion() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("v1\n".utf8).write(to: url)

        #expect(MigrationFlag(url: url, legacyCoverage: AccountMigration.legacyBuiltInTools).coverage() == .legacy)
    }

    /// "v2" is `formatVersion`'s own value, so this is the one legacy content
    /// a parser that compared line 1 against `formatVersion` before stripping
    /// it would misread as "no marker, no ids" instead of a legacy marker. A
    /// real machine's `.workspace-account-symlinks` flag holds exactly this.
    @Test("a legacy flag whose version happens to equal formatVersion is still legacy")
    func legacyFlagMatchingFormatVersion() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("v2\n".utf8).write(to: url)

        #expect(MigrationFlag(url: url, legacyCoverage: AccountMigration.legacyBuiltInTools).coverage() == .legacy)
        #expect(try MigrationFlag(url: url, legacyCoverage: AccountMigration.legacyBuiltInTools).pending(among: ["claude", "codex", "gemini"]).isEmpty)
    }

    @Test("an empty flag file is legacy, not corrupt")
    func emptyFlagIsLegacy() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("".utf8).write(to: url)

        #expect(MigrationFlag(url: url, legacyCoverage: AccountMigration.legacyBuiltInTools).coverage() == .legacy)
    }

    /// The inversion this format change exists to kill. Under the old format a
    /// marker was a bare `v2`, so a run that recorded *nothing* wrote exactly
    /// the byte sequence a legacy marker had — and the next read expanded it to
    /// the full historical set. The more completely a run failed, the more
    /// coverage its flag claimed.
    @Test("recording nothing does not read back as covering everything")
    func emptyRecordDoesNotBecomeFullCoverage() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        let flag = MigrationFlag(url: url, legacyCoverage: AccountMigration.legacyBuiltInTools)

        try flag.markCovered([])

        // Nothing was recorded, so nothing is covered and everything is still
        // pending. No file is written at all, which cannot be misread.
        #expect(flag.coverage() == .absent)
        #expect(try flag.pending(among: ["claude", "codex", "gemini"])
                == ["claude", "codex", "gemini"])
    }

    /// Recording nothing on top of a real record must not erase it either.
    @Test("recording nothing preserves an existing record")
    func emptyRecordPreservesExisting() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        let flag = MigrationFlag(url: url, legacyCoverage: AccountMigration.legacyBuiltInTools)

        try flag.markCovered(["claude"])
        try flag.markCovered([])

        #expect(flag.coverage() == .ids(["claude"]))
    }

    /// A flag that exists but cannot be decoded is not the same as no flag. The
    /// credential migration takes a full backup and rewrites credentials, so
    /// reading an unreadable flag as never-run means doing that again on every
    /// startup for as long as the file stays broken.
    @Test("an undecodable flag is unreadable, not absent")
    func undecodableFlagIsUnreadable() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        // Invalid UTF-8: a lone continuation byte.
        try Data([0x80, 0x0A]).write(to: url)
        let flag = MigrationFlag(url: url, legacyCoverage: AccountMigration.legacyBuiltInTools)

        #expect(flag.coverage() == .unreadable)
        #expect(throws: MigrationFlag.Unreadable.self) {
            _ = try flag.pending(among: ["claude"])
        }
    }

    /// Overwriting an unreadable flag would destroy the only record of what has
    /// already been done, so `markCovered` refuses rather than replacing it.
    @Test("marking coverage refuses to overwrite an unreadable flag")
    func markCoveredRefusesUnreadable() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x80, 0x0A]).write(to: url)
        let flag = MigrationFlag(url: url, legacyCoverage: AccountMigration.legacyBuiltInTools)

        #expect(throws: MigrationFlag.Unreadable.self) {
            try flag.markCovered(["claude"])
        }
        // The original bytes are still there.
        #expect(try Data(contentsOf: url) == Data([0x80, 0x0A]))
    }

    @Test("a tool id shaped like a version marker survives a round trip")
    func versionShapedIDSurvives() throws {
        let url = tmpFlag()
        defer { try? FileManager.default.removeItem(at: url) }
        let flag = MigrationFlag(url: url, legacyCoverage: AccountMigration.legacyBuiltInTools)

        try flag.markCovered(["claude", "v2"])

        // "v2" is a tool id here, not a format marker. Dropping it would silently
        // re-skip that tool on every read.
        #expect(flag.coverage() == .ids(["claude", "v2"]))
        #expect(try flag.pending(among: ["claude", "v2"]).isEmpty)
    }
}

@Suite("AccountMigration per-tool flags")
struct AccountMigrationFlagTests {

    /// The backfill is the cheapest of the five to drive end to end: it needs
    /// only an accounts directory, no workspaces or credentials.
    @Test("backfill records the tools it covered instead of a bare marker")
    func backfillRecordsCoveredTools() throws {
        try withIsolatedHome {
            let home = orreryHomeURL()
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

            AccountMigration.runInfoBackfillIfNeeded(homeURL: home)

            let flag = MigrationFlag(
                url: home.appendingPathComponent(AccountMigration.infoBackfillFlagFileName),
                legacyCoverage: AccountMigration.legacyBuiltInTools)

            // Every tool known at this point must be recorded by name — not a
            // bare "done", which is what would silently skip a later tool.
            let expected = Set(Tool.allCases.map(\.rawValue))
            #expect(flag.coverage() == .ids(expected))
        }
    }

    @Test("a legacy marker still short-circuits the backfill")
    func backfillHonoursLegacyMarker() throws {
        try withIsolatedHome {
            let home = orreryHomeURL()
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let url = home.appendingPathComponent(AccountMigration.infoBackfillFlagFileName)
            try Data("v1\n".utf8).write(to: url)

            AccountMigration.runInfoBackfillIfNeeded(homeURL: home)

            // Untouched: an upgrading install must not re-run what it already did.
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text == "v1\n")
        }
    }

    /// The workspace-symlink migration only ever walks claude accounts, so its
    /// flag must claim claude and nothing else. Recording codex and gemini here
    /// would mark work complete that this migration never attempted.
    @Test("the workspace-symlink migration records only the tool it processed")
    func workspaceSymlinksRecordsClaudeOnly() throws {
        try withIsolatedHome {
            let home = orreryHomeURL()
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

            AccountMigration.runWorkspaceAccountSymlinksIfNeeded(homeURL: home)

            let flag = MigrationFlag(
                url: home.appendingPathComponent(
                    AccountMigration.workspaceAccountSymlinksFlagFileName),
                legacyCoverage: [Tool.claude.rawValue])

            #expect(flag.coverage() == .ids([Tool.claude.rawValue]))
            #expect(try flag.pending(among: [Tool.claude.rawValue]).isEmpty)
        }
    }

    /// Installs that ran this migration before it took a `MigrationFlag` have a
    /// bare `v1` marker on disk. Rebuilding every account's symlinks again on
    /// upgrade is not free, so the legacy marker must still stop it.
    @Test("a legacy marker still short-circuits the workspace-symlink migration")
    func workspaceSymlinksHonoursLegacyMarker() throws {
        try withIsolatedHome {
            let home = orreryHomeURL()
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let url = home.appendingPathComponent(
                AccountMigration.workspaceAccountSymlinksFlagFileName)
            try Data("v1\n".utf8).write(to: url)

            AccountMigration.runWorkspaceAccountSymlinksIfNeeded(homeURL: home)

            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text == "v1\n")
        }
    }
}
