import Testing
import Foundation
@testable import OrreryCore

@Suite("SemanticVersion")
struct SemanticVersionTests {

    @Test("parses three-component versions")
    func parsesThreeComponent() {
        let v = SemanticVersion("2.4.0")
        #expect(v == SemanticVersion(major: 2, minor: 4, patch: 0))
    }

    @Test("strips pre-release suffix")
    func stripsSuffix() {
        #expect(SemanticVersion("2.4.0-beta") == SemanticVersion(major: 2, minor: 4, patch: 0))
        #expect(SemanticVersion("2.4.0+build.7") == SemanticVersion(major: 2, minor: 4, patch: 0))
    }

    @Test("returns nil for fewer than three components")
    func rejectsTooFewComponents() {
        #expect(SemanticVersion("2.4") == nil)
        #expect(SemanticVersion("2") == nil)
    }

    @Test("returns nil for non-numeric components")
    func rejectsNonNumeric() {
        #expect(SemanticVersion("two.four.zero") == nil)
        #expect(SemanticVersion("2.4.x") == nil)
        #expect(SemanticVersion("") == nil)
    }

    @Test("Comparable orders versions correctly")
    func comparable() {
        #expect(SemanticVersion("2.3.0")! < SemanticVersion("2.4.0")!)
        #expect(SemanticVersion("2.3.1")! > SemanticVersion("2.3.0")!)
        #expect(SemanticVersion("2.0.0")! < SemanticVersion("10.0.0")!)  // numeric, not lex
        #expect(SemanticVersion("2.4.0")! == SemanticVersion("2.4.0")!)
    }
}

@Suite("VersionConstraint")
struct VersionConstraintTests {

    @Test("parses each operator")
    func parsesOperators() {
        #expect(VersionConstraint("<2.3.0")?.op == .lt)
        #expect(VersionConstraint("<=2.3.0")?.op == .lte)
        #expect(VersionConstraint("=2.3.0")?.op == .eq)
        #expect(VersionConstraint(">=2.3.0")?.op == .gte)
        #expect(VersionConstraint(">2.3.0")?.op == .gt)
    }

    @Test("tolerates whitespace around operator")
    func tolerantWhitespace() {
        #expect(VersionConstraint("  < 2.3.0 ")?.op == .lt)
        #expect(VersionConstraint(">=  2.3.0")?.version == SemanticVersion("2.3.0"))
    }

    @Test("returns nil for missing operator")
    func rejectsMissingOperator() {
        #expect(VersionConstraint("2.3.0") == nil)
    }

    @Test("returns nil for malformed version")
    func rejectsMalformedVersion() {
        #expect(VersionConstraint("<2.3") == nil)
        #expect(VersionConstraint("<abc") == nil)
    }

    @Test("evaluates each operator correctly")
    func evaluates() {
        let v230 = SemanticVersion("2.3.0")!
        #expect(VersionConstraint("<2.3.0")!.isSatisfied(by: SemanticVersion("2.2.9")!))
        #expect(!VersionConstraint("<2.3.0")!.isSatisfied(by: v230))
        #expect(VersionConstraint("<=2.3.0")!.isSatisfied(by: v230))
        #expect(VersionConstraint("=2.3.0")!.isSatisfied(by: v230))
        #expect(!VersionConstraint("=2.3.0")!.isSatisfied(by: SemanticVersion("2.3.1")!))
        #expect(VersionConstraint(">=2.3.0")!.isSatisfied(by: v230))
        #expect(VersionConstraint(">2.3.0")!.isSatisfied(by: SemanticVersion("2.3.1")!))
        #expect(!VersionConstraint(">2.3.0")!.isSatisfied(by: v230))
    }
}

@Suite("UpdateNotice")
struct UpdateNoticeTests {

    @Test("parses well-formed frontmatter and body")
    func parsesWellFormed() {
        let raw = """
        ---
        applies-to: <2.3.0
        ---
        Reinstall via install.sh.
        """
        let notice = UpdateNotice.parse(raw)
        #expect(notice != nil)
        #expect(notice?.body == "Reinstall via install.sh.")
        #expect(notice?.constraints.count == 1)
        #expect(notice?.constraints.first?.op == .lt)
    }

    @Test("parses AND-combined constraints")
    func parsesAndCombined() {
        let raw = """
        ---
        applies-to: >=2.0.0, <2.3.0
        ---
        body
        """
        let notice = UpdateNotice.parse(raw)
        #expect(notice?.constraints.count == 2)
        #expect(notice?.constraints[0].op == .gte)
        #expect(notice?.constraints[1].op == .lt)
    }

