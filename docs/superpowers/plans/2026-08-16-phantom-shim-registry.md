# Phantom Shim + Registry Implementation Plan (Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make bare `claude` phantom-supervised by default, so `orrery phantom <account>` works without the user having launched via `orrery run claude`.

**Architecture:** The supervisor `while` loop moves out of the `orrery run` shell branch and into the existing `claude()` shell function, kept deliberately thin — it calls three new hidden `orrery-bin` subcommands (`_phantom-begin` / `_phantom-next` / `_phantom-end`) at each turning point, so all volatile logic lives in testable Swift rather than in a string baked into the user's `~/.zshrc`. Supervisor state moves from a single global sentinel file plus an inherited env var to a per-supervisor registry directory under `~/.orrery/phantom/<supervisor-pid>/`, which fixes a multi-session race that this change would otherwise turn from rare into routine, and lets `orrery phantom` be invoked from outside the process chain.

**Tech Stack:** Swift 6, swift-tools-version 6.0, macOS 15+, ArgumentParser, swift-testing (`import Testing`, `@Suite`/`@Test`/`#expect`).

**Spec:** `docs/superpowers/specs/2026-08-16-phantom-shim-registry-design.md`

## Global Constraints

- **Test framework is swift-testing**, not XCTest. Suites are `struct` with `@Suite("Name")`, tests are `@Test("description")`, assertions are `#expect(...)`. Follow `Tests/OrreryTests/PhantomTriggerTests.swift` for the established shape (per-test tmp dir in `init() throws`, `EnvironmentStore(homeURL: tmpDir)`).
- **Never use `EnvironmentStore.default` in tests.** Always construct `EnvironmentStore(homeURL: tmpDir)` with a unique temp directory, as existing tests do. Tests that touch the real `~/.orrery` will corrupt the developer's state.
- **Every new user-facing string must be localized or the build fails.** Adding a key requires editing all four of: `Sources/OrreryCore/Resources/Localization/en.json` (authoritative key set), `zh-Hant.json`, `ja.json`, and `l10n-signatures.json`. The `L10nCodegen` build plugin validates that every locale has exactly the `en.json` key set with matching placeholders. Internal/debug strings printed to stderr do **not** need localization.
- **Hidden subcommands must be registered** in `OrreryCommand.hiddenSubcommands` (`Sources/orrery/OrreryCommand.swift:60`), not in a visible `CommandGroup`.
- **Commit message convention:** `[FEAT]`, `[FIX]`, `[UPDATE]`, `[DOCS]` prefix in brackets. **Do not add a `Co-Authored-By` trailer** — this repo has none and they were deliberately purged.
- **Registry root is `<EnvironmentStore.homeURL>/phantom`**, never a hardcoded `~/.orrery`, so `ORRERY_HOME` and tests stay isolated.
- **Nothing in this feature may block launching claude.** Any failure in `_phantom-begin` must exit non-zero so the shell falls through to a plain launch. Errors are best-effort and silent on stdout (stderr is acceptable).
- Build with `swift build`; run tests with `swift test`. Filter with `swift test --filter <SuiteName>`.

---

### Task 1: PhantomEntry model + PhantomRegistry storage

**Files:**
- Create: `Sources/OrreryCore/Phantom/PhantomEntry.swift`
- Create: `Sources/OrreryCore/Phantom/PhantomRegistry.swift`
- Test: `Tests/OrreryTests/PhantomRegistryTests.swift`

**Interfaces:**
- Consumes: `EnvironmentStore.homeURL` (existing, `Sources/OrreryCore/Storage/EnvironmentStore.swift:9`)
- Produces:
  - `PhantomEntry` struct with `schema/supervisorPid/supervisorStartedAt/tool/tty/cwd/workspace/account/sessionId/sessionIdSource/updatedAt`
  - `PhantomEntry.SessionIdSource` enum (`.hook`, `.probe`)
  - `PhantomRegistry(homeURL:)`, `.entryDirURL(id:)`, `.sentinelURL(id:)`, `.write(_:id:)`, `.read(id:)`, `.remove(id:)`, `.liveEntries(isAlive:)`

- [ ] **Step 1: Write the failing test**

Create `Tests/OrreryTests/PhantomRegistryTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("PhantomRegistry")
struct PhantomRegistryTests {
    var tmpDir: URL!
    var registry: PhantomRegistry!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-phantom-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        registry = PhantomRegistry(homeURL: tmpDir)
    }

    private func sampleEntry(pid: Int32 = 4242, startedAt: Double = 100.0) -> PhantomEntry {
        PhantomEntry(
            supervisorPid: pid,
            supervisorStartedAt: startedAt,
            tool: "claude",
            tty: "/dev/ttys004",
            cwd: "/tmp/project",
            workspace: "origin",
            account: "work",
            sessionId: nil,
            sessionIdSource: .probe,
            updatedAt: 100.0
        )
    }

    @Test("write then read round-trips every field")
    func roundTrip() throws {
        let entry = sampleEntry()
        try registry.write(entry, id: "4242")

        let loaded = try #require(registry.read(id: "4242"))
        #expect(loaded.schema == 1)
        #expect(loaded.supervisorPid == 4242)
        #expect(loaded.supervisorStartedAt == 100.0)
        #expect(loaded.tool == "claude")
        #expect(loaded.tty == "/dev/ttys004")
        #expect(loaded.cwd == "/tmp/project")
        #expect(loaded.workspace == "origin")
        #expect(loaded.account == "work")
        #expect(loaded.sessionId == nil)
        #expect(loaded.sessionIdSource == .probe)
    }

    @Test("meta.json uses snake_case keys so it is readable outside Swift")
    func snakeCaseKeys() throws {
        try registry.write(sampleEntry(), id: "4242")
        let text = try String(
            contentsOf: registry.entryDirURL(id: "4242").appendingPathComponent("meta.json"),
            encoding: .utf8)
        #expect(text.contains("\"supervisor_pid\""))
        #expect(text.contains("\"supervisor_started_at\""))
        #expect(text.contains("\"session_id_source\""))
    }

    @Test("registry root is under homeURL/phantom, isolated per ORRERY_HOME")
    func rootLocation() throws {
        try registry.write(sampleEntry(), id: "4242")
        let expected = tmpDir.appendingPathComponent("phantom").appendingPathComponent("4242")
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    @Test("sentinel lives inside the entry dir, not globally")
    func sentinelIsPerEntry() {
        let url = registry.sentinelURL(id: "4242")
        #expect(url.lastPathComponent == "sentinel")
        #expect(url.deletingLastPathComponent().lastPathComponent == "4242")
    }

    @Test("read returns nil for an unknown id")
    func readMissing() {
        #expect(registry.read(id: "9999") == nil)
    }

    @Test("remove deletes the whole entry dir including its sentinel")
    func removeDeletesDir() throws {
        try registry.write(sampleEntry(), id: "4242")
        try "SESSION_ID='x'\n".write(to: registry.sentinelURL(id: "4242"),
                                    atomically: true, encoding: .utf8)
        registry.remove(id: "4242")
        #expect(!FileManager.default.fileExists(atPath: registry.entryDirURL(id: "4242").path))
    }

    @Test("liveEntries keeps live entries and deletes dead ones")
    func liveEntriesPrunes() throws {
        try registry.write(sampleEntry(pid: 100, startedAt: 1.0), id: "100")
        try registry.write(sampleEntry(pid: 200, startedAt: 2.0), id: "200")

        let live = registry.liveEntries { pid, _ in pid == 100 }

        #expect(live.count == 1)
        #expect(live[0].id == "100")
        #expect(FileManager.default.fileExists(atPath: registry.entryDirURL(id: "100").path))
        #expect(!FileManager.default.fileExists(atPath: registry.entryDirURL(id: "200").path))
    }

    @Test("liveEntries treats a recycled pid as dead by comparing start time")
    func pidRecycleGuard() throws {
        try registry.write(sampleEntry(pid: 300, startedAt: 50.0), id: "300")

        // pid 300 is alive, but it started at a different time — a different process.
        let live = registry.liveEntries { pid, startedAt in pid == 300 && startedAt == 50.0 }
        #expect(live.count == 1)

        try registry.write(sampleEntry(pid: 300, startedAt: 50.0), id: "300")
        let recycled = registry.liveEntries { pid, startedAt in pid == 300 && startedAt == 999.0 }
        #expect(recycled.isEmpty)
    }

    @Test("liveEntries ignores an entry dir with unreadable meta.json")
    func corruptEntryIsPruned() throws {
        let dir = registry.entryDirURL(id: "500")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json".write(to: dir.appendingPathComponent("meta.json"),
                             atomically: true, encoding: .utf8)
        let live = registry.liveEntries { _, _ in true }
        #expect(live.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("liveEntries on a missing registry root returns empty, not an error")
    func missingRoot() {
        let empty = PhantomRegistry(homeURL: tmpDir.appendingPathComponent("nope"))
        #expect(empty.liveEntries { _, _ in true }.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PhantomRegistry`
Expected: FAIL — compile error, `cannot find 'PhantomRegistry' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OrreryCore/Phantom/PhantomEntry.swift`:

```swift
import Foundation

/// One supervised tool session, persisted at
/// `<home>/phantom/<supervisor-pid>/meta.json`.
///
/// `supervisorStartedAt` exists to defeat pid recycling: a pid alone is not a
/// stable identity, so liveness is "pid responds to signal 0 AND its start
/// time still matches what we recorded". Without it, a crashed supervisor's
/// leftover directory could be mistaken for an unrelated new process that
/// happened to get the same pid.
public struct PhantomEntry: Codable, Sendable, Equatable {
    public enum SessionIdSource: String, Codable, Sendable {
        /// Authoritative — reported by claude's own SessionStart hook.
        case hook
        /// Best-effort — inferred by scanning session files by mtime.
        case probe
    }

    public var schema: Int
    public var supervisorPid: Int32
    public var supervisorStartedAt: Double
    public var tool: String
    public var tty: String?
    public var cwd: String
    public var workspace: String?
    public var account: String?
    public var sessionId: String?
    public var sessionIdSource: SessionIdSource
    public var updatedAt: Double

    public init(
        schema: Int = 1,
        supervisorPid: Int32,
        supervisorStartedAt: Double,
        tool: String,
        tty: String?,
        cwd: String,
        workspace: String?,
        account: String?,
        sessionId: String?,
        sessionIdSource: SessionIdSource,
        updatedAt: Double
    ) {
        self.schema = schema
        self.supervisorPid = supervisorPid
        self.supervisorStartedAt = supervisorStartedAt
        self.tool = tool
        self.tty = tty
        self.cwd = cwd
        self.workspace = workspace
        self.account = account
        self.sessionId = sessionId
        self.sessionIdSource = sessionIdSource
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case supervisorPid = "supervisor_pid"
        case supervisorStartedAt = "supervisor_started_at"
        case tool
        case tty
        case cwd
        case workspace
        case account
        case sessionId = "session_id"
        case sessionIdSource = "session_id_source"
        case updatedAt = "updated_at"
    }
}
```

Create `Sources/OrreryCore/Phantom/PhantomRegistry.swift`:

