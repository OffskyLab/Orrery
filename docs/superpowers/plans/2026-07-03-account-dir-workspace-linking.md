# Account 資料夾一律 link 到 pinned workspace — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** claude 啟動時,把 account 資料夾裡「除帳號私有以外的所有資料夾」搬進 pinned workspace 並改成 symlink,改用反向名單讓未來新資料夾(skills…)自動涵蓋。

**Architecture:** 新增一支 `ClaudeAccountDirectory.linkAccountDirsToWorkspace(accountDir:workspaceDir:)`,以反向名單掃描 account dir 頂層資料夾、聯集合併(workspace 優先)搬入 workspace、再 symlink。`prepareDirectory` 收斂到同一支 linker;`_prepare-claude-launch` 在寫完 `.claude.json` 後 best-effort 呼叫它。

**Tech Stack:** Swift、swift-testing(`import Testing`、`@Suite`、`@Test`、`#expect`)、`FileManager`。測試用既有的 `withIsolatedHome { }` helper。

規格來源:`docs/superpowers/specs/2026-07-03-account-dir-workspace-linking-design.md`
(spec 裡函式回傳型別本計畫細化為 `[String]` 警告字串,語意不變。)

---

## File Structure

- Modify `Sources/OrreryCore/Setup/ClaudeAccountDirectory.swift`
  - 新增 `privateSubdirs`、`linkAccountDirsToWorkspace`、私有 helper
    (`relinkSymlink`、`mergeTree`、`isRealDir`、`premergeStamp`)
  - 改寫 `prepareDirectory` 委派給 linker;移除已不再使用的
    `Error.existingDirectoryAtSymlinkPath`
- Modify `Sources/OrreryCore/Commands/PrepareClaudeLaunchCommand.swift`
  - 在 `.claude.json` merge 後呼叫 linker(best-effort、印警告)
- Modify `Tests/OrreryTests/ClaudeAccountDirectoryTests.swift`
  - 新增 linker 測試 suite;把舊的「refuses to clobber」測試改成「moves…」
- Modify `Tests/OrreryTests/PrepareClaudeLaunchCommandTests.swift`
  - 新增「launch 會 link 新資料夾」整合測試

---

## Task 1: 核心 linker `linkAccountDirsToWorkspace`

**Files:**
- Modify: `Sources/OrreryCore/Setup/ClaudeAccountDirectory.swift`
- Test: `Tests/OrreryTests/ClaudeAccountDirectoryTests.swift`

- [ ] **Step 1: 寫失敗測試(新 suite,加在檔案最後)**

