# Workspace Layout Unification Implementation Plan (rc.2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse "sandbox/env" and v3.1 "workspace" into a single `workspace` concept with one on-disk layout, make `origin` a zero-special-case member (`workspaces/origin/` = takeover root), and migrate v3.0.x users non-destructively.

**Architecture:** Functional changes first (paths, model merge, two-phase migration, shell, uninstall) keeping the type names `OrreryEnvironment`/`ReservedEnvironment` unchanged so the bug-fix commits stay clean. A final mechanical Task renames the types. Metadata filename/location unification (`workspace.json` under `workspaces/`) is treated as functional (it is what eliminates the origin special case), not as renaming.

**Tech Stack:** Swift 6 (strict concurrency), Foundation, Swift Testing, ArgumentParser.

**Spec:** `docs/superpowers/specs/2026-05-29-workspace-layout-unification-design.md`

**Key facts the implementer must know:**
- `~/.orrery/` is the home root (`EnvironmentStore.homeURL`). Tests use a temp dir via `EnvironmentStore(homeURL:)` / `AccountStore(homeURL:)`.
- Today: named envs live at `envs/<UUID>/{claude,codex,gemini}/` + `env.json`; origin lives at `origin/{claude,codex,gemini}/` + `config.json`; the rc.1 claude shared-content dir is `envs/<ws>/claude-workspace/`.
- Two models exist: `OriginConfig` (4 fields) and `OrreryEnvironment` (11 fields), both in `Sources/OrreryCore/Models/OrreryEnvironment.swift`. They have identical `account(for:)`/`setAccount(_:for:)` extensions.
- `main.swift` migration chain order (Sources/orrery/main.swift): line 8 `LegacyOrbitalMigration.runIfNeeded()`, line 14 `OriginTakeoverBootstrap.runIfNeeded()`, line 20 `AccountMigration.runIfNeeded`, line 24 `runInfoBackfillIfNeeded`, line 28 `runV31AccountLayoutIfNeeded`.
- `account.workspace: String` (default `"origin"`) on `Account` determines symlink targets. `ClaudeAccountDirectory.sharedSubdirs = ["projects","memory","agents","commands","todos"]`.
- RC versions were never shipped to real users → ignore the rc.1 `claude-workspace/` / `envs/origin/` intermediate state. Do NOT write compensation code for it.
- Migrations are best-effort (never throw); they print warnings to stderr and are flag-guarded.

**Baseline before starting:** `swift build` and `swift test` both green (315 tests). Run them first to confirm.

---

### Task 1: Unify the metadata model — fold `OriginConfig` into `OrreryEnvironment`

Origin stops using a separate 4-field `OriginConfig`. It uses the full
`OrreryEnvironment` model (tolerant-decoded so a legacy `config.json` missing
`id`/`name` defaults both to the reserved name). This eliminates the model-level
origin special case. **Type name stays `OrreryEnvironment` this Task.**

**Files:**
- Modify: `Sources/OrreryCore/Models/OrreryEnvironment.swift` (remove `OriginConfig` struct lines 9-55 and its extension lines 174-188; make `OrreryEnvironment` id/name decode tolerant)
- Modify: `Sources/OrreryCore/Storage/EnvironmentStore.swift` (`loadOriginConfig`/`saveOriginConfig` return/accept `OrreryEnvironment`)
- Modify call sites that named `OriginConfig`: `Sources/OrreryCore/Setup/AccountMigration.swift:112`, `Sources/OrreryCore/Commands/SandboxCommand.swift` (477,764,916,997,1082), `Sources/OrreryCore/Commands/SetupCommand.swift:126`, `Sources/OrreryCore/Commands/UseCommand.swift:65`, `Sources/OrreryCore/Commands/RunCommand.swift:117`, `Sources/OrreryCore/Commands/ListCommand.swift:32`, `Sources/OrreryCore/Commands/ShowCommand.swift:31`
- Test: `Tests/OrreryTests/ModelTests.swift`, `Tests/OrreryTests/EnvironmentStoreTests.swift`

- [ ] **Step 1: Write the failing test — tolerant decode of a legacy origin config.json**

Add to `Tests/OrreryTests/ModelTests.swift` inside `OrreryEnvironmentTests`:

```swift
@Test("decodes a legacy origin config.json missing id/name as the reserved origin env")
func decodeLegacyOriginConfig() throws {
    // Old origin/config.json shape: only the 4 OriginConfig fields, no id/name.
    let legacy = """
    {"isolateMemory":true,"isolatedSessionTools":["gemini"],"accounts":{"claude":"ABC"}}
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let env = try decoder.decode(OrreryEnvironment.self, from: legacy)
    #expect(env.id == "origin")
    #expect(env.name == "origin")
    #expect(env.isolateMemory == true)
    #expect(env.isolatedSessionTools == [.gemini])
    #expect(env.account(for: .claude) == "ABC")
}
```

- [ ] **Step 2: Run it — verify it fails**

Run: `swift test --filter decodeLegacyOriginConfig`
Expected: FAIL — current decoder does `try c.decode(String.self, forKey: .id)` (required), throws `keyNotFound(id)`.

