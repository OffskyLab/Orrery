# Dynamic Update Notice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `orrery _check-update` print an optional remote notice (fetched from `docs/update-notice.md` on `main`) alongside the existing "new version available" line, so maintainers can warn specific version ranges (e.g., "upgrade via install.sh, not brew") without shipping a new binary.

**Architecture:** New `Sources/OrreryCore/Update/UpdateNoticeFetcher.swift` file housing five small types — `SemanticVersion`, `VersionConstraint`, `UpdateNotice`, `NoticeCache`, `UpdateNoticeFetcher`. The fetcher takes an injected transport closure for testability; production wires a curl-based transport. `CheckUpdateCommand` calls the fetcher only when `latest != current` and appends its return value (if any) to existing output. All errors are swallowed — fetcher returns `String?`.

**Tech Stack:** Swift 6.0, swift-testing (`@Suite`/`@Test`/`#expect`), `Process` + `/usr/bin/env curl`, JSON via `Foundation.JSONEncoder/Decoder`.

**Spec:** `docs/superpowers/specs/2026-04-18-update-notice-dynamic-prompt-design.md`

---

## File Structure

**Created:**
- `Sources/OrreryCore/Update/UpdateNoticeFetcher.swift` — all new types
- `Tests/OrreryTests/UpdateNoticeFetcherTests.swift` — unit tests
- `docs/update-notice.md` — no-op placeholder shipped initially

**Modified:**
- `Sources/OrreryCore/Commands/CheckUpdateCommand.swift` — invoke fetcher in the `latest != current` branch

No other files are touched. `$ORRERY_HOME` is resolved inline in the fetcher using the same pattern as `SetupCommand.activateFile()`.

---

## Task 1: SemanticVersion value type

**Files:**
- Create: `Sources/OrreryCore/Update/UpdateNoticeFetcher.swift`
- Test: `Tests/OrreryTests/UpdateNoticeFetcherTests.swift`

### - [ ] Step 1.1: Write the failing tests

Create `Tests/OrreryTests/UpdateNoticeFetcherTests.swift`:

```swift
import Testing
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
```

### - [ ] Step 1.2: Run tests — expect compile failure

Run:
```
swift test --filter SemanticVersion 2>&1 | head -40
```
Expected: compile error `cannot find 'SemanticVersion' in scope`.

### - [ ] Step 1.3: Implement `SemanticVersion`

Create `Sources/OrreryCore/Update/UpdateNoticeFetcher.swift`:

```swift
import Foundation

struct SemanticVersion: Equatable, Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ string: String) {
        let core = string.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? string
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
```

### - [ ] Step 1.4: Run tests — expect pass

Run:
```
swift test --filter SemanticVersion
```
Expected: 5 tests passed.

### - [ ] Step 1.5: Commit

```bash
git add Sources/OrreryCore/Update/UpdateNoticeFetcher.swift \
        Tests/OrreryTests/UpdateNoticeFetcherTests.swift
git commit -m "[FEAT] add SemanticVersion value type for update notice filtering

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: VersionConstraint

**Files:**
- Modify: `Sources/OrreryCore/Update/UpdateNoticeFetcher.swift`
- Modify: `Tests/OrreryTests/UpdateNoticeFetcherTests.swift`

### - [ ] Step 2.1: Append failing tests

Append to `Tests/OrreryTests/UpdateNoticeFetcherTests.swift`:

```swift
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
```

### - [ ] Step 2.2: Run tests — expect compile failure

Run:
```
swift test --filter VersionConstraint 2>&1 | head -40
```
Expected: `cannot find 'VersionConstraint' in scope`.

### - [ ] Step 2.3: Implement `VersionConstraint`

Append to `Sources/OrreryCore/Update/UpdateNoticeFetcher.swift`:

```swift
struct VersionConstraint: Equatable {
    enum Operator: Equatable {
        case lt, lte, eq, gte, gt
    }

    let op: Operator
    let version: SemanticVersion