```swift
@Suite("ClaudeAccountDirectory.linkAccountDirsToWorkspace")
struct ClaudeAccountDirectoryLinkTests {

    /// 建立一對隔離的 acct / ws 暫存目錄;測試結束自動清掉。
    private func makeTempPair() throws -> (acct: URL, ws: URL, base: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("linktest-\(UUID().uuidString)")
        let acct = base.appendingPathComponent("acct")
        let ws = base.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: acct, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        return (acct, ws, base)
    }

    /// 在 backups/ 底下找出這次執行產生的 premerge-* 目錄。
    private func premergeDir(in acct: URL) -> URL? {
        let backups = acct.appendingPathComponent("backups")
        let kids = (try? FileManager.default.contentsOfDirectory(
            at: backups, includingPropertiesForKeys: nil)) ?? []
        return kids.first { $0.lastPathComponent.hasPrefix("premerge-") }
    }

    @Test("moves a brand-new real dir into the workspace and symlinks it")
    func movesNewDir() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        let skills = acct.appendingPathComponent("skills")
        try fm.createDirectory(at: skills, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: skills.appendingPathComponent("foo.md"))

        let warnings = ClaudeAccountDirectory.linkAccountDirsToWorkspace(
            accountDir: acct, workspaceDir: ws)

        #expect(warnings.isEmpty)
        let dest = try fm.destinationOfSymbolicLink(
            atPath: acct.appendingPathComponent("skills").path)
        #expect(dest == ws.appendingPathComponent("skills").path)
        let moved = ws.appendingPathComponent("skills/foo.md")
        #expect(fm.fileExists(atPath: moved.path))
        #expect((try? String(contentsOf: moved, encoding: .utf8)) == "hello")
    }

    @Test("union merge keeps the workspace copy and backs up the account copy")
    func unionWorkspaceWins() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        let acctAgents = acct.appendingPathComponent("agents")
        let wsAgents = ws.appendingPathComponent("agents")
        try fm.createDirectory(at: acctAgents, withIntermediateDirectories: true)
        try fm.createDirectory(at: wsAgents, withIntermediateDirectories: true)
        try Data("acct".utf8).write(to: acctAgents.appendingPathComponent("shared.md"))
        try Data("acct-only".utf8).write(to: acctAgents.appendingPathComponent("only.md"))
        try Data("ws".utf8).write(to: wsAgents.appendingPathComponent("shared.md"))

        let warnings = ClaudeAccountDirectory.linkAccountDirsToWorkspace(
            accountDir: acct, workspaceDir: ws)
        #expect(warnings.isEmpty)

        // workspace wins on conflict
        let shared = ws.appendingPathComponent("agents/shared.md")
        #expect((try? String(contentsOf: shared, encoding: .utf8)) == "ws")
        // non-conflicting account file moved over
        let only = ws.appendingPathComponent("agents/only.md")
        #expect((try? String(contentsOf: only, encoding: .utf8)) == "acct-only")
        // account/agents is now a symlink
        let dest = try fm.destinationOfSymbolicLink(
            atPath: acct.appendingPathComponent("agents").path)
        #expect(dest == wsAgents.path)
        // the conflicting account copy is preserved in backups
        let backup = try #require(premergeDir(in: acct))
        let backedUp = backup.appendingPathComponent("agents/shared.md")
        #expect((try? String(contentsOf: backedUp, encoding: .utf8)) == "acct")
    }

    @Test("nested dirs merge recursively (both children survive)")
    func nestedMerge() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        try fm.createDirectory(
            at: acct.appendingPathComponent("plugins/foo"), withIntermediateDirectories: true)
        try Data("b".utf8).write(to: acct.appendingPathComponent("plugins/foo/bar.txt"))
        try fm.createDirectory(
            at: ws.appendingPathComponent("plugins/foo"), withIntermediateDirectories: true)
        try Data("z".utf8).write(to: ws.appendingPathComponent("plugins/foo/baz.txt"))

        _ = ClaudeAccountDirectory.linkAccountDirsToWorkspace(accountDir: acct, workspaceDir: ws)

        #expect(fm.fileExists(atPath: ws.appendingPathComponent("plugins/foo/bar.txt").path))
        #expect(fm.fileExists(atPath: ws.appendingPathComponent("plugins/foo/baz.txt").path))
        let dest = try fm.destinationOfSymbolicLink(
            atPath: acct.appendingPathComponent("plugins").path)
        #expect(dest == ws.appendingPathComponent("plugins").path)
    }

    @Test("already-correct symlink is a no-op (no backup created)")
    func correctSymlinkNoop() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        let target = ws.appendingPathComponent("projects")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: acct.appendingPathComponent("projects"), withDestinationURL: target)

        let warnings = ClaudeAccountDirectory.linkAccountDirsToWorkspace(
            accountDir: acct, workspaceDir: ws)
        #expect(warnings.isEmpty)
        let dest = try fm.destinationOfSymbolicLink(
            atPath: acct.appendingPathComponent("projects").path)
        #expect(dest == target.path)
        #expect(premergeDir(in: acct) == nil)
    }

    @Test("symlink pointing at the wrong place is repointed")
    func repointsWrongSymlink() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        let wrong = base.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: wrong, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: acct.appendingPathComponent("projects"), withDestinationURL: wrong)

        _ = ClaudeAccountDirectory.linkAccountDirsToWorkspace(accountDir: acct, workspaceDir: ws)

        let dest = try fm.destinationOfSymbolicLink(
            atPath: acct.appendingPathComponent("projects").path)
        #expect(dest == ws.appendingPathComponent("projects").path)
    }

    @Test("private dirs and dotfiles and top-level files are untouched")
    func privateAndFilesUntouched() throws {
        let (acct, ws, base) = try makeTempPair()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        try fm.createDirectory(
            at: acct.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try Data("c".utf8).write(to: acct.appendingPathComponent("cache/x"))
        try fm.createDirectory(
            at: acct.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: acct.appendingPathComponent("settings.json"))

        _ = ClaudeAccountDirectory.linkAccountDirsToWorkspace(accountDir: acct, workspaceDir: ws)

        // cache stayed a real dir with its content, not moved
        #expect(ClaudeAccountDirectory.isRealDirForTest(acct.appendingPathComponent("cache")))
        #expect(fm.fileExists(atPath: acct.appendingPathComponent("cache/x").path))
        #expect(!fm.fileExists(atPath: ws.appendingPathComponent("cache").path))
        // .hidden untouched
        #expect(ClaudeAccountDirectory.isRealDirForTest(acct.appendingPathComponent(".hidden")))
        // top-level file untouched
        #expect(fm.fileExists(atPath: acct.appendingPathComponent("settings.json").path))
        #expect(!fm.fileExists(atPath: ws.appendingPathComponent("settings.json").path))
    }
}
```