```swift
import Foundation

/// Read/write access to the phantom supervisor registry.
///
/// Layout — one directory per live supervisor:
///
///     <home>/phantom/<supervisor-pid>/meta.json
///     <home>/phantom/<supervisor-pid>/sentinel
///
/// The sentinel is per-entry on purpose. It used to be a single global
/// `<home>/.phantom-sentinel`, which meant two concurrent claude sessions
/// would read each other's switch requests and resume into the wrong
/// conversation.
///
/// There is no separate GC pass: `liveEntries` prunes dead entries as a side
/// effect of every read, which is the only time staleness can matter.
public struct PhantomRegistry: Sendable {
    public let rootURL: URL

    public init(homeURL: URL) {
        self.rootURL = homeURL.appendingPathComponent("phantom")
    }

    public func entryDirURL(id: String) -> URL {
        rootURL.appendingPathComponent(id)
    }

    public func metaURL(id: String) -> URL {
        entryDirURL(id: id).appendingPathComponent("meta.json")
    }

    public func sentinelURL(id: String) -> URL {
        entryDirURL(id: id).appendingPathComponent("sentinel")
    }

    public func write(_ entry: PhantomEntry, id: String) throws {
        try FileManager.default.createDirectory(
            at: entryDirURL(id: id), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(entry).write(to: metaURL(id: id), options: .atomic)
    }

    public func read(id: String) -> PhantomEntry? {
        guard let data = try? Data(contentsOf: metaURL(id: id)) else { return nil }
        return try? JSONDecoder().decode(PhantomEntry.self, from: data)
    }

    public func remove(id: String) {
        try? FileManager.default.removeItem(at: entryDirURL(id: id))
    }

    /// Every live entry, pruning any that are dead or unreadable.
    ///
    /// `isAlive` is injected rather than called directly so the pid-recycling
    /// logic is testable without spawning real processes.
    public func liveEntries(
        isAlive: (Int32, Double) -> Bool
    ) -> [(id: String, entry: PhantomEntry)] {
        guard let ids = try? FileManager.default.contentsOfDirectory(
            atPath: rootURL.path) else { return [] }

        var result: [(id: String, entry: PhantomEntry)] = []
        for id in ids.sorted() {
            guard let entry = read(id: id) else {
                // Unreadable or corrupt — nothing can use it, so drop it.
                remove(id: id)
                continue
            }
            if isAlive(entry.supervisorPid, entry.supervisorStartedAt) {
                result.append((id: id, entry: entry))
            } else {
                remove(id: id)
            }
        }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PhantomRegistry`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Phantom/ Tests/OrreryTests/PhantomRegistryTests.swift
git commit -m "[FEAT] add phantom registry with per-supervisor entries

Replaces the single global sentinel with one directory per supervisor.
Liveness compares pid AND process start time so a recycled pid can't
resurrect a dead supervisor's entry."
```

---

### Task 2: ProcessLiveness — real pid + start-time lookup

**Files:**
- Create: `Sources/OrreryCore/Phantom/ProcessLiveness.swift`
- Test: `Tests/OrreryTests/ProcessLivenessTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `ProcessLiveness.startTime(pid: Int32) -> Double?`, `ProcessLiveness.isAlive(pid: Int32, startedAt: Double) -> Bool`. Task 5, 8 and 11 pass `ProcessLiveness.isAlive` as the `isAlive` closure to `PhantomRegistry.liveEntries`.

- [ ] **Step 1: Write the failing test**

Create `Tests/OrreryTests/ProcessLivenessTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("ProcessLiveness")
struct ProcessLivenessTests {
    @Test("start time of the current process is readable and positive")
    func selfStartTime() throws {
        let t = try #require(ProcessLiveness.startTime(pid: getpid()))
        #expect(t > 0)
    }

    @Test("start time is stable across repeated reads")
    func stable() throws {
        let a = try #require(ProcessLiveness.startTime(pid: getpid()))
        let b = try #require(ProcessLiveness.startTime(pid: getpid()))
        #expect(a == b)
    }

    @Test("current process is alive when start time matches")
    func aliveWhenMatching() throws {
        let t = try #require(ProcessLiveness.startTime(pid: getpid()))
        #expect(ProcessLiveness.isAlive(pid: getpid(), startedAt: t))
    }

    @Test("current process is not alive when start time differs (pid recycled)")
    func deadWhenStartTimeDiffers() {
        #expect(!ProcessLiveness.isAlive(pid: getpid(), startedAt: 1.0))
    }

    @Test("start time of a nonexistent pid is nil")
    func missingPid() {
        // pid 0 is the kernel/swapper; KERN_PROC_PID lookup for it yields no
        // usable kinfo_proc for our purposes.
        #expect(ProcessLiveness.startTime(pid: -1) == nil)
    }

    @Test("nonexistent pid is not alive")
    func missingPidNotAlive() {
        #expect(!ProcessLiveness.isAlive(pid: -1, startedAt: 1.0))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProcessLiveness`
Expected: FAIL — `cannot find 'ProcessLiveness' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OrreryCore/Phantom/ProcessLiveness.swift`:

```swift
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Process identity that survives pid recycling.
///
/// A pid on its own is not an identity — the kernel hands the same number out
/// again once a process is reaped. Pairing it with the process's start time
/// (`kinfo_proc.kp_proc.p_starttime`) gives a stable identity, which is the
/// standard pidfile technique.
public enum ProcessLiveness {

    /// Process start time as seconds since the epoch, or nil if the pid does
    /// not resolve.
    public static func startTime(pid: Int32) -> Double? {
        #if canImport(Darwin)
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var procInfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride

        let result = mib.withUnsafeMutableBufferPointer { mibPtr in
            withUnsafeMutablePointer(to: &procInfo) { infoPtr in
                infoPtr.withMemoryRebound(to: CChar.self, capacity: size) { bytes in
                    sysctl(mibPtr.baseAddress, 4, bytes, &size, nil, 0)
                }
            }
        }
        // size == 0 means the pid resolved to nothing (already reaped).
        guard result == 0, size > 0 else { return nil }

        let tv = procInfo.kp_proc.p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000.0
        #else
        return nil
        #endif
    }

    /// Whether `pid` is the same process we recorded.
    ///
    /// The tolerance absorbs float round-tripping through JSON; start times
    /// are microsecond-resolution, so anything within a second is the same
    /// process in practice.
    public static func isAlive(pid: Int32, startedAt: Double, tolerance: Double = 1.0) -> Bool {
        guard let actual = startTime(pid: pid) else { return false }
        return abs(actual - startedAt) <= tolerance
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProcessLiveness`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Phantom/ProcessLiveness.swift Tests/OrreryTests/ProcessLivenessTests.swift
git commit -m "[FEAT] add ProcessLiveness for pid-recycle-safe identity"
```

---

### Task 3: Per-supervisor sentinel in PhantomSupport

**Files:**
- Modify: `Sources/OrreryCore/Commands/PhantomSupport.swift:50-90`
- Modify: `Tests/OrreryTests/PhantomSentinelTests.swift`
- Modify: `Tests/OrreryTests/PhantomTriggerTests.swift`
- Create: `Sources/OrreryCore/Phantom/ShellQuote.swift`
- Test: `Tests/OrreryTests/ShellQuoteTests.swift`

**Interfaces:**
- Consumes: `PhantomRegistry.sentinelURL(id:)` from Task 1.
- Produces:
  - `ShellQuote.single(_ s: String) -> String`
  - `PhantomSupport.writeSentinel(targetAccountTool:targetAccountName:sessionId:to url: URL)` — now takes an explicit destination URL instead of deriving one global path from the store.
  - `PhantomSupport.readSentinel(at url: URL) -> (tool: String?, name: String?, sessionId: String?)?`

- [ ] **Step 1: Write the failing test**

Create `Tests/OrreryTests/ShellQuoteTests.swift`:

```swift
import Testing
@testable import OrreryCore

@Suite("ShellQuote")
struct ShellQuoteTests {
    @Test("plain text is wrapped in single quotes")
    func plain() {
        #expect(ShellQuote.single("work") == "'work'")
    }

    @Test("embedded single quote is escaped so the shell sees one literal quote")
    func embeddedQuote() {
        #expect(ShellQuote.single("it's") == #"'it'\''s'"#)
    }

    @Test("shell metacharacters are inert inside single quotes")
    func metacharacters() {
        #expect(ShellQuote.single("a b; rm -rf /") == "'a b; rm -rf /'")
        #expect(ShellQuote.single("$(whoami)") == "'$(whoami)'")
    }

