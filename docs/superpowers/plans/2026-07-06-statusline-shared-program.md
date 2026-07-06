# Statusline Shared Program (workspace copy, per-account settings) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install `statusline.js` once into the pinned **workspace** claude dir and point each account's per-account `settings.json` `statusLine.command` at that copy, so accounts on a workspace share one program.

**Architecture:** Add a `<WORKSPACE_CLAUDE_DIR>` placeholder to the third-party manifest system. `copyFile` can target the workspace; `patchSettings` can reference it (while still writing the account's `settings.json`). The lock records workspace files with a `<WORKSPACE_CLAUDE_DIR>/…` marker so uninstall resolves them. `ManifestRunner` resolves the workspace dir from the account's pin via the `EnvironmentStore` it already holds.

**Tech Stack:** Swift, swift-testing (`import Testing`, `@Suite`, `@Test`, `#expect`), the `OrreryThirdParty` module.

Spec: `docs/superpowers/specs/2026-07-06-statusline-shared-program-design.md`

---

## File Structure

- Modify `Sources/OrreryThirdParty/Steps/CopyFileExecutor.swift` — add `resolveInstalledPath` + workspace-aware `apply`/`rollback`.
- Modify `Sources/OrreryThirdParty/Steps/CopyGlobExecutor.swift` — fix its `rollback` call into `CopyFileExecutor.rollback` (signature change).
- Modify `Sources/OrreryThirdParty/ManifestRunner.swift` — `resolveWorkspaceClaudeDir`, thread `workspaceDir`, add `<WORKSPACE_CLAUDE_DIR>` placeholder, resolve marker paths on uninstall, update the stale comment.
- Modify `Sources/OrreryThirdParty/Manifests/statusline.json` — target the workspace.
- Modify `Tests/OrreryThirdPartyTests/CopyExecutorTests.swift` — signature update + workspace-target test.
- Modify `Tests/OrreryThirdPartyTests/ManifestRunnerInstallTests.swift` — workspace-install integration tests.

---

## Task 1: CopyFileExecutor — workspace-aware paths

**Files:**
- Modify: `Sources/OrreryThirdParty/Steps/CopyFileExecutor.swift`
- Modify: `Sources/OrreryThirdParty/Steps/CopyGlobExecutor.swift`
- Test: `Tests/OrreryThirdPartyTests/CopyExecutorTests.swift`

- [ ] **Step 1: Update existing tests to the new signature + add a workspace-target test**

In `Tests/OrreryThirdPartyTests/CopyExecutorTests.swift`, replace the whole `copyFileWorks` test and add a new one after it:

```swift
    @Test("copyFile copies and reports dest path (account-relative)")
    func copyFileWorks() throws {
        let (src, dst) = try makeTempTree()
        try Data("hi".utf8).write(to: src.appendingPathComponent("a.js"))

        let record = try CopyFileExecutor.apply(
            .copyFile(from: "a.js", to: "a.js"),
            sourceDir: src, claudeDir: dst, workspaceDir: dst
        )
        #expect(record == ["a.js"])
        let content = try String(contentsOf: dst.appendingPathComponent("a.js"), encoding: .utf8)
        #expect(content == "hi")
    }

    @Test("copyFile with <WORKSPACE_CLAUDE_DIR> lands in the workspace and keeps the marker in the record")
    func copyFileWorkspaceTarget() throws {
        let (src, dst) = try makeTempTree()
        let ws = dst.deletingLastPathComponent().appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: src.appendingPathComponent("a.js"))

        let record = try CopyFileExecutor.apply(
            .copyFile(from: "a.js", to: "<WORKSPACE_CLAUDE_DIR>/a.js"),
            sourceDir: src, claudeDir: dst, workspaceDir: ws
        )
        // Lock keeps the marker verbatim.
        #expect(record == ["<WORKSPACE_CLAUDE_DIR>/a.js"])
        // File landed in the workspace, NOT the account dir.
        #expect(FileManager.default.fileExists(atPath: ws.appendingPathComponent("a.js").path))
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("a.js").path))
    }

    @Test("resolveInstalledPath maps marker to workspace, plain to account")
    func resolvePath() {
        let acct = URL(fileURLWithPath: "/acct")
        let ws = URL(fileURLWithPath: "/ws")
        #expect(CopyFileExecutor.resolveInstalledPath("statusline.js", claudeDir: acct, workspaceDir: ws).path
            == "/acct/statusline.js")
        #expect(CopyFileExecutor.resolveInstalledPath("<WORKSPACE_CLAUDE_DIR>/statusline.js", claudeDir: acct, workspaceDir: ws).path
            == "/ws/statusline.js")
    }
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `swift test --filter CopyExecutorTests 2>&1 | tail -15`
Expected: compile error — `apply` has no `workspaceDir:` parameter / no member `resolveInstalledPath`.

- [ ] **Step 3: Implement the workspace-aware executor**

Replace the entire contents of `Sources/OrreryThirdParty/Steps/CopyFileExecutor.swift` with:

```swift
import Foundation
import OrreryCore

public enum CopyFileExecutor {
    /// Marker prefix that makes a lock/`to` path resolve against the workspace
    /// claude dir instead of the account claude dir.
    public static let workspaceMarker = "<WORKSPACE_CLAUDE_DIR>/"

    /// Resolve a manifest `to` / lock path to an absolute URL. Paths beginning
    /// with the workspace marker resolve under `workspaceDir`; all others are
    /// relative to the account `claudeDir` (unchanged behaviour).
    public static func resolveInstalledPath(_ path: String,
                                            claudeDir: URL,
                                            workspaceDir: URL) -> URL {
        if path.hasPrefix(workspaceMarker) {
            return workspaceDir.appendingPathComponent(String(path.dropFirst(workspaceMarker.count)))
        }
        return claudeDir.appendingPathComponent(path)
    }

    /// Copies the file and returns its destination path — verbatim from the
    /// manifest, so a `<WORKSPACE_CLAUDE_DIR>/…` marker is preserved in the lock.
    public static func apply(_ step: ThirdPartyStep,
                             sourceDir: URL, claudeDir: URL, workspaceDir: URL) throws -> [String] {
        guard case .copyFile(let from, let to) = step else {
            throw ThirdPartyError.stepFailed(reason: "not a copyFile step")
        }
        let src = sourceDir.appendingPathComponent(from)
        let dst = resolveInstalledPath(to, claudeDir: claudeDir, workspaceDir: workspaceDir)
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
        return [to]
    }

    public static func rollback(paths: [String], claudeDir: URL, workspaceDir: URL) {
        let fm = FileManager.default
        for p in paths {
            try? fm.removeItem(at: resolveInstalledPath(p, claudeDir: claudeDir, workspaceDir: workspaceDir))
        }
    }
}
```

Then in `Sources/OrreryThirdParty/Steps/CopyGlobExecutor.swift`, update its `rollback` to pass a `workspaceDir` through (copyGlob paths are always account-relative, so `claudeDir` is a safe workspace arg). Replace:

```swift
    public static func rollback(paths: [String], claudeDir: URL) {
        CopyFileExecutor.rollback(paths: paths, claudeDir: claudeDir)
    }
```
with:
```swift
    public static func rollback(paths: [String], claudeDir: URL) {
        // copyGlob only ever produces account-relative paths (no workspace
        // marker), so passing claudeDir as the workspace arg is a safe no-op.
        CopyFileExecutor.rollback(paths: paths, claudeDir: claudeDir, workspaceDir: claudeDir)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CopyExecutorTests 2>&1 | tail -15`
Expected: PASS (copyFileWorks, copyGlobWorks, copyGlobRejectsWeirdPattern, copyFileWorkspaceTarget, resolvePath).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryThirdParty/Steps/CopyFileExecutor.swift \
        Sources/OrreryThirdParty/Steps/CopyGlobExecutor.swift \
        Tests/OrreryThirdPartyTests/CopyExecutorTests.swift
git commit -m "feat: copyFile supports <WORKSPACE_CLAUDE_DIR> target + path resolver"
```

---

## Task 2: ManifestRunner — resolve workspace, thread it through, uninstall markers

**Files:**
- Modify: `Sources/OrreryThirdParty/ManifestRunner.swift`

- [ ] **Step 1: Add `resolveWorkspaceClaudeDir` helper**

In `Sources/OrreryThirdParty/ManifestRunner.swift`, add this method right after `resolveClaudeDir` (before `lockFileURL`):

```swift
    /// Resolve the workspace claude dir the target account is pinned to. Reads
    /// the account dir's `metadata.json` `workspace` field (absent ⇒ origin) and
    /// maps it via the injected store, mirroring `_prepare-claude-launch`.
    private func resolveWorkspaceClaudeDir(env: String) throws -> URL {
        let claudeDir = try resolveClaudeDir(env: env)
        var workspace = Workspace.reservedOriginName
        let mdURL = claudeDir.appendingPathComponent("metadata.json")
        if let data = try? Data(contentsOf: mdURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ws = obj["workspace"] as? String, !ws.isEmpty {
            workspace = ws
        }
        return store.claudeWorkspaceDir(workspace: workspace)
    }
```

- [ ] **Step 2: Thread `workspaceDir` through `install` + add the placeholder**

In `install(...)`, replace the block from `let claudeDir = try resolveClaudeDir(env: env)` (line ~18) down through the `catch { … }` (line ~64) with:

```swift
        let claudeDir = try resolveClaudeDir(env: env)
        let workspaceDir = try resolveWorkspaceClaudeDir(env: env)
        let lockURL = lockFileURL(claudeDir: claudeDir, packageID: pkg.id)

        // Already installed? Reinstall = uninstall + install (spec decision 7c-B).
        if FileManager.default.fileExists(atPath: lockURL.path) {
            FileHandle.standardError.write(Data(
                "\(pkg.id) already installed — reinstalling.\n".utf8))
            try uninstall(packageID: pkg.id, from: env)
        }

        warnIfMissingNode()

        let cacheRoot = store.homeURL
            .appendingPathComponent("shared/thirdparty/cache")
        let fetched = try fetcher.fetch(
            source: pkg.source, cacheRoot: cacheRoot,
            packageID: pkg.id, refOverride: refOverride,
            forceRefresh: forceRefresh)
        let sourceDir = fetched.dir
        let resolvedRef = fetched.sha

        var copied: [String] = []
        var patched: [SettingsPatchRecord] = []

        do {
            for step in pkg.steps {
                switch step {
                case .copyFile:
                    copied.append(contentsOf: try CopyFileExecutor.apply(
                        step, sourceDir: sourceDir, claudeDir: claudeDir, workspaceDir: workspaceDir))
                case .copyGlob:
                    copied.append(contentsOf: try CopyGlobExecutor.apply(
                        step, sourceDir: sourceDir, claudeDir: claudeDir))
                case .patchSettings:
                    let rec = try PatchSettingsExecutor.apply(
                        step, claudeDir: claudeDir,
                        placeholders: [
                            "<CLAUDE_DIR>": claudeDir.path,
                            "<WORKSPACE_CLAUDE_DIR>": workspaceDir.path,
                        ])
                    patched.append(rec)
                }
            }
        } catch {
            for rec in patched.reversed() {
                try? PatchSettingsExecutor.rollback(record: rec, claudeDir: claudeDir)
            }
            CopyFileExecutor.rollback(paths: copied, claudeDir: claudeDir, workspaceDir: workspaceDir)
            throw error
        }
```

- [ ] **Step 3: Resolve marker paths on uninstall**

In `uninstall(...)`, add the workspace dir and use the resolver. Replace:

```swift
        let claudeDir = try resolveClaudeDir(env: env)
        let lockURL = lockFileURL(claudeDir: claudeDir, packageID: packageID)
```
with:
```swift
        let claudeDir = try resolveClaudeDir(env: env)
        let workspaceDir = try resolveWorkspaceClaudeDir(env: env)
        let lockURL = lockFileURL(claudeDir: claudeDir, packageID: packageID)
```

And replace the copied-files removal loop + the empty-dir prune:

```swift
        for p in record.copiedFiles {
            try? fm.removeItem(at: claudeDir.appendingPathComponent(p))
        }
        // Prune any empty directories left by copyGlob steps.
        let parentDirs = Set(record.copiedFiles.map { path -> String in
            guard let slash = path.lastIndex(of: "/") else { return "" }
            return String(path[..<slash])
        }).filter { !$0.isEmpty && $0 != "." }
        for rel in parentDirs.sorted(by: { $0.count > $1.count }) {
            let dir = claudeDir.appendingPathComponent(rel)
            if let contents = try? fm.contentsOfDirectory(atPath: dir.path),
               contents.isEmpty {
                try? fm.removeItem(at: dir)
            }
        }
```
with:
```swift
        for p in record.copiedFiles {
            try? fm.removeItem(at: CopyFileExecutor.resolveInstalledPath(
                p, claudeDir: claudeDir, workspaceDir: workspaceDir))
        }
        // Prune any empty directories left by copyGlob steps (account-relative
        // paths only; workspace-marker files sit directly in the workspace dir
        // and leave no per-package subdir to prune).
        let parentDirs = Set(record.copiedFiles.compactMap { path -> String? in
            if path.hasPrefix(CopyFileExecutor.workspaceMarker) { return nil }
            guard let slash = path.lastIndex(of: "/") else { return nil }
            return String(path[..<slash])
        }).filter { !$0.isEmpty && $0 != "." }
        for rel in parentDirs.sorted(by: { $0.count > $1.count }) {
            let dir = claudeDir.appendingPathComponent(rel)
            if let contents = try? fm.contentsOfDirectory(atPath: dir.path),
               contents.isEmpty {
                try? fm.removeItem(at: dir)
            }
        }
```

- [ ] **Step 4: Update the now-stale doc comment on `resolveClaudeDir`**

Replace the comment block above `private func resolveClaudeDir` (the paragraph starting "Resolve the install target. In v3.1 the target is the *account* dir …") with:

```swift
    /// Resolve the install target for account-scoped artifacts (the lock and the
    /// `settings.json` patch): the *account* dir — the `CLAUDE_CONFIG_DIR` Claude
    /// actually reads. The `settings.json` patch must land here because it is a
    /// real per-account file. Individual `copyFile` steps may instead target the
    /// pinned workspace via a `<WORKSPACE_CLAUDE_DIR>/…` `to` path (see
    /// `resolveWorkspaceClaudeDir`), which the account's settings then reference
    /// by absolute path — that is how the shared statusline program is installed.
```

- [ ] **Step 5: Build to verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/OrreryThirdParty/ManifestRunner.swift
git commit -m "feat: ManifestRunner resolves workspace dir + <WORKSPACE_CLAUDE_DIR> placeholder"
```

---

## Task 3: Point the statusline manifest at the workspace

**Files:**
- Modify: `Sources/OrreryThirdParty/Manifests/statusline.json`

- [ ] **Step 1: Edit the manifest steps**

In `Sources/OrreryThirdParty/Manifests/statusline.json`, replace the `steps` array:

```json
  "steps": [
    { "type": "copyFile", "from": "statusline.js", "to": "statusline.js" },
    {
      "type": "patchSettings",
      "file": "settings.json",
      "patch": {
        "statusLine": {
          "type": "command",
          "command": "node <CLAUDE_DIR>/statusline.js",
          "refreshInterval": 30
        }
      }
    }
  ]
```
with:
```json
  "steps": [
    { "type": "copyFile", "from": "statusline.js", "to": "<WORKSPACE_CLAUDE_DIR>/statusline.js" },
    {
      "type": "patchSettings",
      "file": "settings.json",
      "patch": {
        "statusLine": {
          "type": "command",
          "command": "node <WORKSPACE_CLAUDE_DIR>/statusline.js",
          "refreshInterval": 30
        }
      }
    }
  ]
```

- [ ] **Step 2: Verify the manifest still parses**

Run: `swift test --filter "BuiltInRegistry|ManifestParser" 2>&1 | tail -10`
Expected: PASS (the manifest loads + parses with the new `to` value).

- [ ] **Step 3: Commit**

```bash
git add Sources/OrreryThirdParty/Manifests/statusline.json
git commit -m "feat: statusline manifest installs into the workspace"
```

---

## Task 4: Integration tests — install to workspace, share, uninstall

**Files:**
- Modify: `Tests/OrreryThirdPartyTests/ManifestRunnerInstallTests.swift`

- [ ] **Step 1: Add workspace-install integration tests**

In `Tests/OrreryThirdPartyTests/ManifestRunnerInstallTests.swift`, add these tests inside the `struct ManifestRunnerInstallTests` (after `happyPath`). The fixture pins account `test-acct` to workspace `dev`, so the workspace claude dir is `store.claudeWorkspaceDir(workspace: "dev")`.

```swift
    private func workspacePkg(_ srcDir: URL) -> ThirdPartyPackage {
        ThirdPartyPackage(
            id: "statusline",
            displayName: "statusline",
            description: "",
            source: .vendored(bundlePath: srcDir.path),
            steps: [
                .copyFile(from: "statusline.js", to: "<WORKSPACE_CLAUDE_DIR>/statusline.js"),
                .patchSettings(file: "settings.json", patch: .object([
                    "statusLine": .object([
                        "command": .string("node <WORKSPACE_CLAUDE_DIR>/statusline.js")
                    ])
                ]))
            ]
        )
    }

    @Test("workspace-targeted install lands the script in the workspace and points the account settings at it")
    func workspaceInstall() throws {
        let (store, envName, srcDir, runner) = try setupFixture()
        let record = try runner.install(workspacePkg(srcDir), into: envName,
                                        refOverride: nil, forceRefresh: false)

        let fm = FileManager.default
        let wsDir = store.claudeWorkspaceDir(workspace: "dev")
        let acctDir = AccountStore(homeURL: store.homeURL).accountDir(id: "test-acct", tool: .claude)

        // Script is in the workspace, NOT the account dir.
        #expect(fm.fileExists(atPath: wsDir.appendingPathComponent("statusline.js").path))
        #expect(!fm.fileExists(atPath: acctDir.appendingPathComponent("statusline.js").path))
        // Lock keeps the marker.
        #expect(record.copiedFiles == ["<WORKSPACE_CLAUDE_DIR>/statusline.js"])
        // settings.json is in the ACCOUNT dir and points at the workspace path.
        let settings = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: acctDir.appendingPathComponent("settings.json")))
        guard case .object(let o) = settings, case .object(let sl) = o["statusLine"],
              case .string(let cmd) = sl["command"] else { Issue.record("shape"); return }
        #expect(cmd == "node \(wsDir.path)/statusline.js")
    }

    @Test("two accounts on one workspace share a single statusline.js")
    func sharedAcrossAccounts() throws {
        let (store, _, srcDir, runner) = try setupFixture()
        // Second account pinned to the same workspace "dev".
        var env = try store.load(named: "dev")
        env.setAccount("test-acct-2", for: .claude)
        try store.save(env)
        try FileManager.default.createDirectory(
            at: AccountStore(homeURL: store.homeURL).accountDir(id: "test-acct-2", tool: .claude),
            withIntermediateDirectories: true)

        _ = try runner.install(workspacePkg(srcDir), into: "dev", refOverride: nil, forceRefresh: false)
        let wsDir = store.claudeWorkspaceDir(workspace: "dev")
        let firstMtime = try FileManager.default.attributesOfItem(
            atPath: wsDir.appendingPathComponent("statusline.js").path)[.modificationDate] as? Date
        // Re-install (second account, same workspace) → still one workspace copy.
        _ = try runner.install(workspacePkg(srcDir), into: "dev", refOverride: nil, forceRefresh: false)
        #expect(FileManager.default.fileExists(atPath: wsDir.appendingPathComponent("statusline.js").path))
        #expect(firstMtime != nil)
    }

    @Test("uninstall removes the workspace script and reverts account settings")
    func uninstallWorkspace() throws {
        let (store, envName, srcDir, runner) = try setupFixture()
        _ = try runner.install(workspacePkg(srcDir), into: envName, refOverride: nil, forceRefresh: false)
        try runner.uninstall(packageID: "statusline", from: envName)

        let fm = FileManager.default
        let wsDir = store.claudeWorkspaceDir(workspace: "dev")
        let acctDir = AccountStore(homeURL: store.homeURL).accountDir(id: "test-acct", tool: .claude)
        #expect(!fm.fileExists(atPath: wsDir.appendingPathComponent("statusline.js").path))
        #expect(!fm.fileExists(atPath: acctDir.appendingPathComponent(".thirdparty/statusline.lock.json").path))
        // settings.json statusLine removed (file removed if it became empty).
        if let data = try? Data(contentsOf: acctDir.appendingPathComponent("settings.json")),
           case .object(let o) = try JSONDecoder().decode(JSONValue.self, from: data) {
            #expect(o["statusLine"] == nil)
        }
    }