- [ ] **Step 2: 跑測試,確認編譯失敗(函式尚未存在)**

Run: `swift test --filter ClaudeAccountDirectoryLinkTests 2>&1 | tail -20`
Expected: 編譯失敗 —「type 'ClaudeAccountDirectory' has no member 'linkAccountDirsToWorkspace'」等。

- [ ] **Step 3: 在 `ClaudeAccountDirectory` 內實作 linker 與 helper**

在 `Sources/OrreryCore/Setup/ClaudeAccountDirectory.swift` 的 `sharedSubdirs`
常數後面、`prepareDirectory` 前面,插入:

```swift
    /// Top-level subdir names that stay per-account and are NEVER shared to the
    /// workspace. Everything else that is a directory is moved into the pinned
    /// workspace and replaced with a symlink.
    public static let privateSubdirs: Set<String> = ["backups", "cache"]

    /// Move every shareable top-level directory in `accountDir` into
    /// `workspaceDir` and replace it with a symlink pointing there. Shareable =
    /// a directory (or existing symlink) whose name is not dot-prefixed and not
    /// in `privateSubdirs`. Top-level files are never touched.
    ///
    /// Merge is a union with the workspace winning: files present only in the
    /// account move over; on a same-path conflict the workspace copy is kept and
    /// the account copy is moved to `backups/premerge-<timestamp>/`.
    ///
    /// Best-effort: never throws. Returns a human-readable warning per entry
    /// that could not be linked, so callers can surface them without blocking
    /// claude startup.
    @discardableResult
    public static func linkAccountDirsToWorkspace(
        accountDir: URL,
        workspaceDir: URL
    ) -> [String] {
        let fm = FileManager.default
        var warnings: [String] = []

        guard let entries = try? fm.contentsOfDirectory(
            at: accountDir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return ["could not read account dir \(accountDir.path)"]
        }

        let backupBase = accountDir
            .appendingPathComponent("backups")
            .appendingPathComponent("premerge-\(premergeStamp())")

        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") { continue }
            if privateSubdirs.contains(name) { continue }

            let vals = try? entry.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            let isSymlink = vals?.isSymbolicLink ?? false
            let isDir = vals?.isDirectory ?? false
            if !isSymlink && !isDir { continue }   // plain file → leave alone

            let target = workspaceDir.appendingPathComponent(name)
            do {
                if isSymlink {
                    try relinkSymlink(link: entry, target: target, fm: fm)
                } else {
                    try fm.createDirectory(
                        at: target, withIntermediateDirectories: true)
                    try mergeTree(
                        from: entry, into: target,
                        backupRoot: backupBase.appendingPathComponent(name),
                        fm: fm)
                    try fm.removeItem(at: entry)   // now empty
                    try fm.createSymbolicLink(
                        at: entry, withDestinationURL: target)
                }
            } catch {
                warnings.append("\(name): \(error.localizedDescription)")
            }
        }
        return warnings
    }

    /// Point `link` (an existing symlink) at `target`, creating `target` if
    /// needed. No-op when it already points there.
    private static func relinkSymlink(link: URL, target: URL, fm: FileManager) throws {
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path),
           dest == target.path {
            return
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
    }

    /// Recursively merge `from` into `into` (union, `into` wins). Children only
    /// in `from` move into `into`; when both sides have a real directory the
    /// merge recurses; any other same-path conflict moves the `from` copy under
    /// `backupRoot`, preserving relative structure.
    private static func mergeTree(
        from: URL, into: URL, backupRoot: URL, fm: FileManager
    ) throws {
        let children = (try? fm.contentsOfDirectory(
            at: from,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [])) ?? []

        for child in children {
            let name = child.lastPathComponent
            let dest = into.appendingPathComponent(name)
            let childVals = try? child.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            let childIsRealDir =
                (childVals?.isDirectory ?? false)
                && !(childVals?.isSymbolicLink ?? false)

            if !fm.fileExists(atPath: dest.path) {
                try fm.moveItem(at: child, to: dest)
            } else if childIsRealDir && isRealDir(dest, fm: fm) {
                try mergeTree(
                    from: child, into: dest,
                    backupRoot: backupRoot.appendingPathComponent(name), fm: fm)
            } else {
                let backup = backupRoot.appendingPathComponent(name)
                try fm.createDirectory(
                    at: backup.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try fm.moveItem(at: child, to: backup)
            }
        }
    }

    private static func isRealDir(_ url: URL, fm: FileManager) -> Bool {
        let v = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return (v?.isDirectory ?? false) && !(v?.isSymbolicLink ?? false)
    }

    /// Test-only accessor for the private `isRealDir` check.
    static func isRealDirForTest(_ url: URL) -> Bool {
        isRealDir(url, fm: .default)
    }

    /// Filename-safe UTC timestamp for the premerge backup dir.
    private static func premergeStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }
```