    @Test("empty string quotes to an empty pair")
    func empty() {
        #expect(ShellQuote.single("") == "''")
    }
}
```

Append to `Tests/OrreryTests/PhantomSentinelTests.swift` inside the existing suite:

```swift
    @Test("sentinel round-trips through readSentinel")
    func sentinelReadBack() throws {
        let url = tmpDir.appendingPathComponent("sentinel")
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "work",
            sessionId: "sess-1", to: url)

        let parsed = try #require(PhantomSupport.readSentinel(at: url))
        #expect(parsed.tool == "claude")
        #expect(parsed.name == "work")
        #expect(parsed.sessionId == "sess-1")
    }

    @Test("readSentinel returns nil when the file is absent")
    func sentinelReadMissing() {
        #expect(PhantomSupport.readSentinel(
            at: tmpDir.appendingPathComponent("nope")) == nil)
    }

    @Test("empty SESSION_ID reads back as nil, not empty string")
    func sentinelEmptySession() throws {
        let url = tmpDir.appendingPathComponent("sentinel")
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "work",
            sessionId: nil, to: url)
        let parsed = try #require(PhantomSupport.readSentinel(at: url))
        #expect(parsed.sessionId == nil)
    }

    @Test("account name containing a single quote survives the round trip")
    func sentinelQuoteInName() throws {
        let url = tmpDir.appendingPathComponent("sentinel")
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "o'brien",
            sessionId: nil, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(#"TARGET_ACCOUNT_NAME='o'\''brien'"#))
        let parsed = try #require(PhantomSupport.readSentinel(at: url))
        #expect(parsed.name == "o'brien")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ShellQuote && swift test --filter PhantomSentinel`
Expected: FAIL — `cannot find 'ShellQuote' in scope`, and `writeSentinel` has no `to:` parameter.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OrreryCore/Phantom/ShellQuote.swift`:

```swift
import Foundation

/// Single-quoting for values crossing the Swift → shell boundary.
///
/// Everything orrery hands back for the shell to `eval` or `.` goes through
/// here. Inside single quotes the shell treats every character literally, so
/// the only thing needing escaping is a single quote itself: close the quote,
/// emit an escaped quote, reopen.
public enum ShellQuote {
    public static func single(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
```

Replace the sentinel section of `Sources/OrreryCore/Commands/PhantomSupport.swift` (the `sentinelURL`, `writeSentinel` and `shellEscape` members, lines 50-90) with:

```swift
    // MARK: - Sentinel

    /// Sentinel format is shell-sourceable so the supervisor loop can simply
    /// `. "$sentinel"` to read it. Single-quoted values guard against names
    /// containing shell metacharacters (account names are validated
    /// elsewhere, but be defensive at the IPC boundary).
    ///
    /// `SESSION_ID` is always emitted (empty string when nil); the account
    /// fields are only emitted when non-nil.
    ///
    /// The destination is passed in rather than derived: sentinels live inside
    /// a supervisor's own registry directory, because a single shared path let
    /// concurrent sessions read each other's switch requests.
    public static func writeSentinel(
        targetAccountTool: String?,
        targetAccountName: String?,
        sessionId: String?,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var lines: [String] = []
        if let targetAccountTool {
            lines.append("TARGET_ACCOUNT_TOOL=\(ShellQuote.single(targetAccountTool))")
        }
        if let targetAccountName {
            lines.append("TARGET_ACCOUNT_NAME=\(ShellQuote.single(targetAccountName))")
        }
        lines.append("SESSION_ID=\(ShellQuote.single(sessionId ?? ""))")
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Parse a sentinel written by `writeSentinel`. Returns nil when the file
    /// is absent or unreadable. An empty `SESSION_ID` reads back as nil so
    /// callers never have to special-case the empty string.
    public static func readSentinel(
        at url: URL
    ) -> (tool: String?, name: String?, sessionId: String?)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            var value = String(line[line.index(after: eq)...])
            if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                value = value.replacingOccurrences(of: #"'\''"#, with: "'")
            }
            values[key] = value
        }
        let session = values["SESSION_ID"]
        return (
            tool: values["TARGET_ACCOUNT_TOOL"],
            name: values["TARGET_ACCOUNT_NAME"],
            sessionId: (session?.isEmpty ?? true) ? nil : session
        )
    }
```

Then fix the two existing call sites that break:

- In `Tests/OrreryTests/PhantomSentinelTests.swift` and `Tests/OrreryTests/PhantomTriggerTests.swift`, every existing `writeSentinel(..., store: store)` call becomes `writeSentinel(..., to: tmpDir.appendingPathComponent("sentinel"))`, and every `PhantomSupport.sentinelURL(store: store)` becomes `tmpDir.appendingPathComponent("sentinel")`.
- In `Sources/OrreryCore/Commands/PhantomAccountTriggerCommand.swift`, the `writeSentinel`/`removeItem` calls will not compile yet — Task 8 rewrites them. For this task only, keep it compiling by passing `PhantomRegistry(homeURL: store.homeURL).sentinelURL(id: supervisorPidStr)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build && swift test --filter ShellQuote && swift test --filter Phantom`
Expected: PASS — all ShellQuote, PhantomSentinel, PhantomTrigger and PhantomAccountTrigger tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore Tests/OrreryTests
git commit -m "[FIX] make the phantom sentinel per-supervisor

A single global ~/.orrery/.phantom-sentinel meant two concurrent claude
sessions read each other's switch requests, applying the wrong account
and resuming into the wrong conversation."
```

---

### Task 4: PhantomLaunchPolicy — which `claude` invocations get supervised

**Files:**
- Create: `Sources/OrreryCore/Phantom/PhantomLaunchPolicy.swift`
- Test: `Tests/OrreryTests/PhantomLaunchPolicyTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `PhantomLaunchPolicy.shouldSupervise(args: [String], stdinIsTTY: Bool, stdoutIsTTY: Bool) -> Bool` and `PhantomLaunchPolicy.nonSessionSubcommands: Set<String>`. Task 5 calls this.

- [ ] **Step 1: Write the failing test**

Create `Tests/OrreryTests/PhantomLaunchPolicyTests.swift`:

```swift
import Testing
@testable import OrreryCore

@Suite("PhantomLaunchPolicy")
struct PhantomLaunchPolicyTests {
    private func decide(_ args: [String], tty: Bool = true) -> Bool {
        PhantomLaunchPolicy.shouldSupervise(args: args, stdinIsTTY: tty, stdoutIsTTY: tty)
    }

    @Test("a bare interactive launch is supervised")
    func bareLaunch() {
        #expect(decide([]))
    }

    @Test("an interactive launch with an initial prompt is supervised")
    func initialPrompt() {
        #expect(decide(["explain this repo"]))
    }

    @Test("--resume is supervised — it is still an interactive session")
    func resumeIsSupervised() {
        #expect(decide(["--resume", "abc-123"]))
    }

    @Test("-p is not supervised: one-shot non-interactive mode")
    func shortPrintFlag() {
        #expect(!decide(["-p", "hello"]))
    }

    @Test("--print is not supervised")
    func longPrintFlag() {
        #expect(!decide(["--print", "hello"]))
    }

    @Test("non-session subcommands are not supervised")
    func subcommands() {
        for sub in ["mcp", "update", "doctor", "config", "install",
                    "plugin", "setup-token", "migrate-installer"] {
            #expect(!decide([sub]), "\(sub) should not be supervised")
        }
    }

    @Test("a subcommand behind a global flag is still detected")
    func subcommandAfterFlag() {
        #expect(!decide(["--debug", "mcp", "list"]))
    }

    @Test("a flag's value is not mistaken for a subcommand")
    func flagValueIsNotASubcommand() {
        // `--model config` must not be read as the `config` subcommand.
        #expect(decide(["--model", "config"]))
    }

    @Test("non-tty stdin is not supervised (piped input)")
    func pipedStdin() {
        #expect(!PhantomLaunchPolicy.shouldSupervise(
            args: [], stdinIsTTY: false, stdoutIsTTY: true))
    }

    @Test("non-tty stdout is not supervised (output redirected)")
    func redirectedStdout() {
        #expect(!PhantomLaunchPolicy.shouldSupervise(
            args: [], stdinIsTTY: true, stdoutIsTTY: false))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PhantomLaunchPolicy`
Expected: FAIL — `cannot find 'PhantomLaunchPolicy' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OrreryCore/Phantom/PhantomLaunchPolicy.swift`:

```swift
import Foundation

/// Decides whether a given `claude` invocation is an interactive session
/// worth supervising.
///
/// This lives in Swift rather than in the generated shell function on
/// purpose: the shell integration is written into the user's rc file and only
/// changes when they re-run `orrery setup`, so anything likely to need
/// updating — like the subcommand list below — belongs behind the binary.
public enum PhantomLaunchPolicy {

    /// `claude` subcommands that do not start a conversation. Supervising one
    /// would relaunch a utility command in a loop.
    public static let nonSessionSubcommands: Set<String> = [
        "mcp", "update", "doctor", "config", "install",
        "plugin", "setup-token", "migrate-installer",
    ]

    /// Flags that take a value, so the token after them must not be read as a
    /// subcommand.
    private static let valueTakingFlags: Set<String> = [
        "--model", "--resume", "-r", "--settings", "--add-dir",
        "--allowed-tools", "--disallowed-tools", "--permission-mode",
        "--append-system-prompt", "--mcp-config", "--session-id",
    ]

    public static func shouldSupervise(
        args: [String],
        stdinIsTTY: Bool,
        stdoutIsTTY: Bool
    ) -> Bool {
        // A supervisor loop only makes sense around an interactive TUI.
        guard stdinIsTTY, stdoutIsTTY else { return false }

        // One-shot print mode exits immediately; relaunching it would loop.
        if args.contains("-p") || args.contains("--print") { return false }

        if let sub = firstPositional(args), nonSessionSubcommands.contains(sub) {
            return false
        }

        return true
    }

    /// The first token that is neither a flag nor a flag's value.
    private static func firstPositional(_ args: [String]) -> String? {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if valueTakingFlags.contains(arg) {
                index += 2
                continue
            }
            if arg.hasPrefix("-") {
                index += 1
                continue
            }
            return arg
        }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PhantomLaunchPolicy`
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Phantom/PhantomLaunchPolicy.swift Tests/OrreryTests/PhantomLaunchPolicyTests.swift
git commit -m "[FEAT] add PhantomLaunchPolicy to decide which claude launches are supervised"
```

---

### Task 5: `_phantom-begin` subcommand

**Files:**
- Create: `Sources/OrreryCore/Commands/PhantomBeginCommand.swift`
- Modify: `Sources/orrery/OrreryCommand.swift:60-71`
- Test: `Tests/OrreryTests/PhantomBeginCommandTests.swift`

**Interfaces:**
- Consumes: `PhantomEntry`, `PhantomRegistry` (Task 1), `ProcessLiveness.startTime` (Task 2), `PhantomLaunchPolicy.shouldSupervise` (Task 4), `ShellQuote.single` (Task 3).
- Produces:
  - `PhantomBeginCommand` (`_phantom-begin`), flags `--tool <name>`, `--supervisor-pid <pid>`, trailing `-- <args...>`
  - `PhantomBeginCommand.exportScript(id:dirURL:) -> String` — the stdout payload, extracted so it is testable without running the command.
  - Env contract: `ORRERY_PHANTOM_ID`, `ORRERY_PHANTOM_DIR`.

- [ ] **Step 1: Write the failing test**

Create `Tests/OrreryTests/PhantomBeginCommandTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("PhantomBeginCommand")
struct PhantomBeginCommandTests {
    var tmpDir: URL!
    var registry: PhantomRegistry!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-phantom-begin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        registry = PhantomRegistry(homeURL: tmpDir)
    }

    @Test("export script assigns both env vars with quoted values")
    func exportScript() {
        let script = PhantomBeginCommand.exportScript(
            id: "4242", dirURL: URL(fileURLWithPath: "/tmp/o rrery/phantom/4242"))
        #expect(script.contains("export ORRERY_PHANTOM_ID='4242'"))
        #expect(script.contains("export ORRERY_PHANTOM_DIR='/tmp/o rrery/phantom/4242'"))
    }

    @Test("begin writes an entry keyed by the supervisor pid")
    func writesEntry() throws {
        try PhantomBeginCommand.begin(
            tool: "claude",
            supervisorPid: 4242,
            supervisorStartedAt: 123.5,
            cwd: "/tmp/project",
            tty: "/dev/ttys004",
            workspace: "origin",
            account: "work",
            registry: registry)

        let entry = try #require(registry.read(id: "4242"))
        #expect(entry.supervisorPid == 4242)
        #expect(entry.supervisorStartedAt == 123.5)
        #expect(entry.tool == "claude")
        #expect(entry.cwd == "/tmp/project")
        #expect(entry.tty == "/dev/ttys004")
        #expect(entry.workspace == "origin")
        #expect(entry.account == "work")
        #expect(entry.sessionId == nil)
        #expect(entry.sessionIdSource == .probe)
    }

    @Test("begin overwrites a stale entry left by a recycled pid")
    func overwritesStale() throws {
        try PhantomBeginCommand.begin(
            tool: "claude", supervisorPid: 4242, supervisorStartedAt: 1.0,
            cwd: "/old", tty: nil, workspace: nil, account: nil, registry: registry)
        try PhantomBeginCommand.begin(
            tool: "claude", supervisorPid: 4242, supervisorStartedAt: 2.0,
            cwd: "/new", tty: nil, workspace: nil, account: nil, registry: registry)

        let entry = try #require(registry.read(id: "4242"))
        #expect(entry.cwd == "/new")
        #expect(entry.supervisorStartedAt == 2.0)
    }

    @Test("begin removes the legacy global sentinel if one is left over")
    func removesLegacySentinel() throws {
        let legacy = tmpDir.appendingPathComponent(".phantom-sentinel")
        try "SESSION_ID=''\n".write(to: legacy, atomically: true, encoding: .utf8)

        PhantomBeginCommand.removeLegacySentinel(homeURL: tmpDir)

        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PhantomBeginCommand`
Expected: FAIL — `cannot find 'PhantomBeginCommand' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OrreryCore/Commands/PhantomBeginCommand.swift`:

```swift
import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// `orrery-bin _phantom-begin --tool claude --supervisor-pid $$ -- <args...>`
///
/// Called by the `claude()` shell function before its supervisor loop starts.
/// Registers the supervisor and prints shell `export` lines for the caller to
/// `eval`. Exits non-zero when this invocation should not be supervised, which
/// the shell treats as "just launch normally" — a failure here must never stop
/// the user launching claude.
///
/// `--supervisor-pid` is required rather than inferred: this runs inside a
/// `$(...)` command substitution, which forks a subshell, so `getppid()` would
/// see that transient subshell rather than the interactive shell that owns the
/// loop. `$$` in bash and zsh stays the original shell's pid inside a subshell,
/// so the shell passes it explicitly.
public struct PhantomBeginCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_phantom-begin",
        shouldDisplay: false
    )

    @Option(name: .long) public var tool: String = "claude"
    @Option(name: .long) public var supervisorPid: Int32

    @Argument(parsing: .allUnrecognized) public var args: [String] = []

    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default

        guard PhantomLaunchPolicy.shouldSupervise(
            args: args,
            stdinIsTTY: isatty(0) == 1,
            stdoutIsTTY: isatty(1) == 1
        ) else {
            throw ExitCode.failure
        }

        guard let startedAt = ProcessLiveness.startTime(pid: supervisorPid) else {
            throw ExitCode.failure
        }

        Self.removeLegacySentinel(homeURL: store.homeURL)

        let registry = PhantomRegistry(homeURL: store.homeURL)
        let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
        let toolEnum = Tool(rawValue: tool)
        let account = toolEnum.flatMap {
            try? RunCommand.resolvePinnedAccount(tool: $0, envName: envName)?.account.displayName
        } ?? nil

        do {
            try Self.begin(
                tool: tool,
                supervisorPid: supervisorPid,
                supervisorStartedAt: startedAt,
                cwd: FileManager.default.currentDirectoryPath,
                tty: Self.currentTTY(),
                workspace: envName,
                account: account,
                registry: registry)
        } catch {
            // Registry unavailable — degrade to an unsupervised launch rather
            // than blocking the user.
            throw ExitCode.failure
        }

        let id = String(supervisorPid)
        print(Self.exportScript(id: id, dirURL: registry.entryDirURL(id: id)))
    }

    // MARK: - Testable pieces

    static func begin(
        tool: String,
        supervisorPid: Int32,
        supervisorStartedAt: Double,
        cwd: String,
        tty: String?,
        workspace: String?,
        account: String?,
        registry: PhantomRegistry
    ) throws {
        let entry = PhantomEntry(
            supervisorPid: supervisorPid,
            supervisorStartedAt: supervisorStartedAt,
            tool: tool,
            tty: tty,
            cwd: cwd,
            workspace: workspace,
            account: account,
            sessionId: nil,
            sessionIdSource: .probe,
            updatedAt: Date().timeIntervalSince1970)
        try registry.write(entry, id: String(supervisorPid))
    }

    static func exportScript(id: String, dirURL: URL) -> String {
        """
        export ORRERY_PHANTOM_ID=\(ShellQuote.single(id))
        export ORRERY_PHANTOM_DIR=\(ShellQuote.single(dirURL.path))
        """
    }

    /// Pre-registry builds used one shared `<home>/.phantom-sentinel`. Drop it
    /// on the first supervised launch so a leftover never fires unexpectedly.
    static func removeLegacySentinel(homeURL: URL) {
        try? FileManager.default.removeItem(
            at: homeURL.appendingPathComponent(".phantom-sentinel"))
    }

    static func currentTTY() -> String? {
        guard isatty(0) == 1, let name = ttyname(0) else { return nil }
        return String(cString: name)
    }
}
```

Register it in `Sources/orrery/OrreryCommand.swift` by adding `PhantomBeginCommand.self` to the `hiddenSubcommands` array that starts at line 61.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build && swift test --filter PhantomBeginCommand`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Commands/PhantomBeginCommand.swift Sources/orrery/OrreryCommand.swift Tests/OrreryTests/PhantomBeginCommandTests.swift
git commit -m "[FEAT] add _phantom-begin to register a supervisor"
```

---

### Task 6: `_phantom-next` and `_phantom-end` subcommands

**Files:**
- Create: `Sources/OrreryCore/Commands/PhantomNextCommand.swift`
- Create: `Sources/OrreryCore/Commands/PhantomEndCommand.swift`
- Modify: `Sources/orrery/OrreryCommand.swift:60-71`
- Test: `Tests/OrreryTests/PhantomNextCommandTests.swift`

**Interfaces:**
- Consumes: `PhantomRegistry` (Task 1), `PhantomSupport.readSentinel` (Task 3), `ShellQuote.single` (Task 3).
- Produces:
  - `PhantomNextCommand.nextArgv(sessionId: String?) -> String`
  - `PhantomNextCommand.advance(id:registry:applyPin:resolveSessionId:) throws -> String?` — returns the argv line, or nil meaning "no sentinel, break the loop".
  - `PhantomEndCommand` (`_phantom-end`), option `--id`.

- [ ] **Step 1: Write the failing test**

Create `Tests/OrreryTests/PhantomNextCommandTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("PhantomNextCommand")
struct PhantomNextCommandTests {
    var tmpDir: URL!
    var registry: PhantomRegistry!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-phantom-next-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        registry = PhantomRegistry(homeURL: tmpDir)
        try registry.write(PhantomEntry(
            supervisorPid: 4242, supervisorStartedAt: 1.0, tool: "claude",
            tty: nil, cwd: "/tmp/project", workspace: "origin", account: "old",
            sessionId: nil, sessionIdSource: .probe, updatedAt: 1.0), id: "4242")
    }

    @Test("argv is --resume plus a quoted session id")
    func argvWithSession() {
        #expect(PhantomNextCommand.nextArgv(sessionId: "abc-123") == "--resume 'abc-123'")
    }

    @Test("argv is empty when there is no session to resume")
    func argvWithoutSession() {
        #expect(PhantomNextCommand.nextArgv(sessionId: nil) == "")
    }

    @Test("no sentinel means break the loop")
    func noSentinel() throws {
        var pinned: [(String, String)] = []
        let result = try PhantomNextCommand.advance(
            id: "4242", registry: registry,
            applyPin: { pinned.append(($0, $1)) },
            resolveSessionId: { nil })
        #expect(result == nil)
        #expect(pinned.isEmpty)
    }

    @Test("a sentinel applies the pin and returns resume argv")
    func appliesPin() throws {
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "work",
            sessionId: "sess-old", to: registry.sentinelURL(id: "4242"))

        var pinned: [(String, String)] = []
        let result = try PhantomNextCommand.advance(
            id: "4242", registry: registry,
            applyPin: { pinned.append(($0, $1)) },
            resolveSessionId: { "sess-old" })

        #expect(result == "--resume 'sess-old'")
        #expect(pinned.count == 1)
        #expect(pinned[0].0 == "claude")
        #expect(pinned[0].1 == "work")
    }

    @Test("the sentinel is consumed so the next iteration does not re-fire")
    func sentinelConsumed() throws {
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "work",
            sessionId: nil, to: registry.sentinelURL(id: "4242"))

        _ = try PhantomNextCommand.advance(
            id: "4242", registry: registry, applyPin: { _, _ in }, resolveSessionId: { nil })

        #expect(!FileManager.default.fileExists(
            atPath: registry.sentinelURL(id: "4242").path))
    }

    @Test("the entry records the new account after a switch")
    func entryUpdated() throws {
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "work",
            sessionId: nil, to: registry.sentinelURL(id: "4242"))

        _ = try PhantomNextCommand.advance(
            id: "4242", registry: registry, applyPin: { _, _ in },
            resolveSessionId: { "sess-new" })

        let entry = try #require(registry.read(id: "4242"))
        #expect(entry.account == "work")
        #expect(entry.sessionId == "sess-new")
    }

    @Test("a hook-sourced session id is preferred over a probed one")
    func hookSessionWins() throws {
        try registry.write(PhantomEntry(
            supervisorPid: 4242, supervisorStartedAt: 1.0, tool: "claude",
            tty: nil, cwd: "/tmp/project", workspace: "origin", account: "old",
            sessionId: "from-hook", sessionIdSource: .hook, updatedAt: 1.0), id: "4242")
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude", targetAccountName: "work",
            sessionId: nil, to: registry.sentinelURL(id: "4242"))

        let result = try PhantomNextCommand.advance(
            id: "4242", registry: registry, applyPin: { _, _ in },
            resolveSessionId: { "from-probe" })

        #expect(result == "--resume 'from-hook'")
    }

    @Test("a session id containing a quote is safely quoted for eval")
    func quotedSessionId() {
        #expect(PhantomNextCommand.nextArgv(sessionId: "a'b") == #"--resume 'a'\''b'"#)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PhantomNextCommand`
Expected: FAIL — `cannot find 'PhantomNextCommand' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OrreryCore/Commands/PhantomNextCommand.swift`:

```swift
import ArgumentParser
import Foundation

/// `orrery-bin _phantom-next --id <id>`
///
/// Called by the `claude()` supervisor loop each time claude exits. Exits
/// non-zero when there is no sentinel, which the shell reads as "claude
/// exited normally, leave the loop". Otherwise it applies the pending account
/// switch and prints the argv for the next iteration.
///
/// The pin is applied here rather than at trigger time on purpose: `orrery
/// use` syncs the just-used account's refreshed credential back into the pool
/// before repinning, so flipping the pin while the old claude was still alive
/// would copy its live token into the new account's pool entry.
public struct PhantomNextCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_phantom-next",
        shouldDisplay: false
    )

    @Option(name: .long) public var id: String

    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default
        let registry = PhantomRegistry(homeURL: store.homeURL)

        guard let argv = try Self.advance(
            id: id,
            registry: registry,
            applyPin: { tool, name in
                try? Self.runUse(tool: tool, name: name)
            },
            resolveSessionId: { PhantomSupport.findCurrentClaudeSessionId() }
        ) else {
            throw ExitCode.failure
        }
        print(argv)
    }

    // MARK: - Testable core

    /// Returns the next iteration's argv, or nil when the loop should end.
    ///
    /// `applyPin` and `resolveSessionId` are injected so the whole decision
    /// path is testable without mutating real account state or needing a live
    /// claude session on disk.
    static func advance(
        id: String,
        registry: PhantomRegistry,
        applyPin: (String, String) -> Void,
        resolveSessionId: () -> String?
    ) throws -> String? {
        let sentinelURL = registry.sentinelURL(id: id)
        guard let sentinel = PhantomSupport.readSentinel(at: sentinelURL) else {
            return nil
        }
        // Consume it first: a sentinel that survives a failure here would
        // re-fire on every subsequent iteration.
        try? FileManager.default.removeItem(at: sentinelURL)

        if let tool = sentinel.tool, let name = sentinel.name {
            applyPin(tool, name)
        }

        var entry = registry.read(id: id)

        // A hook-reported session id is authoritative; only fall back to
        // probing (newest session file by mtime) when we have none.
        let sessionId: String?
        if let entry, entry.sessionIdSource == .hook, let known = entry.sessionId {
            sessionId = known
        } else {
            sessionId = sentinel.sessionId ?? resolveSessionId()
        }

        if var e = entry {
            if let name = sentinel.name { e.account = name }
            e.sessionId = sessionId
            e.updatedAt = Date().timeIntervalSince1970
            try? registry.write(e, id: id)
            entry = e
        }

        return Self.nextArgv(sessionId: sessionId)
    }

    /// The user's original flags are deliberately dropped — they may include a
    /// now-stale `--resume`.
    static func nextArgv(sessionId: String?) -> String {
        guard let sessionId, !sessionId.isEmpty else { return "" }
        return "--resume \(ShellQuote.single(sessionId))"
    }

    private static func runUse(tool: String, name: String) throws {
        var use = UseCommand()
        use.claude = (tool == "claude")
        use.codex = (tool == "codex")
        use.gemini = (tool == "gemini")
        use.name = name
        try use.run()
    }
}
```

> Verified: `UseCommand` (`Sources/OrreryCore/Commands/UseCommand.swift:4-20`) declares `claude`, `codex`, `gemini` and `name` as `public var` with a `public init()`, so constructing and mutating it directly compiles.

Create `Sources/OrreryCore/Commands/PhantomEndCommand.swift`:

```swift
import ArgumentParser
import Foundation