    init(op: Operator, version: SemanticVersion) {
        self.op = op
        self.version = version
    }

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // Order matters: longer prefixes first
        let prefixes: [(String, Operator)] = [
            ("<=", .lte), (">=", .gte), ("<", .lt), (">", .gt), ("=", .eq)
        ]
        for (prefix, op) in prefixes where trimmed.hasPrefix(prefix) {
            let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            guard let version = SemanticVersion(rest) else { return nil }
            self.op = op
            self.version = version
            return
        }
        return nil
    }

    func isSatisfied(by current: SemanticVersion) -> Bool {
        switch op {
        case .lt:  return current <  version
        case .lte: return current <= version
        case .eq:  return current == version
        case .gte: return current >= version
        case .gt:  return current >  version
        }
    }
}
```

### - [ ] Step 2.4: Run tests — expect pass

Run:
```
swift test --filter VersionConstraint
```
Expected: 5 tests passed.

### - [ ] Step 2.5: Commit

```bash
git add Sources/OrreryCore/Update/UpdateNoticeFetcher.swift \
        Tests/OrreryTests/UpdateNoticeFetcherTests.swift
git commit -m "[FEAT] add VersionConstraint with five comparison operators

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: UpdateNotice (frontmatter parsing + applies-to check)

**Files:**
- Modify: `Sources/OrreryCore/Update/UpdateNoticeFetcher.swift`
- Modify: `Tests/OrreryTests/UpdateNoticeFetcherTests.swift`

### - [ ] Step 3.1: Append failing tests

Append to `Tests/OrreryTests/UpdateNoticeFetcherTests.swift`:

```swift
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
```

### - [ ] Step 3.2: Run tests — expect compile failure

Run:
```
swift test --filter UpdateNotice 2>&1 | head -40
```
Expected: `cannot find 'UpdateNotice' in scope`.

### - [ ] Step 3.3: Implement `UpdateNotice`

Append to `Sources/OrreryCore/Update/UpdateNoticeFetcher.swift`:

```swift
struct UpdateNotice: Equatable {
    let constraints: [VersionConstraint]
    let body: String

    static func parse(_ raw: String) -> UpdateNotice? {
        // Normalize CRLF → LF so split on "\n" works
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---" else { return nil }

        // Find the closing `---` on its own line, starting from line 1
        var closingIndex: Int? = nil
        for i in 1..<lines.count where lines[i] == "---" {
            closingIndex = i
            break
        }
        guard let closing = closingIndex else { return nil }

        // Header is lines 1..<closing; body is lines closing+1..<end
        var appliesToRaw: String? = nil
        for line in lines[1..<closing] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let colon = trimmed.firstIndex(of: ":") {
                let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if key == "applies-to" {
                    appliesToRaw = value
                }
            }
        }
        guard let rawConstraint = appliesToRaw else { return nil }

        // Parse comma-separated constraints
        let parts = rawConstraint.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var constraints: [VersionConstraint] = []
        for part in parts {
            guard let c = VersionConstraint(part) else { return nil }
            constraints.append(c)
        }
        guard !constraints.isEmpty else { return nil }

        let bodyLines = lines[(closing + 1)...]
        // Trim trailing empty lines for tidier output; leading newline is kept lean
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return UpdateNotice(constraints: constraints, body: body)
    }

    func applies(to current: SemanticVersion) -> Bool {
        constraints.allSatisfy { $0.isSatisfied(by: current) }
    }
}
```

### - [ ] Step 3.4: Run tests — expect pass

Run:
```
swift test --filter UpdateNotice
```
Expected: 8 tests passed.

### - [ ] Step 3.5: Commit

```bash
git add Sources/OrreryCore/Update/UpdateNoticeFetcher.swift \
        Tests/OrreryTests/UpdateNoticeFetcherTests.swift
git commit -m "[FEAT] add UpdateNotice frontmatter parser with applies-to filter

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: NoticeCache (JSON persistence)

**Files:**
- Modify: `Sources/OrreryCore/Update/UpdateNoticeFetcher.swift`
- Modify: `Tests/OrreryTests/UpdateNoticeFetcherTests.swift`

### - [ ] Step 4.1: Append failing tests

Append to `Tests/OrreryTests/UpdateNoticeFetcherTests.swift`:

```swift
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
```

### - [ ] Step 4.2: Run tests — expect compile failure

Run:
```
swift test --filter NoticeCache 2>&1 | head -40
```
Expected: `cannot find 'NoticeCache' in scope`.

### - [ ] Step 4.3: Implement `NoticeCache`

Append to `Sources/OrreryCore/Update/UpdateNoticeFetcher.swift`:

```swift
struct NoticeCache {
    struct Entry: Codable, Equatable {
        let etag: String?
        let body: String
        let appliesToRaw: String
        let fetchedAt: Int

        enum CodingKeys: String, CodingKey {
            case etag
            case body
            case appliesToRaw = "applies_to"
            case fetchedAt = "fetched_at"
        }
    }

    let url: URL

    init(url: URL) {
        self.url = url
    }