    @Test("returns nil when frontmatter is missing")
    func rejectsMissingFrontmatter() {
        #expect(UpdateNotice.parse("no frontmatter here") == nil)
    }

    @Test("returns nil when applies-to is absent")
    func rejectsMissingAppliesTo() {
        let raw = """
        ---
        other-key: foo
        ---
        body
        """
        #expect(UpdateNotice.parse(raw) == nil)
    }

    @Test("returns nil on malformed constraint")
    func rejectsBadConstraint() {
        let raw = """
        ---
        applies-to: ~2.3.0
        ---
        body
        """
        #expect(UpdateNotice.parse(raw) == nil)
    }

    @Test("preserves --- inside body")
    func preservesInnerDashes() {
        let raw = """
        ---
        applies-to: <2.3.0
        ---
        first line
        ---
        second line after horizontal rule
        """
        let notice = UpdateNotice.parse(raw)
        #expect(notice?.body.contains("---") == true)
        #expect(notice?.body.contains("second line") == true)
    }

    @Test("tolerates CRLF line endings")
    func tolerantCRLF() {
        let raw = "---\r\napplies-to: <2.3.0\r\n---\r\nbody line\r\n"
        let notice = UpdateNotice.parse(raw)
        #expect(notice != nil)
        #expect(notice?.body.contains("body line") == true)
    }

    @Test("applies(to:) evaluates AND across constraints")
    func appliesToAND() {
        let raw = """
        ---
        applies-to: >=2.0.0, <2.3.0
        ---
        body
        """
        let notice = UpdateNotice.parse(raw)!
        #expect(notice.applies(to: SemanticVersion("2.1.0")!))
        #expect(!notice.applies(to: SemanticVersion("1.9.0")!))
        #expect(!notice.applies(to: SemanticVersion("2.3.0")!))
    }
}

@Suite("NoticeCache")
struct NoticeCacheTests {

    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-notice-cache-\(UUID().uuidString).json")
    }

    @Test("round-trip write and read")
    func roundTrip() throws {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let entry = NoticeCache.Entry(
            etag: "W/\"abc\"",
            body: "Reinstall via install.sh.",
            appliesToRaw: "<2.3.0",
            fetchedAt: 1734567890
        )
        let cache = NoticeCache(url: url)
        cache.write(entry)

        let read = cache.read()
        #expect(read == entry)
    }

    @Test("read returns nil when file missing")
    func readMissing() {
        let url = tempCacheURL()
        let cache = NoticeCache(url: url)
        #expect(cache.read() == nil)
    }

    @Test("read returns nil on corrupt JSON")
    func readCorrupt() throws {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "not json at all".write(to: url, atomically: true, encoding: .utf8)

        let cache = NoticeCache(url: url)
        #expect(cache.read() == nil)
    }

    @Test("delete removes the file")
    func deleteRemoves() throws {
        let url = tempCacheURL()
        let entry = NoticeCache.Entry(etag: nil, body: "x", appliesToRaw: "<1.0.0", fetchedAt: 0)
        let cache = NoticeCache(url: url)
        cache.write(entry)
        #expect(FileManager.default.fileExists(atPath: url.path))

        cache.delete()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("delete is a no-op when file is absent")
    func deleteMissing() {
        let url = tempCacheURL()
        let cache = NoticeCache(url: url)
        cache.delete()  // must not throw / crash
    }
}

@Suite("UpdateNoticeFetcher")
struct UpdateNoticeFetcherTests {