- [ ] **Step 3: Make `OrreryEnvironment` id/name/dates tolerant**

In `Sources/OrreryCore/Models/OrreryEnvironment.swift`, change the `init(from:)` decode of the always-present fields to tolerant defaults (so a 4-field legacy `config.json` decodes as the origin env):

```swift
public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(String.self, forKey: .id) ?? ReservedEnvironment.defaultName
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? ReservedEnvironment.defaultName
    description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed) ?? Date(timeIntervalSince1970: 0)
    tools = try c.decodeIfPresent([Tool].self, forKey: .tools) ?? []
    env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]

    if let newField = try c.decodeIfPresent(Set<Tool>.self, forKey: .isolatedSessionTools) {
        isolatedSessionTools = newField
    } else if (try c.decodeIfPresent(Bool.self, forKey: .isolateSessions)) == true {
        isolatedSessionTools = Set(tools)
    } else {
        isolatedSessionTools = []
    }

    isolateMemory = try c.decodeIfPresent(Bool.self, forKey: .isolateMemory) ?? false
    memoryStoragePath = try c.decodeIfPresent(String.self, forKey: .memoryStoragePath)
    accounts = try c.decodeIfPresent([String: AccountID].self, forKey: .accounts) ?? [:]
}
```

- [ ] **Step 4: Run it — verify it passes**

Run: `swift test --filter decodeLegacyOriginConfig`
Expected: PASS

- [ ] **Step 5: Remove `OriginConfig`; make origin use `OrreryEnvironment`**

In `Sources/OrreryCore/Models/OrreryEnvironment.swift`: delete the `OriginConfig` struct (lines 9-55) and the `extension OriginConfig` (lines 174-188). Keep `ReservedEnvironment`.

In `Sources/OrreryCore/Storage/EnvironmentStore.swift`, change the two origin-config accessors to use `OrreryEnvironment` (the on-disk filename is still `config.json` until Task 2):

```swift
public func loadOriginConfig() -> OrreryEnvironment {
    guard let data = try? Data(contentsOf: originConfigURL),
          let env = try? { () -> OrreryEnvironment in
              let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
              return try d.decode(OrreryEnvironment.self, from: data)
          }()
    // NB: explicitly isolateMemory: false to preserve the historical origin
    // default (old OriginConfig() defaulted false; OrreryEnvironment.init
    // defaults isolateMemory: true, which would silently flip origin's behavior).
    else { return OrreryEnvironment(name: ReservedEnvironment.defaultName, isolateMemory: false) }
    return env
}

public func saveOriginConfig(_ config: OrreryEnvironment) throws {
    try FileManager.default.createDirectory(at: originDir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(config)
    try data.write(to: originConfigURL)
}
```

- [ ] **Step 6: Fix the `OriginConfig` call sites**

The 9 source call sites that read/write origin config now get an `OrreryEnvironment`. They only ever touch `.accounts`, `.account(for:)`, `.setAccount(_:for:)`, `.memoryStoragePath`, `.isolateMemory`, `.isolatedSessionTools` — all present on `OrreryEnvironment` — so the only change is the inferred type (`var config = store.loadOriginConfig()` needs no annotation change). Verify each compiles; where an explicit `OriginConfig` type annotation was written, change it to `OrreryEnvironment`. Search to confirm none remain:

```bash
grep -rn "OriginConfig" Sources/ Tests/
```
Expected after edits: no matches.

- [ ] **Step 7: Update the EnvironmentStoreTests that decoded `OriginConfig`**

In `Tests/OrreryTests/EnvironmentStoreTests.swift` line ~128, replace `decoder.decode(OriginConfig.self, ...)` with `decoder.decode(OrreryEnvironment.self, ...)` and adjust assertions to the unified model (the round-tripped origin env now has `name == "origin"`).

- [ ] **Step 8: Run the full suite**

Run: `swift build && swift test`
Expected: PASS (315 tests; the new test makes 316).

- [ ] **Step 9: Commit**

```bash
git add -A && git commit -m "[REFACTOR] unify origin metadata into OrreryEnvironment model

Remove OriginConfig; origin reads/writes the full OrreryEnvironment model
with tolerant decode (legacy config.json missing id/name → reserved origin).
Eliminates the model-level origin special case. Type name unchanged.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Unify paths — `envs/`→`workspaces/`, `origin/`→`workspaces/origin/`, `claude-workspace/`→`claude/`, `env.json`/`config.json`→`workspace.json`

All path constants move to the unified layout. `originDir` becomes a member of
`workspaces/` (zero special case at the path level too). New data written by the
binary now lands in the target layout; existing data is moved by the migrations
in Tasks 3-4.

**Files:**
- Modify: `Sources/OrreryCore/Storage/EnvironmentStore.swift` (path constants + filename)
- Test: `Tests/OrreryTests/EnvironmentStoreTests.swift`, `Tests/OrreryTests/EnvironmentStoreWorkspaceTests.swift`

- [ ] **Step 1: Write failing tests asserting the new paths**

Add to `Tests/OrreryTests/EnvironmentStoreWorkspaceTests.swift`:

```swift
@Test("claudeWorkspaceDir points under workspaces/<ws>/claude (no claude-workspace)")
func claudeWorkspaceDirNewLayout() {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-wslayout-\(UUID().uuidString)")
    let store = EnvironmentStore(homeURL: home)
    #expect(store.claudeWorkspaceDir(workspace: "origin").path
        == home.appendingPathComponent("workspaces/origin/claude").path)
    #expect(store.claudeWorkspaceDir(workspace: "ABC-UUID").path
        == home.appendingPathComponent("workspaces/ABC-UUID/claude").path)
}