    func read() -> Entry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    func write(_ entry: Entry) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entry) else { return }
        // Ensure parent directory exists — callers may pass a path under
        // $ORRERY_HOME which exists, but tests pass temporaryDirectory too.
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
```

### - [ ] Step 4.4: Run tests — expect pass

Run:
```
swift test --filter NoticeCache
```
Expected: 5 tests passed.

### - [ ] Step 4.5: Commit

```bash
git add Sources/OrreryCore/Update/UpdateNoticeFetcher.swift \
        Tests/OrreryTests/UpdateNoticeFetcherTests.swift
git commit -m "[FEAT] add NoticeCache for update notice ETag persistence

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: UpdateNoticeFetcher orchestration (with injected transport)

**Files:**
- Modify: `Sources/OrreryCore/Update/UpdateNoticeFetcher.swift`
- Modify: `Tests/OrreryTests/UpdateNoticeFetcherTests.swift`

### - [ ] Step 5.1: Append failing tests

Append to `Tests/OrreryTests/UpdateNoticeFetcherTests.swift`:

```swift
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
}
```

### - [ ] Step 5.2: Run tests — expect compile failure

Run:
```
swift test --filter UpdateNoticeFetcher 2>&1 | head -40
```
Expected: `cannot find 'UpdateNoticeFetcher' in scope`.

### - [ ] Step 5.3: Implement `UpdateNoticeFetcher` and `FetchResult`

Append to `Sources/OrreryCore/Update/UpdateNoticeFetcher.swift`:

```swift
enum FetchResult {
    case ok(etag: String?, body: String)
    case notModified
    case gone
    case failed
}

struct UpdateNoticeFetcher {
    static let maxBodyBytes = 64 * 1024

    let url: URL
    let cacheURL: URL
    let transport: (URL, String?) -> FetchResult

    func fetch(currentVersion: SemanticVersion) -> String? {
        let cache = NoticeCache(url: cacheURL)
        let existing = cache.read()

        let result = transport(url, existing?.etag)

        switch result {
        case .ok(let etag, let body):
            guard body.utf8.count <= Self.maxBodyBytes else { return nil }
            guard let notice = UpdateNotice.parse(body) else { return nil }
            let appliesToRaw = notice.constraints
                .map { formatConstraint($0) }
                .joined(separator: ", ")
            cache.write(.init(
                etag: etag,
                body: notice.body,
                appliesToRaw: appliesToRaw,
                fetchedAt: Int(Date().timeIntervalSince1970)
            ))
            return notice.applies(to: currentVersion) ? notice.body : nil

        case .notModified:
            guard let cached = existing else { return nil }
            return renderFromCache(cached, current: currentVersion)

        case .gone:
            cache.delete()
            return nil

        case .failed:
            guard let cached = existing else { return nil }
            return renderFromCache(cached, current: currentVersion)
        }
    }

    private func renderFromCache(_ entry: NoticeCache.Entry, current: SemanticVersion) -> String? {
        let parts = entry.appliesToRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var constraints: [VersionConstraint] = []
        for part in parts {
            guard let c = VersionConstraint(part) else { return nil }
            constraints.append(c)
        }
        guard constraints.allSatisfy({ $0.isSatisfied(by: current) }) else { return nil }
        return entry.body
    }

    private func formatConstraint(_ c: VersionConstraint) -> String {
        let opStr: String
        switch c.op {
        case .lt:  opStr = "<"
        case .lte: opStr = "<="
        case .eq:  opStr = "="
        case .gte: opStr = ">="
        case .gt:  opStr = ">"
        }
        return "\(opStr)\(c.version.major).\(c.version.minor).\(c.version.patch)"
    }
}
```

### - [ ] Step 5.4: Run tests — expect pass

Run:
```
swift test --filter UpdateNoticeFetcher
```
Expected: 8 tests passed.

### - [ ] Step 5.5: Run full test suite to ensure no regressions

Run:
```
swift test
```
Expected: all tests pass (existing + new ~26).

### - [ ] Step 5.6: Commit