/// `orrery-bin _phantom-end --id <id>`
///
/// Called once the supervisor loop exits. Best-effort: a leftover entry is
/// harmless because liveness checks prune it, so this never reports failure.
public struct PhantomEndCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_phantom-end",
        shouldDisplay: false
    )

    @Option(name: .long) public var id: String

    public init() {}

    public func run() throws {
        PhantomRegistry(homeURL: EnvironmentStore.default.homeURL).remove(id: id)
    }
}
```

Register both in `hiddenSubcommands` in `Sources/orrery/OrreryCommand.swift`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build && swift test --filter PhantomNextCommand`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Commands/PhantomNextCommand.swift Sources/OrreryCore/Commands/PhantomEndCommand.swift Sources/orrery/OrreryCommand.swift Tests/OrreryTests/PhantomNextCommandTests.swift
git commit -m "[FEAT] add _phantom-next and _phantom-end loop hooks"
```

---

### Task 7: Find claude by walking down from the supervisor

**Files:**
- Modify: `Sources/OrreryCore/Commands/PhantomSupport.swift:121-220`
- Test: `Tests/OrreryTests/PhantomTriggerTests.swift`

**Interfaces:**
- Consumes: existing `PhantomSupport.readProcessInfo`, `isClaudeComm`.
- Produces: `PhantomSupport.resolveClaudePidDownward(supervisorPid:children:lookup:) -> Int32?` and `PhantomSupport.childPids(of: Int32) -> [Int32]`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/OrreryTests/PhantomTriggerTests.swift`:

```swift
    // MARK: - Downward resolution (out-of-band triggering)

    /// Fake tree helper: children maps parent -> [child], comms maps pid -> comm.
    private func downward(
        supervisor: Int32,
        children: [Int32: [Int32]],
        comms: [Int32: String]
    ) -> Int32? {
        PhantomSupport.resolveClaudePidDownward(
            supervisorPid: supervisor,
            children: { children[$0] ?? [] },
            lookup: { pid in comms[pid].map { (ppid: Int32(0), comm: $0) } })
    }

    @Test("finds a claude that is a direct child of the supervisor")
    func downwardDirectChild() {
        #expect(downward(supervisor: 10, children: [10: [11]],
                         comms: [10: "zsh", 11: "claude"]) == 11)
    }

    @Test("finds claude behind a caffeinate wrapper")
    func downwardThroughWrapper() {
        #expect(downward(supervisor: 10, children: [10: [11], 11: [12]],
                         comms: [10: "zsh", 11: "caffeinate", 12: "claude"]) == 12)
    }

    @Test("matches the Bun-compiled claude.exe comm")
    func downwardBunName() {
        #expect(downward(supervisor: 10, children: [10: [11]],
                         comms: [10: "zsh", 11: "claude.exe"]) == 11)
    }

    @Test("falls back to the only child when nothing is named claude")
    func downwardVersionStringComm() {
        // Claude Code often reports its comm as a bare version string.
        #expect(downward(supervisor: 10, children: [10: [11]],
                         comms: [10: "zsh", 11: "2.1.201"]) == 11)
    }

    @Test("returns nil when the supervisor has no children")
    func downwardNoChildren() {
        #expect(downward(supervisor: 10, children: [:], comms: [10: "zsh"]) == nil)
    }

    @Test("prefers the claude-named process over an unrelated sibling")
    func downwardPrefersNamed() {
        #expect(downward(supervisor: 10, children: [10: [11, 12]],
                         comms: [10: "zsh", 11: "sleep", 12: "claude"]) == 12)
    }

    @Test("does not mistarget a helper process whose name merely starts with claude")
    func downwardIgnoresHelper() {
        #expect(downward(supervisor: 10, children: [10: [11], 11: [12]],
                         comms: [10: "zsh", 11: "claude-helper", 12: "claude"]) == 12)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PhantomTrigger`
Expected: FAIL — `type 'PhantomSupport' has no member 'resolveClaudePidDownward'`.

- [ ] **Step 3: Write minimal implementation**

Append to `PhantomSupport` in `Sources/OrreryCore/Commands/PhantomSupport.swift`:

```swift
    // MARK: - Downward process discovery (out-of-band triggering)

    /// Find claude by descending from a known supervisor.
    ///
    /// The in-chain trigger walks *up* from itself, which is shorter and needs
    /// no search. Out-of-band callers have no such ancestry — they only know
    /// the supervisor pid from the registry — so they descend instead.
    ///
    /// The supervisor's loop runs claude in the foreground, so at any moment
    /// there is one relevant subtree. We prefer a process whose comm names
    /// claude (keeping the right target when a wrapper such as `caffeinate`
    /// sits in between) and otherwise fall back to the deepest single
    /// descendant, because Claude Code frequently reports its comm as a bare
    /// version string like "2.1.201".
    static func resolveClaudePidDownward(
        supervisorPid: Int32,
        maxDepth: Int = 8,
        children: (Int32) -> [Int32],
        lookup: (Int32) -> (ppid: Int32, comm: String)?
    ) -> Int32? {
        var frontier = children(supervisorPid)
        var depth = 0
        var fallback: Int32? = frontier.count == 1 ? frontier.first : nil

        while !frontier.isEmpty, depth < maxDepth {
            for pid in frontier {
                if let info = lookup(pid), isClaudeComm(info.comm) {
                    return pid
                }
            }
            let next = frontier.flatMap { children($0) }
            if next.count == 1 { fallback = next.first }
            frontier = next
            depth += 1
        }
        return fallback
    }

    /// Direct children of `pid`, via a full process-table snapshot.
    static func childPids(of pid: Int32) -> [Int32] {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

        let actual = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(actual)
            .filter { $0.kp_eproc.e_ppid == pid }
            .map { $0.kp_proc.p_pid }
        #else
        return []
        #endif
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PhantomTrigger`
Expected: PASS — the 7 new tests plus all pre-existing ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Commands/PhantomSupport.swift Tests/OrreryTests/PhantomTriggerTests.swift
git commit -m "[FEAT] resolve claude by descending from a registered supervisor"
```

---

### Task 8: Registry-based addressing and disambiguation in `orrery phantom`

**Files:**
- Create: `Sources/OrreryCore/Phantom/PhantomTargetSelector.swift`
- Modify: `Sources/OrreryCore/Commands/PhantomAccountTriggerCommand.swift:43-91`
- Modify: `Sources/OrreryCore/Resources/Localization/en.json`, `zh-Hant.json`, `ja.json`, `l10n-signatures.json`
- Test: `Tests/OrreryTests/PhantomTargetSelectorTests.swift`

**Interfaces:**
- Consumes: `PhantomRegistry.liveEntries` (Task 1), `ProcessLiveness.isAlive` (Task 2), `PhantomSupport.resolveClaudePidDownward` (Task 7), `PhantomSupport.writeSentinel(to:)` (Task 3).
- Produces: `PhantomTargetSelector.select(entries:envPhantomId:cwd:explicit:) -> PhantomTargetSelector.Selection`, with cases `.selected(id:entry:)`, `.ambiguous([Candidate])`, `.none`.

- [ ] **Step 1: Write the failing test**

Create `Tests/OrreryTests/PhantomTargetSelectorTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("PhantomTargetSelector")
struct PhantomTargetSelectorTests {
    private func entry(pid: Int32, cwd: String, account: String = "a") -> PhantomEntry {
        PhantomEntry(
            supervisorPid: pid, supervisorStartedAt: 1.0, tool: "claude",
            tty: nil, cwd: cwd, workspace: "origin", account: account,
            sessionId: nil, sessionIdSource: .probe, updatedAt: 1.0)
    }

    @Test("an in-chain ORRERY_PHANTOM_ID wins outright")
    func envIdWins() {
        let entries = [("10", entry(pid: 10, cwd: "/a")),
                       ("20", entry(pid: 20, cwd: "/b"))]
        let result = PhantomTargetSelector.select(
            entries: entries, envPhantomId: "20", cwd: "/a", explicit: nil)
        guard case .selected(let id, _) = result else {
            Issue.record("expected .selected, got \(result)"); return
        }
        #expect(id == "20")
    }

    @Test("a stale ORRERY_PHANTOM_ID with no live entry does not select it")
    func staleEnvId() {
        let entries = [("10", entry(pid: 10, cwd: "/a"))]
        let result = PhantomTargetSelector.select(
            entries: entries, envPhantomId: "99", cwd: "/a", explicit: nil)
        guard case .selected(let id, _) = result else {
            Issue.record("expected .selected, got \(result)"); return
        }
        #expect(id == "10")  // falls through to the unique cwd match
    }

    @Test("a unique cwd match is selected")
    func uniqueCwd() {
        let entries = [("10", entry(pid: 10, cwd: "/a")),
                       ("20", entry(pid: 20, cwd: "/b"))]
        let result = PhantomTargetSelector.select(
            entries: entries, envPhantomId: nil, cwd: "/b", explicit: nil)
        guard case .selected(let id, _) = result else {
            Issue.record("expected .selected, got \(result)"); return
        }
        #expect(id == "20")
    }

    @Test("two entries in the same cwd are ambiguous")
    func ambiguousCwd() {
        let entries = [("10", entry(pid: 10, cwd: "/a", account: "work")),
                       ("20", entry(pid: 20, cwd: "/a", account: "personal"))]
        let result = PhantomTargetSelector.select(
            entries: entries, envPhantomId: nil, cwd: "/a", explicit: nil)
        guard case .ambiguous(let candidates) = result else {
            Issue.record("expected .ambiguous, got \(result)"); return
        }
        #expect(candidates.count == 2)
    }

    @Test("no cwd match lists every live entry as a candidate")
    func noCwdMatch() {
        let entries = [("10", entry(pid: 10, cwd: "/a")),
                       ("20", entry(pid: 20, cwd: "/b"))]
        let result = PhantomTargetSelector.select(
            entries: entries, envPhantomId: nil, cwd: "/elsewhere", explicit: nil)
        guard case .ambiguous(let candidates) = result else {
            Issue.record("expected .ambiguous, got \(result)"); return
        }
        #expect(candidates.count == 2)
    }

