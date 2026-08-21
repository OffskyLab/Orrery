# AIToolKit Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the AIToolKit package and make orrery resolve tools through a registry instead of a closed enum — without moving any per-tool behaviour yet.

**Architecture:** A new standalone Swift package, `AIToolKit`, defines an `AITool` value type that each tool constructs to describe itself, plus an `AIToolRegistry` that answers "which tools exist" from what was registered. orrery takes AIToolKit as a dependency and bridges its existing `Tool` enum into it, so both shapes coexist while call sites migrate later. Before any of that, the four flag-guarded one-shot migrations are made per-tool, because a registry is only complete once registration has run and those flags would otherwise permanently skip a tool.

**Tech Stack:** Swift 6.0 (`swift-tools-version: 6.0`), `.macOS(.v15)`, swift-testing (`import Testing`, `@Suite`, `@Test`, `#expect`), SwiftPM.

**Spec:** `docs/superpowers/specs/2026-08-21-aitoolkit-plugin-framework-design.md`

## Global Constraints

- **AIToolKit must not reference any orrery type.** It is a standalone package that third parties depend on without pulling in orrery.
- **AIToolKit stays on `0.x` for this entire plan.** Breaking changes are expected; semver applies from `1.0`.
- **On-disk format is unchanged.** `metadata.json` keeps `"tool": "claude"`; account paths keep `accounts/<tool>/<id>/`.
- **CLI surface is unchanged.** `--claude` / `--codex` / `--gemini` keep working.
- **Existing installs must not require re-login or migration.**
- Tests use swift-testing, not XCTest. Tests that touch `ORRERY_HOME` or the real home must wrap their body in `withIsolatedHome { … }` (see `Tests/OrreryTests/TestHelpers.swift`).
- No behaviour moves off the `Tool` enum in this plan. That is the next plan.

---

## Scope Note

The spec's Phase 1 has five steps. This plan covers steps 1 and 2 only — the
foundation. Step 3 (migrating behaviour per capability: credentials →
launch/exit → shell → phantom), step 4 (`Tool.allCases` → `registry.all`
across 24 sites) and step 5 (deleting the enum) belong to a **separate plan**,
written once this foundation exists and the interface has been under real
load. Writing them now would be guessing at an interface nobody has used yet.

This plan produces working, testable software on its own: orrery keeps
behaving exactly as it does today, with the registry in place beside the
enum and the migration-flag hazard closed.

---

## File Structure

**New package** at `~/Dropbox/Work/OpenSource/AIToolKit` (separate git repo):

| File | Responsibility |
|---|---|
| `Package.swift` | Package manifest. One library product, `AIToolKit`. |
| `Sources/AIToolKit/AITool.swift` | The `AITool` value type — one tool's description of itself. |
| `Sources/AIToolKit/AIToolRegistry.swift` | Registration and lookup. Replaces `Tool.allCases` as the source of "which tools exist". |
| `Tests/AIToolKitTests/AIToolTests.swift` | `AITool` value semantics and `Codable` round-trip. |
| `Tests/AIToolKitTests/AIToolRegistryTests.swift` | Registration, lookup, duplicate handling, ordering. |

**Modified in orrery:**

| File | Change |
|---|---|
| `Sources/OrreryCore/Setup/MigrationFlag.swift` | **New.** Per-tool coverage for one-shot migration flags. |
| `Sources/OrreryCore/Setup/AccountMigration.swift` | Four flag-guarded functions switch to `MigrationFlag`. |
| `Sources/OrreryCore/Models/Tool.swift` | Gains `var aiTool: AITool` — the bridge. Nothing removed. |
| `Package.swift` | Adds the AIToolKit dependency; `OrreryCore` links it. |
| `Sources/orrery/main.swift` | Registers all tools before any migration runs. |
| `Tests/OrreryTests/MigrationFlagTests.swift` | **New.** |
| `Tests/OrreryTests/ToolBridgeTests.swift` | **New.** |
| `Tests/OrreryTests/RegistryCompletenessTests.swift` | **New.** |

---

## Task 1: MigrationFlag — per-tool coverage

The four one-shot migrations each write a single global "done" marker. Once
`Tool.allCases` is replaced by a registry, a tool absent at that moment is
skipped *and the flag is still written*, so it never migrates on that machine
again. This task builds the replacement; Task 2 applies it.

Backward compatibility matters here: existing installs have flag files
containing `v1\n` or `v3\n`. Those must be read as "already covers
everything", or every upgrading user re-runs migrations they already ran.

**Files:**
- Create: `Sources/OrreryCore/Setup/MigrationFlag.swift`
- Test: `Tests/OrreryTests/MigrationFlagTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct MigrationFlag`
  - `public enum MigrationFlag.Coverage: Equatable { case absent, legacyCoversAll, ids(Set<String>) }`
  - `public init(url: URL)`
  - `public func coverage() -> Coverage`
  - `public func pending(among candidates: Set<String>) -> Set<String>`
  - `public func markCovered(_ ids: Set<String>) throws`

- [ ] **Step 1: Write the failing test**

Create `Tests/OrreryTests/MigrationFlagTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MigrationFlagTests`
Expected: FAIL — `cannot find 'MigrationFlag' in scope`

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OrreryCore/Setup/MigrationFlag.swift`:

```swift
import Foundation