```bash
git add Sources/OrreryCore/Update/UpdateNoticeFetcher.swift \
        Tests/OrreryTests/UpdateNoticeFetcherTests.swift
git commit -m "[FEAT] add UpdateNoticeFetcher with ETag cache and fail-silent policy

Orchestrates conditional HTTP, in-memory cache, and applies-to filtering.
Transport is injected for testability; all error paths return nil.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Curl-based transport (production)

**Files:**
- Modify: `Sources/OrreryCore/Update/UpdateNoticeFetcher.swift`

No unit tests — same convention as existing `CheckUpdateCommand.fetchLatestVersion()`. This is a thin shell-out wrapper.

### - [ ] Step 6.1: Add curl transport factory

Append to `Sources/OrreryCore/Update/UpdateNoticeFetcher.swift`:

```swift
extension UpdateNoticeFetcher {
    /// Default production configuration: fetches from the repo's main branch
    /// and caches under $ORRERY_HOME/.update-notice-cache.json.
    static func production() -> UpdateNoticeFetcher {
        let defaultURL = URL(string: "https://raw.githubusercontent.com/OffskyLab/Orrery/main/docs/update-notice.md")!
        return UpdateNoticeFetcher(
            url: defaultURL,
            cacheURL: Self.defaultCacheURL(),
            transport: Self.curlTransport
        )
    }

    static func defaultCacheURL() -> URL {
        let home: URL
        if let custom = ProcessInfo.processInfo.environment["ORRERY_HOME"] {
            home = URL(fileURLWithPath: custom)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".orrery")
        }
        return home.appendingPathComponent(".update-notice-cache.json")
    }

    static let curlTransport: (URL, String?) -> FetchResult = { url, etag in
        let tmp = FileManager.default.temporaryDirectory
        let bodyFile = tmp.appendingPathComponent("orrery-notice-body-\(UUID().uuidString)")
        let hdrFile = tmp.appendingPathComponent("orrery-notice-hdr-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: bodyFile)
            try? FileManager.default.removeItem(at: hdrFile)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = [
            "curl", "-s", "--max-time", "5",
            "-D", hdrFile.path,
            "-o", bodyFile.path,
            "-w", "%{http_code}",
            "-H", "User-Agent: orrery-cli",
        ]
        if let etag = etag {
            args.append("-H")
            args.append("If-None-Match: \(etag)")
        }
        args.append(url.absoluteString)
        process.arguments = args

        let statusPipe = Pipe()
        process.standardOutput = statusPipe
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return .failed }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return .failed }

        let statusData = statusPipe.fileHandleForReading.readDataToEndOfFile()
        let statusStr = String(data: statusData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let status = Int(statusStr) else { return .failed }

        switch status {
        case 200:
            guard let body = try? String(contentsOf: bodyFile, encoding: .utf8) else {
                return .failed
            }
            let responseEtag = parseEtag(fromHeaderFile: hdrFile)
            return .ok(etag: responseEtag, body: body)
        case 304: return .notModified
        case 404: return .gone
        default:  return .failed
        }
    }

    private static func parseEtag(fromHeaderFile url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Use the LAST ETag line — if curl followed redirects, earlier headers
        // belong to redirect responses rather than the final 200.
        var latest: String? = nil
        for line in text.components(separatedBy: "\n") {
            let lower = line.lowercased()
            guard lower.hasPrefix("etag:") else { continue }
            let value = line.dropFirst("etag:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { latest = value }
        }
        return latest
    }
}
```

### - [ ] Step 6.2: Verify build

Run:
```
swift build 2>&1 | tail -20
```
Expected: `Build complete!`.

### - [ ] Step 6.3: Commit

```bash
git add Sources/OrreryCore/Update/UpdateNoticeFetcher.swift
git commit -m "[FEAT] add curl-based transport for UpdateNoticeFetcher

Uses -D to dump headers so we can recover the response ETag without
needing a second request. Following curl's own convention,
the last ETag line wins when redirects are involved.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Wire fetcher into `CheckUpdateCommand`

**Files:**
- Modify: `Sources/OrreryCore/Commands/CheckUpdateCommand.swift`

No new unit test (existing file has none; integration tested manually).

### - [ ] Step 7.1: Read the current file

Run:
```
cat Sources/OrreryCore/Commands/CheckUpdateCommand.swift
```
Confirm contents match the spec snippet (method `run()` prints notice only when `latest != current`).

### - [ ] Step 7.2: Replace `run()` to append the dynamic notice

Edit `Sources/OrreryCore/Commands/CheckUpdateCommand.swift`, replacing the current `run()` body:

```swift
public func run() throws {
    guard let latest = Self.fetchLatestVersion() else { return }
    let current = Self.currentVersion()
    guard latest != current else { return }
    print(L10n.Update.notice(current: current, latest: latest))

    // Dynamic notice — best-effort, always silent on failure.
    // Per spec: unparseable current version is treated as 0.0.0.
    let currentSemVer = SemanticVersion(current) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
    if let extra = UpdateNoticeFetcher.production().fetch(currentVersion: currentSemVer) {
        print("")
        print(extra)
    }
}
```