    @Test("no live entries at all yields .none")
    func nothingLive() {
        let result = PhantomTargetSelector.select(
            entries: [], envPhantomId: nil, cwd: "/a", explicit: nil)
        guard case .none = result else {
            Issue.record("expected .none, got \(result)"); return
        }
    }

    @Test("an explicit id selects directly, overriding cwd")
    func explicitId() {
        let entries = [("10", entry(pid: 10, cwd: "/a")),
                       ("20", entry(pid: 20, cwd: "/b"))]
        let result = PhantomTargetSelector.select(
            entries: entries, envPhantomId: nil, cwd: "/a", explicit: "20")
        guard case .selected(let id, _) = result else {
            Issue.record("expected .selected, got \(result)"); return
        }
        #expect(id == "20")
    }

    @Test("an explicit 1-based index selects from the candidate list")
    func explicitIndex() {
        let entries = [("10", entry(pid: 10, cwd: "/a")),
                       ("20", entry(pid: 20, cwd: "/b"))]
        let result = PhantomTargetSelector.select(
            entries: entries, envPhantomId: nil, cwd: "/nope", explicit: "2")
        guard case .selected(let id, _) = result else {
            Issue.record("expected .selected, got \(result)"); return
        }
        #expect(id == "20")
    }

    @Test("an explicit id that matches nothing yields .none")
    func explicitUnknown() {
        let entries = [("10", entry(pid: 10, cwd: "/a"))]
        let result = PhantomTargetSelector.select(
            entries: entries, envPhantomId: nil, cwd: "/a", explicit: "77")
        guard case .none = result else {
            Issue.record("expected .none, got \(result)"); return
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PhantomTargetSelector`
Expected: FAIL — `cannot find 'PhantomTargetSelector' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OrreryCore/Phantom/PhantomTargetSelector.swift`:

```swift
import Foundation

/// Picks which supervised session an `orrery phantom` invocation targets.
///
/// The common case is unambiguous and stays that way: when the command runs
/// inside a supervised claude, `ORRERY_PHANTOM_ID` is inherited from the shim
/// and names the session exactly. Everything below that is for out-of-band
/// invocations, which have to guess from cwd and then ask.
public enum PhantomTargetSelector {

    public struct Candidate: Equatable, Sendable {
        public let id: String
        public let entry: PhantomEntry
    }

    public enum Selection: Equatable, Sendable {
        case selected(id: String, entry: PhantomEntry)
        case ambiguous([Candidate])
        case none
    }

    public static func select(
        entries: [(id: String, entry: PhantomEntry)],
        envPhantomId: String?,
        cwd: String,
        explicit: String?
    ) -> Selection {
        guard !entries.isEmpty else { return .none }

        // An explicit selector is either a registry id or a 1-based index into
        // the candidate list the user was just shown.
        if let explicit {
            if let hit = entries.first(where: { $0.id == explicit }) {
                return .selected(id: hit.id, entry: hit.entry)
            }
            if let n = Int(explicit), n >= 1, n <= entries.count {
                let hit = entries[n - 1]
                return .selected(id: hit.id, entry: hit.entry)
            }
            return .none
        }

        // In-chain: the shim exported this, so it is exact.
        if let envPhantomId, let hit = entries.first(where: { $0.id == envPhantomId }) {
            return .selected(id: hit.id, entry: hit.entry)
        }

        let sameCwd = entries.filter { $0.entry.cwd == cwd }
        if sameCwd.count == 1 {
            return .selected(id: sameCwd[0].id, entry: sameCwd[0].entry)
        }
        if sameCwd.count > 1 {
            return .ambiguous(sameCwd.map { Candidate(id: $0.id, entry: $0.entry) })
        }
        return .ambiguous(entries.map { Candidate(id: $0.id, entry: $0.entry) })
    }
}
```

Rewrite `PhantomAccountTriggerCommand.run()` (`Sources/OrreryCore/Commands/PhantomAccountTriggerCommand.swift:43-91`) to:

```swift
    @Option(name: .long, help: ArgumentHelp(L10n.Phantom.sessionSelectorHelp))
    public var session: String?

    public func run() throws {
        let tool = try AddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)
        let store = EnvironmentStore.default
        let registry = PhantomRegistry(homeURL: store.homeURL)

        // Resolve the account first — a typo must never tear down a session.
        guard try AccountStore.default.findByDisplayName(name, tool: tool) != nil else {
            throw ValidationError(L10n.Account.useNotFound(name, tool.rawValue))
        }

        let env = ProcessInfo.processInfo.environment
        let live = registry.liveEntries(isAlive: ProcessLiveness.isAlive)

        // Back-compat: an old shell integration still in the user's rc file
        // sets ORRERY_PHANTOM_SHELL_PID but never registers an entry. Fall
        // back to the legacy global sentinel so switching still works, and
        // tell them how to get the new behaviour. Remove in a future release.
        if live.isEmpty, let legacyPid = env["ORRERY_PHANTOM_SHELL_PID"],
           let supervisorPid = Int32(legacyPid) {
            try Self.switchLegacy(
                supervisorPid: supervisorPid, tool: tool, name: name, store: store)
            return
        }

        let selection = PhantomTargetSelector.select(
            entries: live,
            envPhantomId: env["ORRERY_PHANTOM_ID"],
            cwd: FileManager.default.currentDirectoryPath,
            explicit: session)

        switch selection {
        case .none:
            throw ValidationError(L10n.Phantom.notUnderPhantom)

        case .ambiguous(let candidates):
            var lines = [L10n.Phantom.ambiguousHeader]
            for (i, c) in candidates.enumerated() {
                lines.append("  \(i + 1)) \(c.entry.tool)  \(c.entry.account ?? "-")"
                    + "  \(c.entry.cwd)  \(c.entry.sessionId?.prefix(8) ?? "-")")
            }
            lines.append(L10n.Phantom.ambiguousHint)
            throw ValidationError(lines.joined(separator: "\n"))

        case .selected(let id, let entry):
            guard let claudePid = Self.findTarget(entry: entry, env: env) else {
                throw ValidationError(L10n.Phantom.claudeNotFound)
            }
            try PhantomSupport.writeSentinel(
                targetAccountTool: tool.rawValue,
                targetAccountName: name,
                sessionId: entry.sessionIdSource == .hook
                    ? entry.sessionId
                    : (entry.sessionId ?? PhantomSupport.findCurrentClaudeSessionId()),
                to: registry.sentinelURL(id: id))

            if let sid = entry.sessionId {
                print(L10n.Phantom.switchingAccount(name, String(sid.prefix(8))))
            } else {
                print(L10n.Phantom.switchingAccountNoSession(name))
            }

            if kill(claudePid, SIGTERM) != 0 {
                try? FileManager.default.removeItem(at: registry.sentinelURL(id: id))
                throw ValidationError(L10n.Phantom.signalFailed)
            }
        }
    }

    /// In-chain callers walk up from themselves (short, no search); everyone
    /// else descends from the registered supervisor.
    private static func findTarget(entry: PhantomEntry, env: [String: String]) -> Int32? {
        if env["ORRERY_PHANTOM_ID"] == String(entry.supervisorPid) {
            if let pid = PhantomSupport.findClaudeAncestor(
                supervisorPid: entry.supervisorPid) {
                return pid
            }
        }
        return PhantomSupport.resolveClaudePidDownward(
            supervisorPid: entry.supervisorPid,
            children: { PhantomSupport.childPids(of: $0) },
            lookup: { PhantomSupport.readProcessInfo(pid: $0) })
    }

    private static func switchLegacy(
        supervisorPid: Int32, tool: Tool, name: String, store: EnvironmentStore
    ) throws {
        guard let claudePid = PhantomSupport.findClaudeAncestor(
            supervisorPid: supervisorPid) else {
            throw ValidationError(L10n.Phantom.claudeNotFound)
        }
        let legacyURL = store.homeURL.appendingPathComponent(".phantom-sentinel")
        try PhantomSupport.writeSentinel(
            targetAccountTool: tool.rawValue, targetAccountName: name,
            sessionId: PhantomSupport.findCurrentClaudeSessionId(), to: legacyURL)
        FileHandle.standardError.write(Data((L10n.Phantom.legacySupervisor + "\n").utf8))
        if kill(claudePid, SIGTERM) != 0 {
            try? FileManager.default.removeItem(at: legacyURL)
            throw ValidationError(L10n.Phantom.signalFailed)
        }
    }
```

Add these four keys to `en.json`, translating in `zh-Hant.json` and stubbing in `ja.json`, plus matching entries in `l10n-signatures.json` (all `"kind": "var"`, empty `parameters`, paths `["Phantom", "<key>"]`):

```json
  "phantom.sessionSelectorHelp": "Which supervised session to switch, when more than one is running (index or id).",
  "phantom.ambiguousHeader": "More than one supervised session is running:",
  "phantom.ambiguousHint": "Re-run with --session <number|id> to pick one.",
  "phantom.legacySupervisor": "orrery: this session uses an older shell integration; run 'orrery setup' to enable out-of-band switching."
```

Also update `phantom.notUnderPhantom` in all three locales — it should no longer tell people to use `orrery run claude`:

```json
  "phantom.notUnderPhantom": "No supervised session found. Launch claude normally (phantom is on by default); if you just updated orrery, run 'orrery setup' to refresh the shell integration."
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build && swift test --filter Phantom`
Expected: PASS — 9 selector tests plus all pre-existing phantom tests. If `LocalizationTests` fails, a locale file or `l10n-signatures.json` is missing one of the four new keys.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore Tests/OrreryTests
git commit -m "[FEAT] address phantom sessions via the registry

orrery phantom no longer requires an inherited env var: it looks the
session up in the registry, so it can be run from another terminal. Keeps
a compatibility path for shell integrations that predate the registry."
```

---

### Task 9: SessionStart/SessionEnd hook for authoritative session ids

**Files:**
- Create: `Sources/OrreryCore/Setup/ClaudeSessionHookInstaller.swift`
- Modify: `Sources/orrery-claude-hook/main.swift`
- Modify: `Sources/OrreryCore/Commands/PrepareClaudeLaunchCommand.swift:104-111`
- Test: `Tests/OrreryTests/ClaudeSessionHookTests.swift`

**Interfaces:**
- Consumes: `PhantomRegistry` (Task 1), `SettingsJSONPatcher` (existing), `PhantomEntry.SessionIdSource` (Task 1).
- Produces:
  - `ClaudeSessionHookInstaller.install(command:settingsURL:)`
  - `ClaudeSessionHook.apply(payload: Data, phantomId: String?, registry: PhantomRegistry)`

- [ ] **Step 1: Write the failing test**

Create `Tests/OrreryTests/ClaudeSessionHookTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("ClaudeSessionHook")
struct ClaudeSessionHookTests {
    var tmpDir: URL!
    var registry: PhantomRegistry!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-session-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        registry = PhantomRegistry(homeURL: tmpDir)
        try registry.write(PhantomEntry(
            supervisorPid: 4242, supervisorStartedAt: 1.0, tool: "claude",
            tty: nil, cwd: "/tmp/p", workspace: "origin", account: "work",
            sessionId: nil, sessionIdSource: .probe, updatedAt: 1.0), id: "4242")
    }

    private func payload(_ json: String) -> Data { Data(json.utf8) }

    @Test("SessionStart records the session id as authoritative")
    func recordsSessionId() throws {
        ClaudeSessionHook.apply(
            payload: payload(#"{"hook_event_name":"SessionStart","session_id":"real-1","source":"startup"}"#),
            phantomId: "4242", registry: registry)

        let entry = try #require(registry.read(id: "4242"))
        #expect(entry.sessionId == "real-1")
        #expect(entry.sessionIdSource == .hook)
    }

    @Test("a later SessionStart overwrites an earlier session id")
    func overwritesOnResume() throws {
        ClaudeSessionHook.apply(
            payload: payload(#"{"hook_event_name":"SessionStart","session_id":"first","source":"startup"}"#),
            phantomId: "4242", registry: registry)
        ClaudeSessionHook.apply(
            payload: payload(#"{"hook_event_name":"SessionStart","session_id":"second","source":"clear"}"#),
            phantomId: "4242", registry: registry)

        #expect(try #require(registry.read(id: "4242")).sessionId == "second")
    }

    @Test("no phantom id means no write — an unsupervised claude is a no-op")
    func noPhantomId() throws {
        ClaudeSessionHook.apply(
            payload: payload(#"{"hook_event_name":"SessionStart","session_id":"x"}"#),
            phantomId: nil, registry: registry)

        #expect(try #require(registry.read(id: "4242")).sessionId == nil)
    }

    @Test("an unknown phantom id is ignored rather than creating an entry")
    func unknownPhantomId() {
        ClaudeSessionHook.apply(
            payload: payload(#"{"hook_event_name":"SessionStart","session_id":"x"}"#),
            phantomId: "9999", registry: registry)

        #expect(registry.read(id: "9999") == nil)
    }

    @Test("malformed JSON is ignored without crashing")
    func malformedPayload() throws {
        ClaudeSessionHook.apply(payload: payload("not json"),
                                phantomId: "4242", registry: registry)
        #expect(try #require(registry.read(id: "4242")).sessionId == nil)
    }

    @Test("installer adds SessionStart and SessionEnd hooks")
    func installerWrites() throws {
        let settings = tmpDir.appendingPathComponent("settings.json")
        ClaudeSessionHookInstaller.install(command: "/bin/hook --session-event",
                                          settingsURL: settings)
        let text = try String(contentsOf: settings, encoding: .utf8)
        #expect(text.contains("SessionStart"))
        #expect(text.contains("SessionEnd"))
        #expect(text.contains("/bin/hook --session-event"))
    }

    @Test("installing twice does not duplicate the hook entries")
    func installerIdempotent() throws {
        let settings = tmpDir.appendingPathComponent("settings.json")
        ClaudeSessionHookInstaller.install(command: "/bin/hook --session-event",
                                          settingsURL: settings)
        ClaudeSessionHookInstaller.install(command: "/bin/hook --session-event",
                                          settingsURL: settings)
        let text = try String(contentsOf: settings, encoding: .utf8)
        let occurrences = text.components(separatedBy: "/bin/hook --session-event").count - 1
        #expect(occurrences == 2)  // one under SessionStart, one under SessionEnd
    }

    @Test("installing preserves unrelated settings and other hooks")
    func installerAdditive() throws {
        let settings = tmpDir.appendingPathComponent("settings.json")
        try #"{"model":"opus","hooks":{"Notification":[{"matcher":"auth_success","hooks":[{"type":"command","command":"/bin/other"}]}]}}"#
            .write(to: settings, atomically: true, encoding: .utf8)

        ClaudeSessionHookInstaller.install(command: "/bin/hook --session-event",
                                          settingsURL: settings)

        let text = try String(contentsOf: settings, encoding: .utf8)
        #expect(text.contains("\"opus\""))
        #expect(text.contains("/bin/other"))
        #expect(text.contains("/bin/hook --session-event"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaudeSessionHook`
Expected: FAIL — `cannot find 'ClaudeSessionHook' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OrreryCore/Setup/ClaudeSessionHookInstaller.swift`:

```swift
import Foundation

/// Records the session id claude itself reports, instead of guessing.
///
/// Without this, the session id is inferred by scanning the project's session
/// files for the newest mtime — which answers "who wrote most recently", not
/// "what is *this* claude working on". With two claude sessions open on one
/// project, that guess can resume the switch into the wrong conversation.
///
/// `SessionStart` also fires for `resume`, `clear` and `compact`, so the
/// registry keeps up when the user changes conversations mid-session.
///
/// `SessionEnd` is installed too, but nothing depends on it: phantom ends
/// claude with SIGTERM and whether the hook fires in that case is unverified.
/// Credential capture therefore stays on the shell side, and a missed
/// `SessionEnd` only means the entry is pruned slightly later by the liveness
/// check.
public enum ClaudeSessionHookInstaller {
    public static func install(command: String, settingsURL: URL) {
        let hookList: JSONValue = .array([
            .object([
                "hooks": .array([
                    .object([
                        "type": .string("command"),
                        "command": .string(command),
                    ]),
                ]),
            ]),
        ])

        let patch: JSONValue = .object([
            "hooks": .object([
                "SessionStart": hookList,
                "SessionEnd": hookList,
            ]),
        ])

        var target: JSONValue
        if let data = try? Data(contentsOf: settingsURL), !data.isEmpty,
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
            target = decoded
        } else {
            target = .object([:])
        }

        guard (try? SettingsJSONPatcher.apply(patch: patch, to: &target)) != nil else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(target) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }
}

/// The hook's payload handler, separated from the executable so it is testable.
public enum ClaudeSessionHook {
    public static func apply(payload: Data, phantomId: String?, registry: PhantomRegistry) {
        guard let phantomId,
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let sessionId = obj["session_id"] as? String,
              !sessionId.isEmpty,
              var entry = registry.read(id: phantomId)
        else { return }

        entry.sessionId = sessionId
        entry.sessionIdSource = .hook
        entry.updatedAt = Date().timeIntervalSince1970
        try? registry.write(entry, id: phantomId)
    }
}
```

Extend `Sources/orrery-claude-hook/main.swift`. Replace the unconditional stdin drain with a mode check, keeping the existing `auth_success` behaviour intact:

```swift
let stdinData = FileHandle.standardInput.readDataToEndOfFile()

if CommandLine.arguments.contains("--session-event") {
    ClaudeSessionHook.apply(
        payload: stdinData,
        phantomId: ProcessInfo.processInfo.environment["ORRERY_PHANTOM_ID"],
        registry: PhantomRegistry(homeURL: EnvironmentStore.default.homeURL))
    exit(0)
}
```

Place this immediately after the stdin read and before the existing `accountDirArgument()` logic.

In `Sources/OrreryCore/Commands/PrepareClaudeLaunchCommand.swift`, install the session hook **outside** the `if !linksOnly` block. The existing `ensureAuthSuccessHookInstalled` call sits at line 109, inside that block, which is why origin accounts never get it — do not move that one (out of scope), but do place the new call after the block closes at line 111:

```swift
        #if os(macOS)
        // Outside the !linksOnly guard on purpose: unlike .claude.json (which
        // bare origin launches read from ~/.claude.json, not the account dir),
        // settings.json IS read from the account dir even on origin, because
        // ~/.claude symlinks to it. Origin sessions need accurate session ids
        // just as much as pinned ones do.
        if let hookBinaryPath = Self.resolvedHookBinaryPath() {
            ClaudeSessionHookInstaller.install(
                command: "\(hookBinaryPath) --session-event",
                settingsURL: acctDirURL.appendingPathComponent("settings.json"))
        }
        #endif
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build && swift test --filter ClaudeSessionHook`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore Sources/orrery-claude-hook Tests/OrreryTests/ClaudeSessionHookTests.swift
git commit -m "[FEAT] record claude's own session id via a SessionStart hook

Replaces mtime-guessing, which picks the wrong session when two claude
sessions share a project. Installed outside the --links-only guard so
origin accounts get it too."
```

---

### Task 10: Move the supervisor loop into the `claude()` shell shim

**Files:**
- Modify: `Sources/OrreryCore/Shell/ShellFunctionGenerator.swift:29-127` (the `run)` case) and `:263-284` (the `claude()` function)
- Test: `Tests/OrreryTests/ShellFunctionGeneratorPhantomTests.swift`

**Interfaces:**
- Consumes: `_phantom-begin` / `_phantom-next` / `_phantom-end` (Tasks 5, 6).
- Produces: the generated shell text. No Swift API.

- [ ] **Step 1: Write the failing test**

Create `Tests/OrreryTests/ShellFunctionGeneratorPhantomTests.swift`:

```swift
import Testing
@testable import OrreryCore

@Suite("ShellFunctionGenerator phantom")
struct ShellFunctionGeneratorPhantomTests {
    let script = ShellFunctionGenerator.generate(version: "9.9.9")