    private let url = URL(string: "https://example.test/notice.md")!
    private let current = SemanticVersion("2.2.0")!

    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-notice-fetcher-\(UUID().uuidString).json")
    }

    private func validNoticeBody(appliesTo: String = "<2.3.0", body: String = "Upgrade via install.sh") -> String {
        """
        ---
        applies-to: \(appliesTo)
        ---
        \(body)
        """
    }

    @Test("first run: .ok with matching applies-to returns body, writes cache")
    func firstRunMatches() {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let fetcher = UpdateNoticeFetcher(
            url: url,
            cacheURL: cacheURL,
            transport: { _, etag in
                #expect(etag == nil)  // no cache yet
                return .ok(etag: "W/\"v1\"", body: self.validNoticeBody())
            }
        )
        let out = fetcher.fetch(currentVersion: current)
        #expect(out == "Upgrade via install.sh")
        #expect(NoticeCache(url: cacheURL).read()?.etag == "W/\"v1\"")
    }

    @Test(".ok but applies-to doesn't match returns nil, still writes cache")
    func firstRunNoMatch() {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let fetcher = UpdateNoticeFetcher(
            url: url,
            cacheURL: cacheURL,
            transport: { _, _ in
                .ok(etag: "W/\"v1\"", body: self.validNoticeBody(appliesTo: ">=9.0.0"))
            }
        )
        #expect(fetcher.fetch(currentVersion: current) == nil)
        #expect(NoticeCache(url: cacheURL).read()?.appliesToRaw == ">=9.0.0")
    }

    @Test(".notModified uses cached body when applies-to matches")
    func notModifiedUsesCache() {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let cache = NoticeCache(url: cacheURL)
        cache.write(.init(etag: "W/\"v1\"", body: "cached body", appliesToRaw: "<2.3.0", fetchedAt: 0))

        let fetcher = UpdateNoticeFetcher(
            url: url,
            cacheURL: cacheURL,
            transport: { _, etag in
                #expect(etag == "W/\"v1\"")
                return .notModified
            }
        )
        #expect(fetcher.fetch(currentVersion: current) == "cached body")
    }

    @Test(".failed + cache returns stale cached body")
    func failedUsesStaleCache() {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        NoticeCache(url: cacheURL).write(
            .init(etag: "W/\"v1\"", body: "stale body", appliesToRaw: "<2.3.0", fetchedAt: 0)
        )

        let fetcher = UpdateNoticeFetcher(
            url: url,
            cacheURL: cacheURL,
            transport: { _, _ in .failed }
        )
        #expect(fetcher.fetch(currentVersion: current) == "stale body")
    }

    @Test(".failed + no cache returns nil")
    func failedNoCache() {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let fetcher = UpdateNoticeFetcher(
            url: url,
            cacheURL: cacheURL,
            transport: { _, _ in .failed }
        )
        #expect(fetcher.fetch(currentVersion: current) == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test(".gone deletes cache, returns nil")
    func goneDeletesCache() {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        NoticeCache(url: cacheURL).write(
            .init(etag: "W/\"v1\"", body: "old", appliesToRaw: "<2.3.0", fetchedAt: 0)
        )

        let fetcher = UpdateNoticeFetcher(
            url: url,
            cacheURL: cacheURL,
            transport: { _, _ in .gone }
        )
        #expect(fetcher.fetch(currentVersion: current) == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test(".ok with unparseable body returns nil, cache untouched")
    func okParseFails() {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        NoticeCache(url: cacheURL).write(
            .init(etag: "W/\"v0\"", body: "previous", appliesToRaw: "<2.3.0", fetchedAt: 0)
        )

        let fetcher = UpdateNoticeFetcher(
            url: url,
            cacheURL: cacheURL,
            transport: { _, _ in .ok(etag: "W/\"v1\"", body: "no frontmatter here") }
        )
        #expect(fetcher.fetch(currentVersion: current) == nil)
        #expect(NoticeCache(url: cacheURL).read()?.etag == "W/\"v0\"")  // untouched
    }

    @Test(".ok with body > 64 KB returns nil, cache untouched")
    func okBodyTooLarge() {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let oversized = String(repeating: "a", count: 65 * 1024)
        let fetcher = UpdateNoticeFetcher(
            url: url,
            cacheURL: cacheURL,
            transport: { _, _ in .ok(etag: "W/\"big\"", body: oversized) }
        )
        #expect(fetcher.fetch(currentVersion: current) == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test(".notModified with non-matching cached applies-to returns nil")
    func notModifiedNoMatch() {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        NoticeCache(url: cacheURL).write(
            .init(etag: "W/\"v1\"", body: "old notice", appliesToRaw: "<2.0.0", fetchedAt: 0)
        )
        // current is 2.2.0 — above the <2.0.0 ceiling
        let fetcher = UpdateNoticeFetcher(
            url: url,
            cacheURL: cacheURL,
            transport: { _, _ in .notModified }
        )
        #expect(fetcher.fetch(currentVersion: current) == nil)
    }

    @Test(".failed + cache with non-matching applies-to returns nil")
    func failedCacheNoMatch() {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        NoticeCache(url: cacheURL).write(
            .init(etag: "W/\"v1\"", body: "old notice", appliesToRaw: "<2.0.0", fetchedAt: 0)
        )
        let fetcher = UpdateNoticeFetcher(
            url: url,
            cacheURL: cacheURL,
            transport: { _, _ in .failed }
        )
        #expect(fetcher.fetch(currentVersion: current) == nil)
    }
}