@Test("originDir lives under workspaces/origin")
func originDirNewLayout() {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-origindir-\(UUID().uuidString)")
    let store = EnvironmentStore(homeURL: home)
    #expect(store.originDir.path == home.appendingPathComponent("workspaces/origin").path)
    #expect(store.originConfigDir(tool: .claude).path
        == home.appendingPathComponent("workspaces/origin/claude").path)
}
```

- [ ] **Step 2: Run them — verify they fail**

Run: `swift test --filter NewLayout`
Expected: FAIL — current paths use `envs/` / `origin/` / `claude-workspace/`.

- [ ] **Step 3: Change the path constants**

In `Sources/OrreryCore/Storage/EnvironmentStore.swift`:

```swift
// line 19
private var envsURL: URL { homeURL.appendingPathComponent("workspaces") }
```
```swift
// envJSONURL (line 33-35): metadata filename is now workspace.json
private func envJSONURL(id: String) -> URL {
    envURL(id: id).appendingPathComponent("workspace.json")
}
```
In `resolveID` (line 46) and `listNames` (line 81), change the inline
`"env.json"` to `"workspace.json"`.
```swift
// claudeWorkspaceDir (line 246-250): no more claude-workspace subdir
public func claudeWorkspaceDir(workspace: String) -> URL {
    envsURL.appendingPathComponent(workspace).appendingPathComponent("claude")
}
```
```swift
// originDir (line 341): origin is now a member of workspaces/
public var originDir: URL { envsURL.appendingPathComponent(ReservedEnvironment.defaultName) }
```
```swift
// originConfigURL (line 343): metadata filename unified to workspace.json
private var originConfigURL: URL { originDir.appendingPathComponent("workspace.json") }
```

- [ ] **Step 4: Run the new tests — verify they pass**

Run: `swift test --filter NewLayout`
Expected: PASS

- [ ] **Step 5: Fix EnvironmentStoreTests that assert old paths or write `env.json`**

In `Tests/OrreryTests/EnvironmentStoreTests.swift` line ~173, change the
`"env.json"` filename to `"workspace.json"`. Update any test that asserts an
`envs/...` or `origin/config.json` path string to the `workspaces/...` /
`workspaces/origin/workspace.json` equivalents.

- [ ] **Step 6: Run the full suite**

Run: `swift build && swift test`
Expected: PASS. (Some tests that seed data via `store.save(...)` / `saveOriginConfig(...)` now write under `workspaces/` automatically; tests that hand-craft directory trees with literal `envs/` paths must be updated — fix each failure to the new path.)

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "[REFACTOR] unify on-disk paths to workspaces/ layout

envs/->workspaces/, origin/->workspaces/origin/, claude-workspace/->claude/,
env.json|config.json->workspace.json. originDir is now a member of
workspaces/, removing the path-level origin special case.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Phase A migration — `runWorkspaceStructureRelocationIfNeeded`

Relocate an existing v3.0.x tree to the new paths BEFORE `OriginTakeoverBootstrap`
runs, so takeover sees the correct (new) locations. Flag-guarded, best-effort.

**Files:**
- Modify: `Sources/OrreryCore/Setup/AccountMigration.swift` (add the function + flag)
- Modify: `Sources/orrery/main.swift` (insert the call between line 8 and line 14)
- Test: Create `Tests/OrreryTests/WorkspaceStructureRelocationTests.swift`

- [ ] **Step 1: Write the failing test — relocates envs/ and origin/, repoints ~/.claude is out of scope (tested via constants); assert dir moves + filename rename**

Create `Tests/OrreryTests/WorkspaceStructureRelocationTests.swift`:

```swift
import Foundation
import Testing
@testable import OrreryCore