    @Test("the claude shim drives the supervisor loop")
    func loopInClaudeShim() {
        #expect(script.contains("_phantom-begin --tool claude --supervisor-pid $$"))
        #expect(script.contains("_phantom-next --id \"$ORRERY_PHANTOM_ID\""))
        #expect(script.contains("_phantom-end --id \"$ORRERY_PHANTOM_ID\""))
    }

    @Test("the supervisor pid is passed explicitly, never inferred")
    func explicitSupervisorPid() {
        // getppid() inside a $(...) substitution sees the transient subshell.
        #expect(script.contains("--supervisor-pid $$"))
    }

    @Test("fast-path guards short-circuit before any subcommand runs")
    func guards() {
        #expect(script.contains("${ORRERY_PHANTOM_ID:-}"))
        #expect(script.contains("${CLAUDECODE:-}"))
        #expect(script.contains("${ORRERY_NO_PHANTOM:-}"))
    }

    @Test("the loop calls the launch helper, never claude directly")
    func usesLaunchHelper() {
        #expect(script.contains("_orrery_claude_launch"))
    }

    @Test("prepare and capture still bracket the real claude binary")
    func prepareAndCapturePreserved() {
        #expect(script.contains("_prepare-claude-launch"))
        #expect(script.contains("_capture-claude-exit"))
        #expect(script.contains("command claude"))
    }

    @Test("orrery run no longer carries its own phantom loop")
    func runBranchHasNoLoop() {
        #expect(!script.contains("ORRERY_PHANTOM_SHELL_PID"))
        #expect(!script.contains("_phantom_sentinel"))
    }