- [ ] **Step 4: 跑測試,確認通過**

Run: `swift test --filter ClaudeAccountDirectoryLinkTests 2>&1 | tail -20`
Expected: PASS(6 個測試全過)。

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Setup/ClaudeAccountDirectory.swift \
        Tests/OrreryTests/ClaudeAccountDirectoryTests.swift
git commit -m "feat: linkAccountDirsToWorkspace — deny-list move+link account dirs into workspace"
```

---

## Task 2: `prepareDirectory` 收斂到 linker

**Files:**
- Modify: `Sources/OrreryCore/Setup/ClaudeAccountDirectory.swift:42-95`
- Modify: `Tests/OrreryTests/ClaudeAccountDirectoryTests.swift`(改寫 clobber 測試)

- [ ] **Step 1: 改寫舊的 clobber 測試為 move 語意**

在 `Tests/OrreryTests/ClaudeAccountDirectoryTests.swift` 中,把整個
`@Test("refuses to clobber a real directory at a symlink path") func refusesToClobberRealDirectory()`
測試(含 body)替換成:

```swift
    @Test("moves a pre-existing real directory into the workspace and symlinks it")
    func movesPreexistingRealDirectory() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            var acct = Account(tool: .claude, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let realDir = acctDir.appendingPathComponent("projects")
            try FileManager.default.createDirectory(
                at: realDir, withIntermediateDirectories: true)
            try Data("important".utf8)
                .write(to: realDir.appendingPathComponent("user-file.txt"))

            try ClaudeAccountDirectory.prepareDirectory(
                account: acct, accountStore: acctStore, environmentStore: envStore)

            let fm = FileManager.default
            let wsDir = envStore.claudeWorkspaceDir(workspace: "origin")
            // account/projects is now a symlink into the workspace.
            let dest = try fm.destinationOfSymbolicLink(
                atPath: acctDir.appendingPathComponent("projects").path)
            #expect(dest == wsDir.appendingPathComponent("projects").path)
            // The user's file was moved into the workspace, not lost.
            let moved = wsDir.appendingPathComponent("projects/user-file.txt")
            #expect(fm.fileExists(atPath: moved.path))
            #expect((try? String(contentsOf: moved, encoding: .utf8)) == "important")
        }
    }