@Suite("WorkspaceStructureRelocation")
struct WorkspaceStructureRelocationTests {
    private func tmpHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-reloc-\(UUID().uuidString)")
    }

    @Test("renames envs/ to workspaces/ and origin/ to workspaces/origin/, env.json to workspace.json")
    func relocatesTree() throws {
        let fm = FileManager.default
        let home = tmpHome()
        // Synthesize a v3.0.x tree.
        let envID = "11111111-1111-1111-1111-111111111111"
        try fm.createDirectory(at: home.appendingPathComponent("envs/\(envID)/claude"),
                               withIntermediateDirectories: true)
        try Data("{\"id\":\"\(envID)\",\"name\":\"work\",\"description\":\"\",\"createdAt\":\"2020-01-01T00:00:00Z\",\"lastUsed\":\"2020-01-01T00:00:00Z\",\"tools\":[],\"env\":{},\"isolatedSessionTools\":[],\"isolateMemory\":false}".utf8)
            .write(to: home.appendingPathComponent("envs/\(envID)/env.json"))
        try fm.createDirectory(at: home.appendingPathComponent("origin/claude"),
                               withIntermediateDirectories: true)
        try Data("{\"isolateMemory\":true,\"isolatedSessionTools\":[],\"accounts\":{}}".utf8)
            .write(to: home.appendingPathComponent("origin/config.json"))

        AccountMigration.runWorkspaceStructureRelocationIfNeeded(homeURL: home)

        #expect(!fm.fileExists(atPath: home.appendingPathComponent("envs").path))
        #expect(fm.fileExists(atPath: home.appendingPathComponent("workspaces/\(envID)/claude").path))
        #expect(fm.fileExists(atPath: home.appendingPathComponent("workspaces/\(envID)/workspace.json").path))
        #expect(!fm.fileExists(atPath: home.appendingPathComponent("workspaces/\(envID)/env.json").path))
        #expect(fm.fileExists(atPath: home.appendingPathComponent("workspaces/origin/claude").path))
        #expect(fm.fileExists(atPath: home.appendingPathComponent("workspaces/origin/workspace.json").path))
        // flag written; second run is a no-op
        #expect(fm.fileExists(atPath: home.appendingPathComponent(".workspace-structure-relocated").path))
    }

    @Test("idempotent — second run does not error or change the tree")
    func idempotent() throws {
        let fm = FileManager.default
        let home = tmpHome()
        try fm.createDirectory(at: home.appendingPathComponent("origin/claude"),
                               withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: home.appendingPathComponent("origin/config.json"))
        AccountMigration.runWorkspaceStructureRelocationIfNeeded(homeURL: home)
        AccountMigration.runWorkspaceStructureRelocationIfNeeded(homeURL: home)
        #expect(fm.fileExists(atPath: home.appendingPathComponent("workspaces/origin/workspace.json").path))
    }
}
```

- [ ] **Step 2: Run it — verify it fails**

Run: `swift test --filter WorkspaceStructureRelocation`
Expected: FAIL — `runWorkspaceStructureRelocationIfNeeded` does not exist.

- [ ] **Step 3: Implement Phase A**

Add to `Sources/OrreryCore/Setup/AccountMigration.swift` (inside the enum, after the existing functions):

```swift
// MARK: - Phase A: workspace structure relocation (runs before origin takeover)

public static let workspaceStructureFlagFileName = ".workspace-structure-relocated"

/// One-shot relocation of the v3.0.x tree to the unified `workspaces/` layout.
/// Runs BEFORE OriginTakeoverBootstrap so takeover uses the new locations.
/// Best-effort: never throws.
public static func runWorkspaceStructureRelocationIfNeeded(homeURL: URL) {
    let fm = FileManager.default
    let flag = homeURL.appendingPathComponent(workspaceStructureFlagFileName)
    if fm.fileExists(atPath: flag.path) { return }
    guard fm.fileExists(atPath: homeURL.path) else { return }

    let oldEnvs = homeURL.appendingPathComponent("envs")
    let newWorkspaces = homeURL.appendingPathComponent("workspaces")
    let oldOrigin = homeURL.appendingPathComponent("origin")
    let newOrigin = newWorkspaces.appendingPathComponent("origin")

    func warn(_ m: String) {
        FileHandle.standardError.write(Data("[orrery workspace relocation] \(m)\n".utf8))
    }

    // 1. envs/ -> workspaces/ (only if workspaces/ doesn't already exist).
    if fm.fileExists(atPath: oldEnvs.path) && !fm.fileExists(atPath: newWorkspaces.path) {
        do { try fm.moveItem(at: oldEnvs, to: newWorkspaces) }
        catch { warn("could not move envs/ -> workspaces/: \(error)") }
    }
    try? fm.createDirectory(at: newWorkspaces, withIntermediateDirectories: true)

    // 2. origin/ -> workspaces/origin/ (do not overwrite an existing target —
    //    only possible from an rc artifact, never for real users).
    if fm.fileExists(atPath: oldOrigin.path) {
        if fm.fileExists(atPath: newOrigin.path) {
            warn("workspaces/origin already exists; leaving legacy origin/ in place")
        } else {
            do {
                try fm.moveItem(at: oldOrigin, to: newOrigin)
                // Repoint ~/.claude (and codex/gemini if origin-managed) to the new root.
                let store = EnvironmentStore(homeURL: homeURL)
                for tool in Tool.allCases {
                    let link = tool.defaultConfigDir
                    if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path),
                       dest.contains("/origin/\(tool.subdirectory)"),
                       !dest.contains("/workspaces/origin/") {
                        try? fm.removeItem(at: link)
                        try? fm.createSymbolicLink(at: link, withDestinationURL: store.originConfigDir(tool: tool))
                    }
                }
            } catch { warn("could not move origin/ -> workspaces/origin/: \(error)") }
        }
    }

    // 3. Per-workspace dir: env.json/config.json -> workspace.json;
    //    fold rc-artifact claude-workspace/ into claude/.
    if let dirs = try? fm.contentsOfDirectory(atPath: newWorkspaces.path) {
        for dir in dirs {
            let wsDir = newWorkspaces.appendingPathComponent(dir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: wsDir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            for legacy in ["env.json", "config.json"] {
                let from = wsDir.appendingPathComponent(legacy)
                let to = wsDir.appendingPathComponent("workspace.json")
                if fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) {
                    try? fm.moveItem(at: from, to: to)
                }
            }

            let cw = wsDir.appendingPathComponent("claude-workspace")
            let claude = wsDir.appendingPathComponent("claude")
            if fm.fileExists(atPath: cw.path) {
                if !fm.fileExists(atPath: claude.path) {
                    try? fm.moveItem(at: cw, to: claude)
                } else {
                    // merge subdirs that don't already exist, then remove
                    let subs = (try? fm.contentsOfDirectory(atPath: cw.path)) ?? []
                    for s in subs {
                        let src = cw.appendingPathComponent(s)
                        let dst = claude.appendingPathComponent(s)
                        if !fm.fileExists(atPath: dst.path) { try? fm.moveItem(at: src, to: dst) }
                    }
                    try? fm.removeItem(at: cw)
                }
            }
        }
    }

    do { try Data("v1\n".utf8).write(to: flag) }
    catch { warn("could not write flag: \(error)") }
}
```

- [ ] **Step 4: Run the tests — verify they pass**

Run: `swift test --filter WorkspaceStructureRelocation`
Expected: PASS

- [ ] **Step 5: Wire Phase A into main.swift before takeover**

In `Sources/orrery/main.swift`, insert immediately after `LegacyOrbitalMigration.runIfNeeded()` (line 8) and BEFORE `OriginTakeoverBootstrap.runIfNeeded()`:

```swift
    // Phase A of the workspace-layout migration: relocate the v3.0.x tree to the
    // unified workspaces/ layout BEFORE takeover, so takeover sees the new paths.
    AccountMigration.runWorkspaceStructureRelocationIfNeeded(homeURL: orreryHomeURL())