    @Test("orrery run claude delegates to the shim")
    func runDelegates() {
        #expect(script.contains("claude \"$@\""))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "ShellFunctionGenerator phantom"`
Expected: FAIL — the generated script still contains `ORRERY_PHANTOM_SHELL_PID` and has no `_phantom-begin`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/OrreryCore/Shell/ShellFunctionGenerator.swift`, replace the phantom branch of the `run)` case (lines 86-118, from `if [ $_run_non_phantom -eq 0 ] ...` through `unset ORRERY_PHANTOM_SHELL_PID`) with a delegation:

```sh
              if [ $_run_non_phantom -eq 0 ] && [ "${1:-}" = "claude" ]; then
                if [ -n "$_run_target" ]; then
                  echo "orrery run claude: -e/--env is not supported for claude — run 'orrery use <account>' first, then 'orrery run claude'." >&2
                  return 1
                fi
                # Supervision now lives in the claude() shim, so bare `claude`
                # gets it too. This branch stays as an equivalent alias.
                shift
                claude "$@"
              else
```

Then replace the `claude()` function (lines 263-284) with the split helper plus the loop:

```sh
        # v3.1 launch wrapper, extracted so the supervisor loop can call it once
        # per iteration: each relaunch may land on a different account dir, so
        # prepare/capture must run every time, not once around the whole loop.
        _orrery_claude_launch() {
          if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -f "$CLAUDE_CONFIG_DIR/metadata.json" ]; then
            if ! command orrery-bin _prepare-claude-launch --account-dir "$CLAUDE_CONFIG_DIR"; then
              echo "orrery: prepare-claude-launch failed; launching with existing .claude.json" >&2
            fi
            command claude "$@"
            local _rc=$?
            command orrery-bin _capture-claude-exit --account-dir "$CLAUDE_CONFIG_DIR" 2>/dev/null || true
            return $_rc
          elif [ -z "${CLAUDE_CONFIG_DIR:-}" ] && [ -f "$HOME/.claude/metadata.json" ]; then
            # Bare launch on origin: ~/.claude points at the origin account dir.
            # claude reads ~/.claude.json here (NOT accountdir/.claude.json), so
            # we must NOT merge .claude.json — only sync the workspace symlinks.
            command orrery-bin _prepare-claude-launch --account-dir "$HOME/.claude" --links-only || true
            command claude "$@"
          else
            command claude "$@"
          fi
        }

        # Phantom supervisor. Kept deliberately thin: this text is written into
        # the user's rc file, so it only changes when they re-run `orrery setup`.
        # Every decision that might need updating lives behind orrery-bin.
        claude() {
          if [ -n "${ORRERY_PHANTOM_ID:-}" ] || [ -n "${CLAUDECODE:-}" ] \
             || [ -n "${ORRERY_NO_PHANTOM:-}" ]; then
            _orrery_claude_launch "$@"; return $?
          fi

          local _spec
          _spec=$(command orrery-bin _phantom-begin --tool claude --supervisor-pid $$ -- "$@") || {
            _orrery_claude_launch "$@"; return $?
          }
          eval "$_spec"

          local _args=("$@")
          local _rc=0
          while true; do
            _orrery_claude_launch "${_args[@]}"
            _rc=$?
            local _next
            _next=$(command orrery-bin _phantom-next --id "$ORRERY_PHANTOM_ID") || break
            eval "set -- $_next"
            _args=("$@")
          done

          command orrery-bin _phantom-end --id "$ORRERY_PHANTOM_ID"
          unset ORRERY_PHANTOM_ID ORRERY_PHANTOM_DIR
          return $_rc
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build && swift test --filter ShellFunctionGenerator`
Expected: PASS, 7 new tests plus any pre-existing generator tests.

- [ ] **Step 5: Verify the generated shell actually parses**

Run:

```bash
swift run orrery-bin init > /tmp/orrery-init-check.sh && \
  zsh -n /tmp/orrery-init-check.sh && bash -n /tmp/orrery-init-check.sh && \
  echo "SYNTAX OK"
```

Expected: `SYNTAX OK`. A syntax error here would break every new shell for every user, and no Swift test catches it.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrreryCore/Shell/ShellFunctionGenerator.swift Tests/OrreryTests/ShellFunctionGeneratorPhantomTests.swift
git commit -m "[FEAT] supervise bare claude by moving the phantom loop into the shim

orrery run claude becomes an equivalent alias; users no longer have to
remember it for in-place account switching to work."
```

---

### Task 11: Surface supervised sessions in `orrery show`, clean up on uninstall

**Files:**
- Modify: `Sources/OrreryCore/Commands/ShowCommand.swift`
- Modify: `Sources/OrreryCore/Commands/UninstallCommand.swift`
- Modify: `Sources/OrreryCore/Resources/Localization/en.json`, `zh-Hant.json`, `ja.json`, `l10n-signatures.json`
- Test: `Tests/OrreryTests/PhantomShowTests.swift`

**Interfaces:**
- Consumes: `PhantomRegistry.liveEntries` (Task 1), `ProcessLiveness.isAlive` (Task 2).
- Produces: `ShowCommand.supervisedSessionLines(entries:) -> [String]`.

- [ ] **Step 1: Write the failing test**

Create `Tests/OrreryTests/PhantomShowTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("PhantomShow")
struct PhantomShowTests {
    private func entry(pid: Int32, account: String?, cwd: String,
                       session: String?) -> PhantomEntry {
        PhantomEntry(
            supervisorPid: pid, supervisorStartedAt: 1.0, tool: "claude",
            tty: "/dev/ttys001", cwd: cwd, workspace: "origin",
            account: account, sessionId: session,
            sessionIdSource: session == nil ? .probe : .hook, updatedAt: 1.0)
    }

    @Test("no live sessions produces no lines at all")
    func emptyIsSilent() {
        #expect(ShowCommand.supervisedSessionLines(entries: []).isEmpty)
    }

    @Test("a live session is rendered with tool, account, cwd and session prefix")
    func rendersEntry() {
        let lines = ShowCommand.supervisedSessionLines(entries: [
            ("10", entry(pid: 10, account: "work", cwd: "/tmp/p",
                         session: "abcdef0123456789")),
        ])
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("claude"))
        #expect(joined.contains("work"))
        #expect(joined.contains("/tmp/p"))
        #expect(joined.contains("abcdef01"))
        #expect(!joined.contains("abcdef0123456789"))  // truncated to 8
    }

    @Test("a session with no account or session id renders placeholders")
    func rendersMissingFields() {
        let lines = ShowCommand.supervisedSessionLines(entries: [
            ("10", entry(pid: 10, account: nil, cwd: "/tmp/p", session: nil)),
        ])
        #expect(lines.joined().contains("-"))
    }

    @Test("multiple sessions each get a line")
    func rendersMultiple() {
        let lines = ShowCommand.supervisedSessionLines(entries: [
            ("10", entry(pid: 10, account: "a", cwd: "/x", session: "s1")),
            ("20", entry(pid: 20, account: "b", cwd: "/y", session: "s2")),
        ])
        // One header plus one line per session.
        #expect(lines.count == 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PhantomShow`
Expected: FAIL — `type 'ShowCommand' has no member 'supervisedSessionLines'`.

- [ ] **Step 3: Write minimal implementation**

Add to `Sources/OrreryCore/Commands/ShowCommand.swift`:

```swift
    /// Rendered lines for the live supervised sessions, or an empty array when
    /// there are none — `orrery show` stays unchanged for anyone not using
    /// phantom.
    static func supervisedSessionLines(
        entries: [(id: String, entry: PhantomEntry)]
    ) -> [String] {
        guard !entries.isEmpty else { return [] }
        var lines = [L10n.Show.supervisedHeader]
        for (_, e) in entries {
            let session = e.sessionId.map { String($0.prefix(8)) } ?? "-"
            lines.append("  \(e.tool)  \(e.account ?? "-")  \(e.cwd)  \(session)")
        }
        return lines
    }
```

Call it at the end of `ShowCommand.run()`. Note the existing local is named `envStore` (`ShowCommand.swift:16`), not `store`:

```swift
        let registry = PhantomRegistry(homeURL: envStore.homeURL)
        for line in Self.supervisedSessionLines(
            entries: registry.liveEntries(isAlive: ProcessLiveness.isAlive)) {
            print(line)
        }
```

In `Sources/OrreryCore/Commands/UninstallCommand.swift`, remove the registry root alongside the other orrery state it clears. That command has no `EnvironmentStore` local of its own — its removals near `UninstallCommand.swift:66-82` operate on URLs it builds directly — so reference the store explicitly:

```swift
        // Supervised-session registry: entries are per-process and meaningless
        // once the shell integration is gone.
        try? FileManager.default.removeItem(
            at: EnvironmentStore.default.homeURL.appendingPathComponent("phantom"))
```

Add the localization key to all three locale files plus `l10n-signatures.json` (path `["Show", "supervisedHeader"]`, `"kind": "var"`, empty parameters):

```json
  "show.supervisedHeader": "Supervised sessions:"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build && swift test --filter PhantomShow && swift test --filter Localization`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS — no regressions anywhere.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrreryCore Tests/OrreryTests/PhantomShowTests.swift
git commit -m "[FEAT] list supervised sessions in orrery show, clear registry on uninstall"
```

---

## Manual Verification

Automated tests cannot cover the parts that involve a real claude and a real terminal. Run these by hand after Task 11, from a fresh shell (`exec zsh`) after `orrery setup`:

- [ ] **Bare launch is supervised.** Run `claude` in a project. In another terminal, `orrery show` lists one supervised session with the right cwd and account.
- [ ] **In-place switching without `orrery run`.** Inside that claude, run `!orrery phantom <other-account>`. Claude exits and reappears resumed on the same conversation, with the new account active.
- [ ] **Out-of-band switching.** With one claude running, from a *different* terminal run `orrery phantom <account>` in the same project directory. The running claude relaunches.
- [ ] **The race this fixes.** Open two claude sessions in the *same* project. Switch one. Confirm the other is untouched and still on its own conversation — this is the multi-session bug the per-supervisor sentinel exists to prevent.
- [ ] **Ambiguity is reported, not guessed.** With those two sessions open, run `orrery phantom <account>` from a third terminal in that project. It should list both candidates and ask for `--session`, not pick one.
- [ ] **Non-session invocations are untouched.** `claude -p "hi"`, `claude mcp list`, and `echo hi | claude -p -` all run once and exit — no loop, no registry entry.
- [ ] **Session id is authoritative.** With a session running, check `~/.orrery/phantom/<pid>/meta.json` shows `"session_id_source": "hook"` and an id matching claude's own `/status`.
- [ ] **`SessionEnd` under SIGTERM.** Note whether the entry's `updated_at` changes when phantom terminates claude. Record the answer in the spec's Risks section — the design does not depend on it either way.
- [ ] **Origin accounts get the hook.** On an origin (unpinned) launch, confirm `~/.claude/settings.json` contains the `SessionStart` hook.
- [ ] **`orrery run claude` still works.** It should behave identically to bare `claude`.
- [ ] **Legacy shell integration.** In a shell that still has the old rc function (open one *before* running `orrery setup`), confirm `orrery phantom` still switches and prints the "run orrery setup" notice.

## Self-Review Notes

Checked against the spec:

- Spec §1 (shell/Swift boundary) → Task 10; §2 (subcommand contracts) → Tasks 5, 6; §3 (which launches are supervised) → Task 4; §4 (registry) → Task 1; §5 (no stored claude pid, downward resolution) → Task 7; §6 (SessionStart/SessionEnd) → Task 9; §7 (addressing and disambiguation) → Task 8; §8 (`orrery run claude` degradation) → Task 10; §9 (`orrery show`) → Task 11; Compatibility → Task 8 (legacy sentinel path) and Task 5 (legacy sentinel removal); Risks §2 (origin hook path) → resolved and handled in Task 9.
- The spec's `tcgetpgrp` cross-check is explicitly deferred; the `tty` field is still written in Task 1 and 5 so a later change needs no migration.
- Localization is required in Tasks 8 and 11 only; all other new strings go to stderr as diagnostics.