```

- [ ] **Step 2: 跑測試,確認新測試因舊行為(throw)而失敗**

Run: `swift test --filter movesPreexistingRealDirectory 2>&1 | tail -20`
Expected: FAIL —`prepareDirectory` 仍 throw `existingDirectoryAtSymlinkPath`,
測試在 `try prepareDirectory` 處丟例外。

- [ ] **Step 3: 改寫 `prepareDirectory` 委派給 linker**

把 `Sources/OrreryCore/Setup/ClaudeAccountDirectory.swift` 內整個
`public static func prepareDirectory(...) throws { ... }`(約 42–95 行)替換成:

```swift
    /// Create (or repair) the account dir so every shareable subdir is a symlink
    /// into the workspace from `account.workspace`. Real dirs / mislinked
    /// symlinks are moved+relinked via `linkAccountDirsToWorkspace`; the standard
    /// base set is additionally ensured for fresh accounts. Idempotent.
    public static func prepareDirectory(
        account: Account,
        accountStore: AccountStore,
        environmentStore: EnvironmentStore
    ) throws {
        guard account.tool == .claude else {
            throw Error.wrongTool(got: account.tool)
        }

        let fm = FileManager.default
        let acctDir = accountStore.accountDir(id: account.id, tool: .claude)
        let wsDir = environmentStore.claudeWorkspaceDir(workspace: account.workspace)

        try fm.createDirectory(at: acctDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: wsDir, withIntermediateDirectories: true)

        // Move/relink any shareable dir already present in the account dir.
        linkAccountDirsToWorkspace(accountDir: acctDir, workspaceDir: wsDir)

        // Ensure the standard base set exists as symlinks even on a fresh
        // account where claude hasn't created those dirs yet (nothing to move).
        for sub in sharedSubdirs {
            let target = wsDir.appendingPathComponent(sub)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let link = acctDir.appendingPathComponent(sub)
            if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                if dest != target.path {
                    try fm.removeItem(at: link)
                    try fm.createSymbolicLink(at: link, withDestinationURL: target)
                }
            } else if !fm.fileExists(atPath: link.path) {
                try fm.createSymbolicLink(at: link, withDestinationURL: target)
            }
        }
    }
```

- [ ] **Step 4: 移除已不再使用的 Error case**

先確認沒有其他引用:

Run: `grep -rn "existingDirectoryAtSymlinkPath" Sources Tests`
Expected: 只剩 `ClaudeAccountDirectory.swift` 的 enum 宣告與 errorDescription 兩處。

若如上,刪除 `Sources/OrreryCore/Setup/ClaudeAccountDirectory.swift` 內這兩段:

enum case:
```swift
        case existingDirectoryAtSymlinkPath(URL)
```
errorDescription 對應分支:
```swift
            case .existingDirectoryAtSymlinkPath(let url):
                return "Refusing to overwrite real directory at \(url.path) — move or remove its contents manually, then re-run."
```

(若 grep 顯示尚有其他引用,則保留此 case,略過本步驟。)

- [ ] **Step 5: 跑相關測試,確認全過**

Run: `swift test --filter ClaudeAccountDirectory 2>&1 | tail -25`
Expected: PASS — 既有 `prepareDirectory` / `verifySymlinks` 測試 + 新的
`movesPreexistingRealDirectory` + Task 1 的 linker 測試皆通過。

- [ ] **Step 6: Commit**

```bash
git add Sources/OrreryCore/Setup/ClaudeAccountDirectory.swift \
        Tests/OrreryTests/ClaudeAccountDirectoryTests.swift
git commit -m "refactor: prepareDirectory delegates to linkAccountDirsToWorkspace (move semantics)"
```

---

## Task 3: 接入 `_prepare-claude-launch`

**Files:**
- Modify: `Sources/OrreryCore/Commands/PrepareClaudeLaunchCommand.swift:83-89`
- Test: `Tests/OrreryTests/PrepareClaudeLaunchCommandTests.swift`

- [ ] **Step 1: 寫失敗的整合測試**

在 `Tests/OrreryTests/PrepareClaudeLaunchCommandTests.swift` 的
`struct PrepareClaudeLaunchCommandTests { ... }` 內(最後一個測試後)加入:

```swift
    @Test("launch links a new shareable account dir into the workspace")
    func linksNewShareableDir() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)
            try PinCommand.parse(["alice", "--workspace", "work"]).run()

            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let wsDir = envStore.claudeWorkspaceDir(workspace: "work")

            // Simulate claude having created a brand-new folder in the account dir.
            let skills = acctDir.appendingPathComponent("skills")
            try FileManager.default.createDirectory(
                at: skills, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: skills.appendingPathComponent("a.md"))

            var cmd = try PrepareClaudeLaunchCommand.parse(["--account-dir", acctDir.path])
            try cmd.run()

            let fm = FileManager.default
            let dest = try fm.destinationOfSymbolicLink(
                atPath: acctDir.appendingPathComponent("skills").path)
            #expect(dest == wsDir.appendingPathComponent("skills").path)
            #expect(fm.fileExists(
                atPath: wsDir.appendingPathComponent("skills/a.md").path))
        }
    }