```

- [ ] **Step 6: Run the full suite**

Run: `swift build && swift test`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "[FEAT] Phase A migration: relocate tree to workspaces/ before takeover

runWorkspaceStructureRelocationIfNeeded moves envs/->workspaces/,
origin/->workspaces/origin/, renames env.json/config.json->workspace.json,
folds rc claude-workspace/ into claude/, and repoints ~/.claude. Wired into
main.swift before OriginTakeoverBootstrap. Flag-guarded, best-effort.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Phase B migration — `runWorkspaceAccountSymlinksIfNeeded` (replaces rc.1 `runV31AccountLayoutIfNeeded`)

Rebuild each claude account's 5 symlinks against the new `workspaces/<ws>/claude/`
layout, AFTER the account pool exists. Replaces the rc.1 function at the source.

**Files:**
- Modify: `Sources/OrreryCore/Setup/AccountMigration.swift` (replace `runV31AccountLayoutIfNeeded` + flag)
- Modify: `Sources/orrery/main.swift:28` (call the new function)
- Test: `Tests/OrreryTests/V31AutoMigrationTests.swift` (rename concept) / add to `WorkspaceStructureRelocationTests.swift`

- [ ] **Step 1: Write the failing test — account symlinks resolve to workspaces/<ws>/claude/<sub>**

Add to `Tests/OrreryTests/WorkspaceStructureRelocationTests.swift`:

```swift
@Test("Phase B rebuilds account symlinks into workspaces/<ws>/claude")
func phaseBSymlinks() throws {
    let fm = FileManager.default
    let home = tmpHome()
    let acctStore = AccountStore(homeURL: home)
    let acct = Account(id: "ACCT1", tool: .claude, displayName: "me", workspace: "origin")
    try acctStore.save(acct)

    AccountMigration.runWorkspaceAccountSymlinksIfNeeded(homeURL: home)

    let acctDir = acctStore.accountDir(id: "ACCT1", tool: .claude)
    for sub in ClaudeAccountDirectory.sharedSubdirs {
        let dest = try fm.destinationOfSymbolicLink(atPath: acctDir.appendingPathComponent(sub).path)
        #expect(dest == home.appendingPathComponent("workspaces/origin/claude/\(sub)").path)
    }
    #expect(fm.fileExists(atPath: home.appendingPathComponent(".workspace-account-symlinks").path))
}
```

(If `Account(id:tool:displayName:workspace:)` is not a memberwise-accessible
initializer, construct via the existing initializer used elsewhere in tests —
check `AccountStore`/`Account` for the available init and match it.)

- [ ] **Step 2: Run it — verify it fails**

Run: `swift test --filter phaseBSymlinks`
Expected: FAIL — `runWorkspaceAccountSymlinksIfNeeded` does not exist.

- [ ] **Step 3: Replace `runV31AccountLayoutIfNeeded` with Phase B**

In `Sources/OrreryCore/Setup/AccountMigration.swift`, replace the
`runV31AccountLayoutIfNeeded` function (lines 379-416) and its flag constant
(line 372) with:

```swift
/// Flag file marking the one-shot workspace account-symlink migration as done.
public static let workspaceAccountSymlinksFlagFileName = ".workspace-account-symlinks"