/// Records *which tools* a one-shot migration actually covered, rather than a
/// single global "done" marker.
///
/// The bare marker is safe only while the tool list is fixed at compile time.
/// Once `Tool.allCases` becomes a registry — total only if registration ran —
/// a tool that was not registered when the migration executed gets skipped and
/// the flag is written anyway, so it never migrates on that machine again. The
/// failure is invisible and permanent, which is why this exists before any
/// call site moves.
///
/// File format is a version line followed by one tool id per line:
///
///     v2
///     claude
///     codex
///
/// A file with no id lines is a pre-existing marker (`v1` / `v3`) written
/// before this type existed. Those are read as covering everything: the
/// migration genuinely did run for every tool that existed then, and treating
/// them as covering nothing would re-run every migration on upgrade.
public struct MigrationFlag {
    public enum Coverage: Equatable {
        /// No flag file — the migration has never run.
        case absent
        /// A pre-per-tool marker. Counts as covering every tool.
        case legacyCoversAll
        /// The tool ids this migration has covered.
        case ids(Set<String>)
    }

    private static let formatVersion = "v2"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func coverage() -> Coverage {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return .absent }

        let ids = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != Self.formatVersion && !isVersionToken($0) }

        return ids.isEmpty ? .legacyCoversAll : .ids(Set(ids))
    }

    /// Which of `candidates` this migration has not yet covered.
    public func pending(among candidates: Set<String>) -> Set<String> {
        switch coverage() {
        case .absent:         return candidates
        case .legacyCoversAll: return []
        case .ids(let done):  return candidates.subtracting(done)
        }
    }

    /// Adds `ids` to the covered set. Unions rather than replaces, so a
    /// migration that runs for one late-registered tool does not erase the
    /// record of the tools it already handled.
    public func markCovered(_ ids: Set<String>) throws {
        var all = ids
        if case .ids(let existing) = coverage() {
            all.formUnion(existing)
        }
        let body = ([Self.formatVersion] + all.sorted()).joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: url, options: .atomic)
    }

    /// `v1`, `v3`, … — a legacy marker line, not a tool id.
    private func isVersionToken(_ s: String) -> Bool {
        s.first == "v" && s.dropFirst().allSatisfy(\.isNumber) && s.count > 1
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MigrationFlagTests`
Expected: PASS, 7 tests

- [ ] **Step 5: Run the full suite to confirm nothing regressed**

Run: `swift test`
Expected: all suites pass. (If `RunCommandTests`' "unsetenv removes the stripped keys…" fails, re-run — it is a known pre-existing flake that mutates the real process environment and races other suites. Anything else failing is real.)

- [ ] **Step 6: Commit**

```bash
git add Sources/OrreryCore/Setup/MigrationFlag.swift Tests/OrreryTests/MigrationFlagTests.swift
git commit -m "[FEAT] MigrationFlag: record which tools a one-shot migration covered

A single global done-marker is safe only while the tool list is fixed at
compile time. Once it comes from a registry — total only if registration
ran — a tool absent at that moment is skipped and the flag is written
anyway, so it never migrates on that machine again.

Legacy v1/v3 markers read as covering everything, so upgrading installs
do not re-run migrations they already completed."
```

---

## Task 2: Apply MigrationFlag to the four one-shot migrations

**Files:**
- Modify: `Sources/OrreryCore/Setup/AccountMigration.swift`
- Test: `Tests/OrreryTests/MigrationFlagTests.swift` (extend)

The four, confirmed by reading each guard rather than assuming:

| Flag file | Function |
|---|---|
| `.migration-v3` | `runIfNeeded` |
| `.backfill-account-info-v1` | `runInfoBackfillIfNeeded` |
| `.account-config-consolidated` | `runAccountConfigConsolidationIfNeeded` |
| `.workspace-structure-relocated` | `runWorkspaceStructureRelocationIfNeeded` |

`OriginTakeoverBootstrap` and `OriginAccountSeeder` are deliberately **not**
in this list. They loop `Tool.allCases` too, but guard per tool
(`!store.isOriginManaged(tool:)`, `origin.account(for: tool) == nil`) and hold
no global flag, so they re-run every invocation and pick up a late-registered
tool by themselves.

**Interfaces:**
- Consumes: `MigrationFlag`, `MigrationFlag.Coverage`, `pending(among:)`, `markCovered(_:)` from Task 1.
- Produces: no new public API. `AccountMigration`'s four entry points keep their existing signatures.

- [ ] **Step 1: Write the failing test**

Append to `Tests/OrreryTests/MigrationFlagTests.swift`:

```swift
@Suite("AccountMigration per-tool flags")
struct AccountMigrationFlagTests {

    /// The backfill is the cheapest of the four to drive end to end: it needs
    /// only an accounts directory, no workspaces or credentials.
    @Test("backfill records the tools it covered instead of a bare marker")
    func backfillRecordsCoveredTools() throws {
        try withIsolatedHome {
            let home = orreryHomeURL()
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

            AccountMigration.runInfoBackfillIfNeeded(homeURL: home)

            let flag = MigrationFlag(
                url: home.appendingPathComponent(AccountMigration.infoBackfillFlagFileName))

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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AccountMigrationFlagTests`
Expected: FAIL — `backfillRecordsCoveredTools` reports `.legacyCoversAll` instead of `.ids([...])`, because the current code writes `"v1\n"`.

- [ ] **Step 3: Change `runInfoBackfillIfNeeded`**

In `Sources/OrreryCore/Setup/AccountMigration.swift`, replace the flag guard and
the flag write in `runInfoBackfillIfNeeded`.

Replace:

```swift
        let flagURL = homeURL.appendingPathComponent(infoBackfillFlagFileName)
        if fm.fileExists(atPath: flagURL.path) { return }
```

with:

```swift
        let flag = MigrationFlag(url: homeURL.appendingPathComponent(infoBackfillFlagFileName))
        let toolIDs = Set(Tool.allCases.map(\.rawValue))
        let pending = flag.pending(among: toolIDs)
        if pending.isEmpty { return }
```

Replace the loop header:

```swift
        for tool in Tool.allCases {
```

with:

```swift
        for tool in Tool.allCases where pending.contains(tool.rawValue) {
```

and replace the flag write at the end of the function with:

```swift
        try? flag.markCovered(pending)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AccountMigrationFlagTests`
Expected: PASS, 2 tests

- [ ] **Step 5: Apply the same shape to the other three**

Same four-line transformation in each — guard becomes `pending`, loop filters
on `pending`, write becomes `markCovered(pending)`:

- `runIfNeeded` — flag `flagFileName` (`.migration-v3`). Its loop is
  `for tool in Tool.allCases` at the migrate-origin/env step. Note this
  function `throws`; use `try flag.markCovered(pending)` rather than `try?`,
  matching its existing `try writeFlag(at:)`.
- `runAccountConfigConsolidationIfNeeded` — flag
  `accountConfigConsolidatedFlagFileName`. Its per-tool work is inside
  `consolidateClaudeAccountSettings(homeURL:)`; pass `pending` down as a
  parameter rather than recomputing it there, so the guard and the work cannot
  disagree.
- `runWorkspaceStructureRelocationIfNeeded` — flag
  `workspaceStructureFlagFileName`. Its `Tool.allCases` loop is the symlink
  repoint inside the origin-relocation branch.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: all pass. Pay attention to `V31AutoMigrationTests`,
`AccountMigrationTests`, `WorkspaceStructureRelocationTests` and
`AccountConfigConsolidationTests` — those exercise these four functions
directly and are the ones a mistake here shows up in.

- [ ] **Step 7: Commit**

```bash
git add Sources/OrreryCore/Setup/AccountMigration.swift Tests/OrreryTests/MigrationFlagTests.swift
git commit -m "[FIX] one-shot migrations record which tools they covered

Applies MigrationFlag to the four flag-guarded migrations: .migration-v3,
.backfill-account-info-v1, .account-config-consolidated and
.workspace-structure-relocated. Each now runs for the tools still pending
rather than all-or-nothing, so a tool that appears later still gets its
migration instead of being locked out by a flag written before it existed.

OriginTakeoverBootstrap and OriginAccountSeeder are untouched on purpose —
they guard per tool and hold no global flag, so they already self-heal."
```

---

## Task 3: AIToolKit package and the `AITool` type

**Files:**
- Create: `~/Dropbox/Work/OpenSource/AIToolKit/Package.swift`
- Create: `~/Dropbox/Work/OpenSource/AIToolKit/Sources/AIToolKit/AITool.swift`
- Create: `~/Dropbox/Work/OpenSource/AIToolKit/Tests/AIToolKitTests/AIToolTests.swift`
- Create: `~/Dropbox/Work/OpenSource/AIToolKit/README.md`
- Create: `~/Dropbox/Work/OpenSource/AIToolKit/.gitignore`

**Interfaces:**
- Consumes: nothing. This package has no dependencies.
- Produces:
  - `public struct AITool: Sendable, Hashable, Codable`
  - `public let id: String`, `displayName: String`, `configDirectoryName: String`, `configDirEnvVar: String?`, `authLoginCommand: [String]?`, `installCommand: [String]?`, `sessionSubdirectories: [String]`, `ansiColor: String`
  - `public init(id:displayName:configDirectoryName:configDirEnvVar:authLoginCommand:installCommand:sessionSubdirectories:ansiColor:)`
  - `public var supportsSetup: Bool`
  - `public var coloredTag: String`

Two shape decisions worth understanding before writing the code, both
following the spec's rule that **AIToolKit states facts and the host decides
policy**:

`configDirectoryName` is `".claude"`, not a resolved `URL`. Resolving it needs
a home directory, and which home to resolve against is orrery's decision —
`userHomeURL()` is overridable via `ORRERY_USER_HOME` precisely so tests can
redirect it. A `URL` here would drag that policy into the framework.

`configDirEnvVar` is **optional**, and this fixes an existing lie. Today
`Tool.gemini.envVarName` returns `"GEMINI_CONFIG_DIR"`, but gemini-cli ignores
that variable entirely — it only ever reads `$HOME/.gemini`. Setting it was the
bug behind `orrery add --gemini` writing to the user's real config. `nil` states
the fact honestly; what to do about it (a HOME wrapper) stays with the host.

- [ ] **Step 1: Create the repository skeleton**

```bash
mkdir -p ~/Dropbox/Work/OpenSource/AIToolKit/Sources/AIToolKit
mkdir -p ~/Dropbox/Work/OpenSource/AIToolKit/Tests/AIToolKitTests
cd ~/Dropbox/Work/OpenSource/AIToolKit
git init
printf '.build/\n.DS_Store\n*.xcodeproj\n' > .gitignore
```

Create `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIToolKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AIToolKit", targets: ["AIToolKit"]),
    ],
    targets: [
        .target(name: "AIToolKit", path: "Sources/AIToolKit"),
        .testTarget(
            name: "AIToolKitTests",
            dependencies: ["AIToolKit"],
            path: "Tests/AIToolKitTests"
        ),
    ]
)
```

Create `README.md`:

```markdown
# AIToolKit

Describes an AI CLI tool — how to launch it, where its config lives, how it
logs in — so a host application can manage several of them without knowing
any of them by name.

Built for [orrery](https://github.com/OffskyLab/Orrery), but deliberately
independent of it: a tool plugin depends on this package alone, never on
orrery itself.

**Status: 0.x.** The interface is expected to change while orrery's own
migration onto it is in progress. Semver applies from 1.0.

## What belongs here

Facts about a tool. `~/.claude` is where Claude Code keeps its config;
gemini-cli ignores `GEMINI_CONFIG_DIR` and reads only `$HOME/.gemini`.

## What does not

Anything the *host* decides. Account pools, credential storage policy,
directory sharing — those live in the host, because they are its inventions,
not the tool's.
```

- [ ] **Step 2: Write the failing test**

Create `Tests/AIToolKitTests/AIToolTests.swift`:

```swift
import Foundation
import Testing
@testable import AIToolKit

@Suite("AITool")
struct AIToolTests {

    private var claude: AITool {
        AITool(
            id: "claude",
            displayName: "Claude Code",
            configDirectoryName: ".claude",
            configDirEnvVar: "CLAUDE_CONFIG_DIR",
            authLoginCommand: nil,
            installCommand: ["npm", "install", "-g", "@anthropic-ai/claude-code"],
            sessionSubdirectories: ["projects"],
            ansiColor: "\u{1B}[38;5;173m"
        )
    }

    @Test("identity is the id — two descriptions of the same tool are equal")
    func identityIsTheID() {
        var other = claude
        #expect(other == claude)
        #expect(Set([claude, other]).count == 1)

        other = AITool(
            id: "codex", displayName: "Claude Code",
            configDirectoryName: ".claude", configDirEnvVar: "CLAUDE_CONFIG_DIR",
            authLoginCommand: nil, installCommand: nil,
            sessionSubdirectories: [], ansiColor: ""
        )
        #expect(other != claude)
    }

    /// metadata.json stores `"tool": "claude"`. Encoding anything else would
    /// break every existing install.
    @Test("encodes as its bare id string")
    func encodesAsID() throws {
        let data = try JSONEncoder().encode(claude)
        #expect(String(data: data, encoding: .utf8) == "\"claude\"")
    }

    @Test("supportsSetup follows whether there is an install command")
    func supportsSetup() {
        #expect(claude.supportsSetup)

        let noInstall = AITool(
            id: "x", displayName: "X", configDirectoryName: ".x",
            configDirEnvVar: nil, authLoginCommand: nil, installCommand: nil,
            sessionSubdirectories: [], ansiColor: ""
        )
        #expect(!noInstall.supportsSetup)
    }

    /// gemini-cli ignores GEMINI_CONFIG_DIR and reads only $HOME/.gemini.
    /// Today's enum returns the variable name anyway, which is what sent
    /// `orrery add --gemini` at the user's real config. nil says so honestly;
    /// deciding to build a HOME wrapper instead is the host's business.
    @Test("a tool with no config-dir variable says so with nil")
    func noConfigDirEnvVar() {
        let gemini = AITool(
            id: "gemini", displayName: "Gemini CLI",
            configDirectoryName: ".gemini", configDirEnvVar: nil,
            authLoginCommand: nil, installCommand: nil,
            sessionSubdirectories: ["tmp"], ansiColor: ""
        )
        #expect(gemini.configDirEnvVar == nil)
    }

    @Test("coloredTag wraps the id in the tool's colour and resets")
    func coloredTag() {
        #expect(claude.coloredTag == "\u{1B}[38;5;173m[claude]\u{1B}[0m")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd ~/Dropbox/Work/OpenSource/AIToolKit && swift test`
Expected: FAIL — `cannot find 'AITool' in scope`

- [ ] **Step 4: Write minimal implementation**

Create `Sources/AIToolKit/AITool.swift`:

```swift
import Foundation

/// One AI CLI tool's description of itself.
///
/// Everything here is a *fact about the tool*: where it keeps its config, how
/// it logs in, how it is installed. Nothing here is a decision the host makes
/// about the tool — account pooling, credential storage policy and directory
/// sharing are the host's inventions, and belong to it.
///
/// Identity is `id`, which is also the on-disk representation: this type
/// encodes as a bare string so a host can keep writing `"tool": "claude"`.
public struct AITool: Sendable, Hashable, Codable {

    /// Stable identifier. Also the on-disk value and, typically, the directory
    /// segment a host uses for this tool.
    public let id: String

    /// Human-facing name, e.g. "Claude Code".
    public let displayName: String

    /// The directory name the tool reads its config from, e.g. `".claude"`.
    ///
    /// A name rather than a resolved `URL` on purpose: resolving it requires a
    /// home directory, and which home to resolve against is the host's
    /// decision — orrery redirects it in tests. A URL here would pull that
    /// policy into the framework.
    public let configDirectoryName: String

    /// The environment variable that relocates the tool's config directory, or
    /// `nil` if the tool has none.
    ///
    /// `nil` is a real answer, not a missing one. gemini-cli ignores
    /// `GEMINI_CONFIG_DIR` entirely and reads only `$HOME/.gemini`; claiming
    /// otherwise is what sent one of orrery's login flows at the user's real
    /// config directory. What to do about a tool like that — redirect `HOME`,
    /// refuse to isolate it — is the host's call.
    public let configDirEnvVar: String?

    /// A scriptable login subcommand, or `nil` when the tool authenticates on
    /// first interactive launch instead.
    public let authLoginCommand: [String]?

    /// How to install the tool, or `nil` if the host cannot install it.
    public let installCommand: [String]?

    /// Subdirectories of the config directory holding session state.
    public let sessionSubdirectories: [String]

    /// ANSI escape prefix used when tagging this tool's output.
    public let ansiColor: String

    public init(
        id: String,
        displayName: String,
        configDirectoryName: String,
        configDirEnvVar: String?,
        authLoginCommand: [String]?,
        installCommand: [String]?,
        sessionSubdirectories: [String],
        ansiColor: String
    ) {
        self.id = id
        self.displayName = displayName
        self.configDirectoryName = configDirectoryName
        self.configDirEnvVar = configDirEnvVar
        self.authLoginCommand = authLoginCommand
        self.installCommand = installCommand
        self.sessionSubdirectories = sessionSubdirectories
        self.ansiColor = ansiColor
    }

    public var supportsSetup: Bool { installCommand != nil }

    public var coloredTag: String { "\(ansiColor)[\(id)]\u{1B}[0m" }

    // MARK: - Identity

    public static func == (lhs: AITool, rhs: AITool) -> Bool { lhs.id == rhs.id }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: - Codable
    //
    // Encodes as the bare id so a host's existing on-disk format survives
    // unchanged. Decoding yields an id-only value; a host that needs the full
    // description looks it up in its registry.

    public init(from decoder: any Decoder) throws {
        let id = try decoder.singleValueContainer().decode(String.self)
        self.init(
            id: id, displayName: id, configDirectoryName: ".\(id)",
            configDirEnvVar: nil, authLoginCommand: nil, installCommand: nil,
            sessionSubdirectories: [], ansiColor: ""
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ~/Dropbox/Work/OpenSource/AIToolKit && swift test`
Expected: PASS, 5 tests

- [ ] **Step 6: Commit**

```bash
cd ~/Dropbox/Work/OpenSource/AIToolKit
git add .
git commit -m "[FEAT] AITool — one tool's description of itself

Facts about a tool only: config directory name, login command, install
command, session subdirectories. Host decisions stay with the host.

Two shape choices carry that split. configDirectoryName is a name rather
than a URL, because resolving it needs a home directory and which home is
the host's decision. configDirEnvVar is optional, because a tool may have
none — gemini-cli ignores GEMINI_CONFIG_DIR and reads only \$HOME/.gemini,
and claiming otherwise is what sent a login flow at the user's real config.

Encodes as its bare id so a host's existing on-disk format survives."
```

---

## Task 4: AIToolRegistry

**Files:**
- Create: `~/Dropbox/Work/OpenSource/AIToolKit/Sources/AIToolKit/AIToolRegistry.swift`
- Create: `~/Dropbox/Work/OpenSource/AIToolKit/Tests/AIToolKitTests/AIToolRegistryTests.swift`

**Interfaces:**
- Consumes: `AITool` from Task 3.
- Produces:
  - `public final class AIToolRegistry: @unchecked Sendable`
  - `public static let shared: AIToolRegistry`
  - `public func register(_ tool: AITool)`
  - `public func tool(id: String) -> AITool?`
  - `public var all: [AITool]` — sorted by `id`, for deterministic iteration
  - `public var isEmpty: Bool`
  - `public func reset()` — test support

`all` is sorted rather than insertion-ordered so that iteration is
deterministic regardless of registration order. Several orrery call sites
iterate tools to produce user-facing output; a set's arbitrary order would
make that output vary between runs.

- [ ] **Step 1: Write the failing test**

Create `Tests/AIToolKitTests/AIToolRegistryTests.swift`:

```swift
import Foundation
import Testing
@testable import AIToolKit

@Suite("AIToolRegistry")
struct AIToolRegistryTests {

    private func tool(_ id: String) -> AITool {
        AITool(
            id: id, displayName: id, configDirectoryName: ".\(id)",
            configDirEnvVar: nil, authLoginCommand: nil, installCommand: nil,
            sessionSubdirectories: [], ansiColor: ""
        )
    }

    @Test("a fresh registry knows nothing")
    func startsEmpty() {
        let registry = AIToolRegistry()
        #expect(registry.isEmpty)
        #expect(registry.all.isEmpty)
        #expect(registry.tool(id: "claude") == nil)
    }

    @Test("registered tools are retrievable by id")
    func registerAndLookUp() {
        let registry = AIToolRegistry()
        registry.register(tool("claude"))

        #expect(!registry.isEmpty)
        #expect(registry.tool(id: "claude")?.id == "claude")
        #expect(registry.tool(id: "codex") == nil)
    }

    /// Several call sites iterate tools to build user-facing output. Arbitrary
    /// order would make that output differ run to run.
    @Test("all is sorted by id regardless of registration order")
    func allIsSorted() {
        let registry = AIToolRegistry()
        registry.register(tool("gemini"))
        registry.register(tool("claude"))
        registry.register(tool("codex"))

        #expect(registry.all.map(\.id) == ["claude", "codex", "gemini"])
    }

    @Test("registering the same id again replaces the description")
    func reregisterReplaces() {
        let registry = AIToolRegistry()
        registry.register(tool("claude"))
        registry.register(AITool(
            id: "claude", displayName: "Claude Code",
            configDirectoryName: ".claude", configDirEnvVar: "CLAUDE_CONFIG_DIR",
            authLoginCommand: nil, installCommand: nil,
            sessionSubdirectories: [], ansiColor: ""
        ))

        #expect(registry.all.count == 1)
        #expect(registry.tool(id: "claude")?.displayName == "Claude Code")
        #expect(registry.tool(id: "claude")?.configDirEnvVar == "CLAUDE_CONFIG_DIR")
    }

    @Test("reset clears everything")
    func reset() {
        let registry = AIToolRegistry()
        registry.register(tool("claude"))
        registry.reset()

        #expect(registry.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Dropbox/Work/OpenSource/AIToolKit && swift test --filter AIToolRegistryTests`
Expected: FAIL — `cannot find 'AIToolRegistry' in scope`

- [ ] **Step 3: Write minimal implementation**

Create `Sources/AIToolKit/AIToolRegistry.swift`:

```swift
import Foundation

/// Which tools exist, according to what has been registered.
///
/// This replaces a host's compile-time list. The difference is not cosmetic:
/// a `CaseIterable` enum is total at compile time, whereas a registry is total
/// only once registration has run. A host must therefore register everything
/// before any code that iterates tools executes — in particular before
/// one-shot migrations, which can otherwise mark themselves complete having
/// silently skipped a tool.
public final class AIToolRegistry: @unchecked Sendable {

    /// The registry a host application registers into at startup.
    public static let shared = AIToolRegistry()

    private let lock = NSLock()
    private var storage: [String: AITool] = [:]

    public init() {}

    /// Registers `tool`, replacing any existing description with the same id.
    public func register(_ tool: AITool) {
        lock.lock()
        defer { lock.unlock() }
        storage[tool.id] = tool
    }

    public func tool(id: String) -> AITool? {
        lock.lock()
        defer { lock.unlock() }
        return storage[id]
    }

    /// Every registered tool, sorted by id.
    ///
    /// Sorted rather than insertion-ordered so iteration is deterministic
    /// however registration happened to be sequenced — several hosts iterate
    /// this to build user-facing output.
    public var all: [AITool] {
        lock.lock()
        defer { lock.unlock() }
        return storage.values.sorted { $0.id < $1.id }
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.isEmpty
    }

    /// Empties the registry. Intended for tests.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Dropbox/Work/OpenSource/AIToolKit && swift test`
Expected: PASS, 10 tests (5 from Task 3, 5 here)

- [ ] **Step 5: Tag and publish**

```bash
cd ~/Dropbox/Work/OpenSource/AIToolKit
git add .
git commit -m "[FEAT] AIToolRegistry — tools come from registration, not compilation

all is sorted by id so iteration is deterministic however registration was
sequenced; several call sites turn it into user-facing output.

Carries the caveat that matters: a CaseIterable enum is total at compile
time, a registry only once registration has run. Hosts must register before
anything that iterates tools — especially one-shot migrations, which can
otherwise mark themselves complete having skipped a tool."
git tag 0.1.0
gh repo create OffskyLab/AIToolKit --public --source=. --push
git push --tags
```

---

## Task 5: orrery depends on AIToolKit, and `Tool` bridges to `AITool`

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/OrreryCore/Models/Tool.swift`
- Test: `Tests/OrreryTests/ToolBridgeTests.swift`

Nothing is removed from `Tool` in this task. The bridge lets both shapes
coexist so call sites can migrate later, one at a time.

**Interfaces:**
- Consumes: `AITool` (Task 3).
- Produces: `public var Tool.aiTool: AITool`.

- [ ] **Step 1: Add the dependency**

In `Package.swift`, add to `dependencies:`:

```swift
        .package(url: "https://github.com/OffskyLab/AIToolKit", from: "0.1.0"),
```

and add to the `OrreryCore` target's `dependencies:`:

```swift
                .product(name: "AIToolKit", package: "AIToolKit"),
```

- [ ] **Step 2: Write the failing test**

Create `Tests/OrreryTests/ToolBridgeTests.swift`:

```swift
import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

/// While call sites migrate, the enum and the registry describe the same three
/// tools. If the bridge drifts from the enum, behaviour changes depending on
/// which one a given call site happens to consult — so these assert they agree.
@Suite("Tool → AITool bridge")
struct ToolBridgeTests {

    @Test("every case bridges to an AITool carrying its rawValue as id")
    func idMatchesRawValue() {
        for tool in Tool.allCases {
            #expect(tool.aiTool.id == tool.rawValue)
        }
    }

    @Test("the bridged config directory name matches the enum's default dir")
    func configDirectoryNameMatches() {
        for tool in Tool.allCases {
            #expect(tool.aiTool.configDirectoryName == tool.defaultConfigDir.lastPathComponent)
        }
    }

    @Test("install command and setup support carry across unchanged")
    func installCarriesAcross() {
        for tool in Tool.allCases {
            #expect(tool.aiTool.installCommand == tool.installCommand)
            #expect(tool.aiTool.supportsSetup == tool.supportsSetup)
        }
    }

    @Test("session subdirectories and colour carry across unchanged")
    func sessionsAndColourCarryAcross() {
        for tool in Tool.allCases {
            #expect(tool.aiTool.sessionSubdirectories == tool.sessionSubdirectories)
            #expect(tool.aiTool.coloredTag == tool.coloredTag)
        }
    }

    @Test("login command carries across, including claude's and gemini's nil")
    func loginCarriesAcross() {
        for tool in Tool.allCases {
            #expect(tool.aiTool.authLoginCommand == tool.authLoginCommand)
        }
        #expect(Tool.claude.aiTool.authLoginCommand == nil)
        #expect(Tool.gemini.aiTool.authLoginCommand == nil)
    }

    /// The bridge is where the enum's existing lie gets corrected: gemini-cli
    /// ignores GEMINI_CONFIG_DIR, so the bridged value is nil even though
    /// `Tool.gemini.envVarName` still returns the string.
    @Test("gemini bridges to no config-dir variable")
    func geminiHasNoConfigDirVariable() {
        #expect(Tool.gemini.aiTool.configDirEnvVar == nil)
        #expect(Tool.claude.aiTool.configDirEnvVar == "CLAUDE_CONFIG_DIR")
        #expect(Tool.codex.aiTool.configDirEnvVar == "CODEX_HOME")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter ToolBridgeTests`
Expected: FAIL — `value of type 'Tool' has no member 'aiTool'`

- [ ] **Step 4: Write the bridge**

Append to `Sources/OrreryCore/Models/Tool.swift`:

```swift
import AIToolKit

extension Tool {
    /// This tool described in AIToolKit's terms.
    ///
    /// A bridge, not a replacement: nothing has been removed from the enum, so
    /// call sites can move to the registry one at a time. The enum is deleted
    /// once none of them read it.
    public var aiTool: AITool {
        AITool(
            id: rawValue,
            displayName: displayName,
            configDirectoryName: defaultConfigDir.lastPathComponent,
            configDirEnvVar: bridgedConfigDirEnvVar,
            authLoginCommand: authLoginCommand,
            installCommand: installCommand,
            sessionSubdirectories: sessionSubdirectories,
            ansiColor: ansiColor
        )
    }

    /// `envVarName` returns a string for every case, including gemini — but
    /// gemini-cli ignores `GEMINI_CONFIG_DIR` and reads only `$HOME/.gemini`.
    /// Setting it was the bug behind `orrery add --gemini` writing to the
    /// user's real config. The bridge reports `nil` rather than carrying that
    /// claim forward; the enum keeps its old value until its callers are gone.
    private var bridgedConfigDirEnvVar: String? {
        switch self {
        case .claude, .codex: return envVarName
        case .gemini:         return nil
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter ToolBridgeTests`
Expected: PASS, 6 tests

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Package.resolved Sources/OrreryCore/Models/Tool.swift Tests/OrreryTests/ToolBridgeTests.swift
git commit -m "[FEAT] bridge Tool to AITool

Adds the AIToolKit dependency and Tool.aiTool. Nothing is removed from the
enum: both shapes coexist so call sites migrate one at a time, and the enum
goes once none of them read it.

The bridge corrects one thing on the way across. Tool.gemini.envVarName
returns \"GEMINI_CONFIG_DIR\", but gemini-cli ignores it and reads only
\$HOME/.gemini — setting it is what sent orrery add --gemini at the user's
real config. The bridged value is nil; the enum keeps its old answer until
its callers are gone.

Tests assert the bridge agrees with the enum on every case, so the two
cannot drift while both are live."
```

---

## Task 6: Register at startup, before anything iterates tools

**Files:**
- Modify: `Sources/orrery/main.swift`
- Create: `Sources/OrreryCore/Setup/AIToolRegistration.swift`
- Test: `Tests/OrreryTests/RegistryCompletenessTests.swift`

**Interfaces:**
- Consumes: `Tool.aiTool` (Task 5), `AIToolRegistry.shared` (Task 4).
- Produces: `public enum AIToolRegistration { public static func registerBuiltInTools() }`

- [ ] **Step 1: Write the failing test**

Create `Tests/OrreryTests/RegistryCompletenessTests.swift`:

```swift
import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

/// The registry is total only once registration has run. Four one-shot
/// migrations in AccountMigration mark themselves complete for whichever tools
/// they saw, so registering late means a tool is skipped and locked out
/// permanently. These tests pin the invariant that makes that impossible.
@Suite("registry completeness", .serialized)
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RegistryCompletenessTests`
Expected: FAIL — `cannot find 'AIToolRegistration' in scope`

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OrreryCore/Setup/AIToolRegistration.swift`:

```swift
import Foundation
import AIToolKit

/// Registers the tools this build ships with.
///
/// Must run before anything that iterates tools — above all before
/// `AccountMigration`'s four one-shot migrations, which record the tools they
/// covered and would otherwise lock out a tool that registered afterwards.
/// `main.swift` sequences this explicitly rather than relying on load order.
public enum AIToolRegistration {

    /// Registers into the shared registry. Idempotent.
    public static func registerBuiltInTools() {
        registerBuiltInTools(into: .shared)
    }

    /// Registry taken as a parameter so tests never touch the shared instance.
    public static func registerBuiltInTools(into registry: AIToolRegistry) {
        for tool in Tool.allCases {
            registry.register(tool.aiTool)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RegistryCompletenessTests`
Expected: PASS, 3 tests

- [ ] **Step 5: Wire registration into startup**

In `Sources/orrery/main.swift`, add as the **first** statement inside
`runOrreryMain()`, above `LegacyOrbitalMigration.runIfNeeded()`:

```swift
    // Register the built-in tools before anything iterates them. Ordering is
    // load-bearing, not stylistic: AccountMigration's one-shot migrations
    // record which tools they covered, so a tool registered after one of them
    // runs is skipped and never migrated on that machine again.
    AIToolRegistration.registerBuiltInTools()
```

- [ ] **Step 6: Verify the ordering holds in the built binary**

```bash
swift build
grep -n "registerBuiltInTools" -A 2 Sources/orrery/main.swift
grep -n "AccountMigration\|OriginTakeover\|OriginAccountSeeder" Sources/orrery/main.swift | head -3
```

Expected: `registerBuiltInTools` appears at a lower line number than every
`AccountMigration` / `OriginTakeover` / `OriginAccountSeeder` call.

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/OrreryCore/Setup/AIToolRegistration.swift Sources/orrery/main.swift Tests/OrreryTests/RegistryCompletenessTests.swift
git commit -m "[FEAT] register built-in tools before any migration runs

Ordering here is load-bearing rather than stylistic. AccountMigration's
one-shot migrations record which tools they covered, so a tool registered
after one of them has run is skipped and never migrated on that machine
again — invisibly and permanently.

registerBuiltInTools(into:) takes the registry as a parameter so tests
never mutate the shared instance, and the completeness test asserts the
registry matches the enum rather than trusting that it does."
```

---

## Self-Review

**Spec coverage.** Every requirement this plan claims:

| Spec requirement | Task |
|---|---|
| `AITool` struct with the enum's descriptive members | 3 |
| Identity is an open string, no closed set in the framework | 3 (`id: String`) |
| `Codable` through the id so `metadata.json` is unchanged | 3 |
| `AIToolRegistry`, `allCases` → `registry.all` source | 4 |
| AIToolKit is its own repo, depends on nothing of orrery's | 3, 4 |
| AIToolKit stays on `0.x` | 4 (`git tag 0.1.0`) |
| Registration completes before migration/takeover/seeding | 6 |
| One-shot flags record which tools they covered | 1, 2 |
| A test asserts registry completeness | 6 |
| Strangler: enum bridges, both coexist | 5 |

Deliberately **out of scope**, and stated as such in the Scope Note: behaviour
migration per capability, the 24 `Tool.allCases` call sites, deleting the
enum, moving Codex and Gemini to their own repos. Those need the interface to
have been under load first.

**Placeholder scan.** No `TBD`, no "add error handling", no "similar to Task
N". Every code step carries the code. The one instruction that repeats a shape
rather than repeating code is Task 2 Step 5, which names each of the three
remaining functions, its flag constant, and where its loop lives — the
transformation itself is shown in full in Step 3 of the same task, four lines
above.

**Type consistency.** Checked across tasks: `MigrationFlag.pending(among:)` /
`markCovered(_:)` used identically in Tasks 1 and 2. `AITool`'s eight
initialiser labels identical in Tasks 3, 4, 5. `AIToolRegistry.register` /
`tool(id:)` / `all` / `isEmpty` / `reset` consistent in Tasks 4 and 6.
`Tool.aiTool` produced in Task 5 and consumed in Task 6.

**One risk this plan does not remove.** Task 5 points `Package.swift` at
`https://github.com/OffskyLab/AIToolKit` `from: "0.1.0"`, which requires Task
4's `gh repo create … --push` to have succeeded. If the repo is private or the
tag is missing, Task 5 fails at dependency resolution with a message about
resolving the package rather than anything about this plan. Confirm the tag is
visible before starting Task 5.