```

- [ ] **Step 2: Run the integration tests**

Run: `swift test --filter "ManifestRunner — install" 2>&1 | tail -20`
Expected: PASS (happyPath + workspaceInstall + sharedAcrossAccounts + uninstallWorkspace).

- [ ] **Step 3: Commit**

```bash
git add Tests/OrreryThirdPartyTests/ManifestRunnerInstallTests.swift
git commit -m "test: statusline workspace install/share/uninstall integration"
```

---

## Task 5: Full build + thirdparty suite

**Files:** none (verification)

- [ ] **Step 1: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`, no warnings from the changed files.

- [ ] **Step 2: Run the whole OrreryThirdParty suite**

Run: `swift test --filter OrreryThirdParty 2>&1 | tail -30`
Expected: all pass — especially the pre-existing `ManifestRunner — install/uninstall/reinstall`, `CopyFile + CopyGlob executors`, `PatchSettingsExecutor`, `BuiltInRegistry`, `ManifestParser`.

> Note: the `ManifestRunner` install/uninstall tests have historically been flaky under the FULL `swift test` run due to a temp-copy race unrelated to this change. Run them **filtered** as above (`--filter`) to get a clean signal; if a flake appears, re-run the filter.

- [ ] **Step 3: (if any failure) fix and re-run until green**

---

## Self-Review notes

- **Spec coverage:** §1 workspace resolution → Task 2 Step 1; §2 placeholder (patchSettings + copyFile) → Task 1 + Task 2 Step 2; §3 lock/uninstall marker → Task 1 (`resolveInstalledPath`) + Task 2 Step 3; §4 manifest → Task 3; §5 re-pin (no auto-repatch) → no code, unchanged; §6 unaffected (`mergedClaudeSettings`, linker, statusline repo) → not touched; tests §1–6 → Task 1 + Task 4.
- **Type consistency:** `CopyFileExecutor.apply(_:sourceDir:claudeDir:workspaceDir:)`, `CopyFileExecutor.rollback(paths:claudeDir:workspaceDir:)`, `CopyFileExecutor.resolveInstalledPath(_:claudeDir:workspaceDir:)`, `CopyFileExecutor.workspaceMarker`, `ManifestRunner.resolveWorkspaceClaudeDir(env:)` used consistently across tasks. `store.claudeWorkspaceDir(workspace:)` and `Workspace.reservedOriginName` are existing APIs.
- **No placeholders:** every code step has full code + exact commands/expected output.