```

- [ ] **Step 2: 跑測試,確認失敗**

Run: `swift test --filter linksNewShareableDir 2>&1 | tail -20`
Expected: FAIL —`skills` 仍是真實資料夾,不是 symlink(`destinationOfSymbolicLink` 丟錯)。

- [ ] **Step 3: 在 `PrepareClaudeLaunchCommand.run()` 尾端呼叫 linker**

在 `Sources/OrreryCore/Commands/PrepareClaudeLaunchCommand.swift` 中,
把結尾這段:

```swift
        // Merge and write out.
        let merged = ClaudeJsonMerge.merge(identity: identity, shared: shared)
        try ClaudeJsonMerge.saveJSON(
            merged,
            at: acctDirURL.appendingPathComponent(".claude.json")
        )
    }
```

替換成:

```swift
        // Merge and write out.
        let merged = ClaudeJsonMerge.merge(identity: identity, shared: shared)
        try ClaudeJsonMerge.saveJSON(
            merged,
            at: acctDirURL.appendingPathComponent(".claude.json")
        )

        // v3.1: generalize workspace linking. Move any shareable account dir
        // (skills, plugins, or anything claude adds later) into the pinned
        // workspace and symlink it, so accounts on the same workspace share it.
        // Best-effort — link failures must never block claude launch.
        let linkWarnings = ClaudeAccountDirectory.linkAccountDirsToWorkspace(
            accountDir: acctDirURL, workspaceDir: wsDir)
        for w in linkWarnings {
            FileHandle.standardError.write(
                Data("orrery: link-workspace: \(w)\n".utf8))
        }
    }
```

- [ ] **Step 4: 跑測試,確認通過**

Run: `swift test --filter linksNewShareableDir 2>&1 | tail -20`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Commands/PrepareClaudeLaunchCommand.swift \
        Tests/OrreryTests/PrepareClaudeLaunchCommandTests.swift
git commit -m "feat: _prepare-claude-launch links account dirs into workspace at launch"
```

---

## Task 4: 全套建置與測試

**Files:** 無(驗證)

- [ ] **Step 1: 完整建置**

Run: `swift build 2>&1 | tail -15`
Expected: `Build complete!`,無錯誤/警告(新程式碼不得引入警告)。

- [ ] **Step 2: 完整測試套件**

Run: `swift test 2>&1 | tail -30`
Expected: 全數通過。特別確認既有 suite 未回歸:
`PrepareClaudeLaunchCommand`、`v3.1 launch+capture round trip`、
`ClaudeAccountDirectory.prepareDirectory`、`ClaudeAccountDirectory.verifySymlinks`。

- [ ] **Step 3: (若有失敗)修正後重跑,直到全綠**

修任何回歸,重跑 `swift test`。不要略過失敗。

---

## Self-Review 註記

- **Spec 覆蓋**:反向名單(Task 1 `privateSubdirs` + 掃描)、private 清單
  含檔案/backups/cache/dot(Task 1 測試 `privateAndFilesUntouched`)、聯集
  workspace 優先 + 備份(Task 1 `unionWorkspaceWins`)、巢狀合併
  (`nestedMerge`)、接入 `_prepare-claude-launch`(Task 3)、`prepareDirectory`
  收斂(Task 2)、`verifySymlinks` 維持現狀(不動,既有測試守住)、`_link-memory`
  不受影響(未改動)。
- **型別一致**:全程 `linkAccountDirsToWorkspace(accountDir:workspaceDir:) -> [String]`;
  helper `relinkSymlink` / `mergeTree` / `isRealDir` / `premergeStamp` 私有;
  測試透過 `isRealDirForTest` 存取 `isRealDir`。
- **無 placeholder**:每個程式步驟都附完整程式碼與確切指令/預期輸出。