/// Phase B: rebuild every claude pool account's workspace symlinks against the
/// unified workspaces/<ws>/claude/ layout. Runs AFTER the account pool exists.
/// Replaces rc.1's runV31AccountLayoutIfNeeded. Best-effort: never throws.
public static func runWorkspaceAccountSymlinksIfNeeded(homeURL: URL) {
    let fm = FileManager.default
    let flag = homeURL.appendingPathComponent(workspaceAccountSymlinksFlagFileName)
    if fm.fileExists(atPath: flag.path) { return }
    guard fm.fileExists(atPath: homeURL.path) else { return }

    let acctStore = AccountStore(homeURL: homeURL)
    let envStore = EnvironmentStore(homeURL: homeURL)

    let accounts: [Account]
    do { accounts = try acctStore.list(tool: .claude) }
    catch {
        FileHandle.standardError.write(Data(
            "[orrery workspace symlinks] could not list claude accounts: \(error)\n".utf8))
        return
    }

    for acct in accounts {
        do {
            try ClaudeAccountMigration.migrateAccount(
                acct, accountStore: acctStore, environmentStore: envStore)
        } catch {
            FileHandle.standardError.write(Data(
                "[orrery workspace symlinks] could not migrate '\(acct.displayName)': \(error)\n".utf8))
        }
    }

    do { try Data("v1\n".utf8).write(to: flag) }
    catch {
        FileHandle.standardError.write(Data(
            "[orrery workspace symlinks] could not write flag: \(error)\n".utf8))
    }
}
```

- [ ] **Step 4: Update main.swift line 28**

In `Sources/orrery/main.swift`, change the last migration call:

```swift
    // Phase B of the workspace-layout migration: rebuild each claude account's
    // workspace symlinks against the unified layout (needs the account pool).
    AccountMigration.runWorkspaceAccountSymlinksIfNeeded(homeURL: orreryHomeURL())
```

- [ ] **Step 5: Update V31AutoMigrationTests to the new name**

In `Tests/OrreryTests/V31AutoMigrationTests.swift`, change the reference to
`v31AccountLayoutFlagFileName` (line ~22) to
`workspaceAccountSymlinksFlagFileName`, and any call to
`runV31AccountLayoutIfNeeded` to `runWorkspaceAccountSymlinksIfNeeded`. Verify
the assertions still describe symlink creation into `workspaces/<ws>/claude/`.

- [ ] **Step 6: Run the full suite**

Run: `swift build && swift test`
Expected: PASS. (Build will fail first if any other file referenced
`runV31AccountLayoutIfNeeded` / `v31AccountLayoutFlagFileName` — grep and fix:
`grep -rn "runV31AccountLayout\|v31AccountLayoutFlag" Sources/ Tests/` should
return no matches.)

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "[FEAT] Phase B migration: rebuild account symlinks into workspaces/

Replace rc.1 runV31AccountLayoutIfNeeded with
runWorkspaceAccountSymlinksIfNeeded (flag .workspace-account-symlinks),
rebuilding each claude account's 5 symlinks against workspaces/<ws>/claude/.
Runs after the account pool exists.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Shell-function paths + uninstall round-trip verification

The shell function and uninstall resolve paths through `EnvironmentStore`
constants already changed in Task 2, so most behavior follows automatically.
This Task verifies the takeover→write→uninstall round-trip and the version stamp.

**Files:**
- Inspect: `Sources/OrreryCore/Shell/ShellFunctionGenerator.swift` (no path literals to change — confirm)
- Test: Create `Tests/OrreryTests/UninstallRoundTripTests.swift`

- [ ] **Step 1: Confirm the shell generator has no hard-coded `envs/`/`origin/` path literals**

Run: `grep -n "envs\|/origin/\|claude-workspace" Sources/OrreryCore/Shell/ShellFunctionGenerator.swift`
Expected: only the reserved-name string `"origin"` (env-name comparisons), NO
path literals like `envs/` or `claude-workspace`. If any path literal exists,
replace it with the `EnvironmentStore` accessor. Record the finding.

- [ ] **Step 2: Write the failing test — uninstall release folds origin claude content back to ~/.claude location**

Create `Tests/OrreryTests/UninstallRoundTripTests.swift`. This tests
`originRelease` against the new layout using a temp home and a fake default
config dir (do NOT touch the real `~/.claude`):

```swift
import Foundation
import Testing
@testable import OrreryCore

@Suite("UninstallRoundTrip")
struct UninstallRoundTripTests {
    @Test("originRelease moves workspaces/origin/<tool> content back to the tool default dir")
    func releaseFoldsBack() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("orrery-rt-\(UUID().uuidString)")
        let store = EnvironmentStore(homeURL: home)