Leave `currentVersion()` and `fetchLatestVersion()` unchanged.

### - [ ] Step 7.3: Verify build

Run:
```
swift build 2>&1 | tail -20
```
Expected: `Build complete!`.

### - [ ] Step 7.4: Run full test suite

Run:
```
swift test
```
Expected: all tests pass.

### - [ ] Step 7.5: Manual smoke test — no notice file yet → only regular output

Run:
```
swift run orrery-bin _check-update
```
Expected: either no output (if already on latest) or exactly the `L10n.Update.notice(...)` line (the remote file doesn't exist yet → 404 → `.gone` → nil → nothing appended).

### - [ ] Step 7.6: Commit

```bash
git add Sources/OrreryCore/Commands/CheckUpdateCommand.swift
git commit -m "[FEAT] append dynamic notice to orrery _check-update output

Fetched from docs/update-notice.md on main via curl with ETag caching;
silent on any failure.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Seed the placeholder `docs/update-notice.md`

**Files:**
- Create: `docs/update-notice.md`

### - [ ] Step 8.1: Write the no-op notice

Create `docs/update-notice.md`:

```markdown
---
applies-to: <0.0.1
---
<!--
This file is fetched by `orrery _check-update` when the CLI detects a newer
release than the one installed.

Format:
  - `applies-to:` takes a comma-separated list of version constraints (logical AND).
    Supported operators: <, <=, =, >=, >. Example: `>=2.0.0, <2.3.0`.
  - The body below the closing `---` is printed verbatim to the user's terminal.

When the current value (<0.0.1) matches nobody, this file is effectively dormant.
Edit `applies-to:` and replace this comment block with a real notice when needed.
Users will see the updated message within 4 hours of their next shell command
(shell wrapper throttles `_check-update` at 14400 s — see ShellFunctionGenerator.swift).
-->
```

### - [ ] Step 8.2: Manual verification — point fetcher at the live URL after push

After merging and pushing to `main`, run on a separate machine / fresh clone:

```bash
ORRERY_HOME=$(mktemp -d) swift run orrery-bin _check-update
```

Expected (when on an older version): the `L10n.Update.notice(...)` line only — body is suppressed because `applies-to: <0.0.1` matches no real version.

(Note: this step is not actionable inside the PR itself; it verifies the feature after deploy.)

### - [ ] Step 8.3: Commit

```bash
git add docs/update-notice.md
git commit -m "[DOCS] seed empty update-notice.md (applies-to: <0.0.1)

Ships a dormant notice file so the production URL resolves 200 once
deployed. Future notices edit applies-to and replace the body.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Final verification

### - [ ] Run the full test suite one last time

```
swift test
```

Expected: all tests green, including the ~26 new ones across SemanticVersion, VersionConstraint, UpdateNotice, NoticeCache, UpdateNoticeFetcher.

### - [ ] Review the diff

```
git log --oneline main..HEAD
git diff main..HEAD --stat
```

Expected commits (in order):
1. `[FEAT] add SemanticVersion value type...`
2. `[FEAT] add VersionConstraint...`
3. `[FEAT] add UpdateNotice frontmatter parser...`
4. `[FEAT] add NoticeCache...`
5. `[FEAT] add UpdateNoticeFetcher...`
6. `[FEAT] add curl-based transport...`
7. `[FEAT] append dynamic notice to orrery _check-update...`
8. `[DOCS] seed empty update-notice.md...`

### - [ ] Check README / CHANGELOG

- `CHANGELOG.md` — add an entry under an unreleased section describing the new `_check-update` dynamic notice capability.
- `README.md` — no change needed unless there's a "how update works" section (check first).

---

## Notes for the implementer

- **Do not rename files or restructure `OrreryCore` while implementing this plan.** Scope is strictly additive.
- **`import Testing` (swift-testing) is the convention here, not XCTest.** Match it.
- **Commit messages:** the repo uses `[FEAT]`, `[DOCS]`, `[REFACTOR]` etc. tags (see recent `git log`). Match the tag style.
- **No emojis** in code, commits, or files.
- **`$ORRERY_HOME` fallback** is `$HOME/.orrery` — resolve via `ProcessInfo.processInfo.environment["ORRERY_HOME"]` as shown in `SetupCommand.activateFile()`.
- If a test fails unexpectedly, STOP and investigate. Do not skip tests, do not mark them pending, do not push with failures.