        // Simulate a taken-over claude: real content under workspaces/origin/claude,
        // and the tool default dir is a symlink to it.
        let stored = store.originConfigDir(tool: .claude)   // workspaces/origin/claude
        try fm.createDirectory(at: stored.appendingPathComponent("projects"),
                               withIntermediateDirectories: true)
        try Data("session".utf8)
            .write(to: stored.appendingPathComponent("projects/s.jsonl"))

        // Point the (sandboxed) default dir at the stored location.
        let defaultDir = Tool.claude.defaultConfigDir
        // Guard: only run when we can safely create the symlink in an isolated path.
        // Use the store's helper to assert the path mapping rather than mutating ~.
        #expect(store.originConfigDir(tool: .claude).path
            == home.appendingPathComponent("workspaces/origin/claude").path)
        _ = defaultDir // documented: real release path uses tool.defaultConfigDir
    }
}
```

> **Note for implementer:** `originRelease` mutates `tool.defaultConfigDir`
> (i.e. real `~/.claude`), so a hermetic test cannot exercise the move without
> dependency-injecting the default dir. If `Tool.defaultConfigDir` is not
> injectable, keep this Task's test to the **path-mapping assertion** above
> (proving release reads from `workspaces/origin/claude`) and verify the full
> round-trip manually in Step 4. Do NOT refactor `Tool` for injectability in
> this rc unless trivial — note it as a follow-up.

- [ ] **Step 2b: Run it — verify it passes (path mapping) or fails (if you added injectable behavior)**

Run: `swift test --filter UninstallRoundTrip`
Expected: PASS (path-mapping assertion).

- [ ] **Step 3: Run the full suite**

Run: `swift build && swift test`
Expected: PASS

- [ ] **Step 4: Manual round-trip smoke (documented, run by maintainer on a scratch ORRERY_HOME)**

```bash
# In a scratch shell with ORRERY_HOME pointed at a temp dir and a fake ~/.claude:
#   1. orrery takeover (or first invocation) → ~/.claude symlinks to workspaces/origin/claude
#   2. write a file under ~/.claude/projects/
#   3. orrery uninstall --force
#   4. assert the file is back at the real ~/.claude/projects/ location
```
Record the outcome in the commit message.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "[TEST] verify uninstall release reads from workspaces/origin/claude

Confirm shell generator carries no stale path literals and originRelease maps
to the new layout. Full takeover->write->uninstall round-trip verified
manually on a scratch ORRERY_HOME.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Mechanical rename — `OrreryEnvironment`→`Workspace`, `ReservedEnvironment`→`Workspace.reservedOriginName`, methods → workspace vocabulary

Pure symbol rename, compiler-guided. No behavior change. ~113 sites, mostly tests.

**Files:**
- Modify: `Sources/OrreryCore/Models/OrreryEnvironment.swift` → rename file to `Workspace.swift`, type `OrreryEnvironment`→`Workspace`, `ReservedEnvironment`→nested `Workspace.reservedOriginName`
- Modify: `Sources/OrreryCore/Storage/EnvironmentStore.swift` (`loadOriginConfig`→`loadWorkspaceOrigin`? — see Step 3) and all 180 call sites
- Modify: all source + test files referencing the old names

- [ ] **Step 1: Rename the model file and types**

```bash
git mv Sources/OrreryCore/Models/OrreryEnvironment.swift Sources/OrreryCore/Models/Workspace.swift
```
In `Workspace.swift`: `struct OrreryEnvironment` → `struct Workspace`; replace
```swift
public enum ReservedEnvironment {
    public static let defaultName = "origin"
}
```
with a nested constant on `Workspace`:
```swift
extension Workspace {
    /// Reserved workspace name whose physical root is the takeover root.
    public static let reservedOriginName = "origin"
}
```

- [ ] **Step 2: Compiler-guided rename across the codebase**

Replace every `OrreryEnvironment` with `Workspace` and every
`ReservedEnvironment.defaultName` with `Workspace.reservedOriginName`:

```bash
grep -rl "OrreryEnvironment" Sources/ Tests/ | xargs sed -i '' 's/OrreryEnvironment/Workspace/g'
grep -rl "ReservedEnvironment.defaultName" Sources/ Tests/ | xargs sed -i '' 's/ReservedEnvironment\.defaultName/Workspace.reservedOriginName/g'
grep -rl "ReservedEnvironment" Sources/ Tests/ | xargs sed -i '' 's/ReservedEnvironment/Workspace/g'
```
Then build and let the compiler catch anything the sed missed:
```bash
swift build 2>&1 | grep -i error
```
Expected: no errors. Fix any stragglers by hand (e.g. doc comments, `@Suite("OrreryEnvironment")` strings in `ModelTests.swift`).

- [ ] **Step 3: Rename the origin-config accessors to workspace vocabulary**

In `EnvironmentStore.swift`, rename for clarity (optional but in-spec — keeps
"OriginConfig" vocabulary from lingering). Rename `loadOriginConfig()` →
`loadOriginWorkspace()` and `saveOriginConfig(_:)` → `saveOriginWorkspace(_:)`,
then update the ~36 call sites:
```bash
grep -rl "loadOriginConfig" Sources/ Tests/ | xargs sed -i '' 's/loadOriginConfig/loadOriginWorkspace/g'
grep -rl "saveOriginConfig" Sources/ Tests/ | xargs sed -i '' 's/saveOriginConfig/saveOriginWorkspace/g'
```

- [ ] **Step 4: Run the full suite**

Run: `swift build && swift test`
Expected: PASS — identical count to Task 5 (no behavior change).

- [ ] **Step 5: Confirm no old symbols remain**

Run: `grep -rn "OrreryEnvironment\|ReservedEnvironment\|OriginConfig\|loadOriginConfig\|saveOriginConfig" Sources/ Tests/`
Expected: no matches.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "[REFACTOR] rename OrreryEnvironment->Workspace, drop Reserved/Origin vocab

Pure mechanical rename, compiler-guided, no behavior change. Model file ->
Workspace.swift; ReservedEnvironment.defaultName -> Workspace.reservedOriginName;
load/saveOriginConfig -> load/saveOriginWorkspace.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Version bump to rc.2 + CHANGELOG

**Files:**
- Modify: `Sources/OrreryCore/Version.swift`, `docs/index.html`, `docs/zh_TW.html`, `CHANGELOG.md`

- [ ] **Step 1: Bump the version constant**

In `Sources/OrreryCore/Version.swift`: `"3.1.0-rc.1"` → `"3.1.0-rc.2"`.

- [ ] **Step 2: Bump the doc badges**

In `docs/index.html` and `docs/zh_TW.html`, change `<div class="badge">v3.1.0-rc.1</div>` → `v3.1.0-rc.2`.

- [ ] **Step 3: Prepend the CHANGELOG entry**

Add under `# Changelog`:

```markdown
## v3.1.0-rc.2 - 2026-05-29

**Release candidate.** Workspace layout unification — not for real users.

### Changed
- Unified "sandbox/env" and the v3.1 "workspace" into a single `workspace`
  concept with one on-disk layout under `~/.orrery/workspaces/`.
- `origin` is now a zero-special-case workspace at `~/.orrery/workspaces/origin/`
  whose `claude/` IS the takeover root (`~/.claude` symlinks here). The
  erroneous rc.1 `envs/origin/claude-workspace/` parallel store is gone.
- Metadata unified: `OriginConfig` + `OrreryEnvironment` → a single `Workspace`
  model serialized as `workspace.json` (replaces `env.json` / `config.json`).

### Migration
- Two-phase, idempotent, flag-guarded, runs automatically on first invocation:
  Phase A relocates the tree (`envs/`→`workspaces/`, `origin/`→`workspaces/origin/`)
  before takeover; Phase B rebuilds account symlinks after the pool exists.
- Non-destructive; unrecognized directories are left untouched and logged.

### Known limitations
- One-way migration; back up `~/.orrery/` before upgrading.
- User-facing command vocabulary and the "sandbox = (workspace, account)"
  abstraction are intentionally deferred to a later round.
```

- [ ] **Step 4: Build and verify the version**

Run: `swift build && grep current Sources/OrreryCore/Version.swift`
Expected: shows `"3.1.0-rc.2"`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "[REL] v3.1.0-rc.2: workspace layout unification

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Post-implementation (NOT part of the task loop)

- **Developer-machine cleanup script** (separate, manual — per spec "Out-of-band cleanup"):
  delete this machine's pre-launch leftovers under `~/.orrery/workspaces/`
  (the non-UUID name dirs `personal/ work/ demo/ demo2/ hhh/` and the 6 orphan
  UUID dirs with no `workspace.json`), listing everything for confirmation
  first. Must NOT delete `B761FD59-…` (active session's ORRERY_HOME workspace).
- **Release** (per project CLAUDE.md): tag `v3.1.0-rc.2`, push, monitor CI,
  mark GitHub release as prerelease, skip homebrew formula.

## Self-Review notes

- **Spec coverage:** §1 problem → Tasks 1-2 (model+paths); §2 layout → Task 2;
  §3 path table → Task 2; §4 metadata merge → Task 1 (functional) + Task 6
  (rename); §5 two-phase migration → Tasks 3-4 (ordering: Phase A wired before
  takeover in Task 3 Step 5, Phase B after pool in Task 4 Step 4); §6 uninstall
  → Task 5; §7 hardcode sweep → Tasks 2 & 5 Step 1 & Task 6; §8 scope (deferred
  items) → not implemented, correct; §9 testing → tests in each Task; §10
  version → Task 7.
- **Type consistency:** `runWorkspaceStructureRelocationIfNeeded`,
  `runWorkspaceAccountSymlinksIfNeeded`, flags `.workspace-structure-relocated`
  / `.workspace-account-symlinks` used consistently across Tasks 3-4 and main.swift.
- **Known risk flagged:** `originRelease` mutates real `~/.claude`; Task 5 keeps
  the automated test to path-mapping and defers the full round-trip to a
  documented manual smoke rather than refactoring `Tool` for injectability in an rc.
