# Account 資料夾一律 link 到 pinned workspace（launch 時)

日期:2026-07-03
狀態:設計待實作

## 背景

Orrery v3.1 的架構:Claude 的進入點是 **account 資料夾**
(`~/.orrery/accounts/claude/<id>/`,即 `CLAUDE_CONFIG_DIR`),而每個 account
pin/link 到一個 **workspace**(`~/.orrery/workspaces/<ws>/claude/`)。同一個
workspace 底下的多個 account 應共享工作內容(projects、agents、commands、
skills…),只有帳號私有的東西(憑證、身分、設定)各自獨立。

目前 `ClaudeAccountDirectory` 用一個**固定白名單**決定哪些子目錄 symlink 到
workspace:

```swift
public static let sharedSubdirs: [String] = [
    "projects", "memory", "agents", "commands", "todos"
]
```

問題:Claude 在發展過程中會新增資料夾(例如 `skills/`、`plugins/`)。固定白名單
不會涵蓋新資料夾,導致新資料夾停留在 account 本地、不會在同 workspace 的帳號間
共享。此外現行 `prepareDirectory` 遇到「account 已有真實資料夾」會直接拒絕
(throw),不會把既有內容搬進 workspace。

## 目標

在 **claude 啟動時**,把 account 資料夾裡「除了帳號私有以外的所有資料夾」搬進
pinned workspace 並改成 symlink。改用**反向名單(deny-list)**取代固定白名單,
讓 Claude 未來新增的資料夾自動被涵蓋,不需改 code。

## 決策(已與使用者確認)

1. **反向名單**:掃描 account dir 頂層,除了 private 清單以外的**資料夾**一律
   共用。
2. **Private 清單(留在 account,不搬)**:
   - 所有頂層**檔案**:`.claude.json`、`.credentials.json`、`settings.json`、
     `history.jsonl`、`metadata.json`、`claude-identity.json`… → 只處理資料夾,
     檔案一律不碰。
   - **資料夾**:`backups/`、`cache/`。
   - **dot 開頭(hidden)的頂層項目**:一律當 private 跳過。
   - 其餘資料夾全部共用,含 `projects`、`memory`、`agents`、`commands`、`todos`、
     `plugins`、`statsig`、`shell-snapshots`、`ide`,以及未來任何新資料夾。
3. **合併策略**:聯集,**workspace 優先**。account 有、workspace 沒有的檔案搬過去;
   同路徑衝突時保留 workspace 版本,account 的重複檔搬到備份。
4. **執行時機**:`_prepare-claude-launch`(每次啟動 claude 前,`claude()` wrapper
   已呼叫;此時 `CLAUDE_CONFIG_DIR` 一定指向正確 account)。

## 詳細設計

### 新函式:`ClaudeAccountDirectory.linkAccountDirsToWorkspace`

```
static func linkAccountDirsToWorkspace(
    accountDir: URL,
    workspaceDir: URL
) -> [LinkOutcome]   // best-effort;回傳每個項目的結果 / 錯誤,絕不 throw 中斷全部
```

Private 資料夾常數:

```swift
static let privateSubdirs: Set<String> = ["backups", "cache"]
```

演算法 — 對 `accountDir` 每個頂層項目 `E`:

1. **跳過**:`E` 是檔案、或名稱以 `.` 開頭、或名稱 ∈ `privateSubdirs`。
2. **`E` 已是 symlink**:
   - 指向 `workspaceDir/E` → OK,跳過。
   - 指向別處 → 移除並重建指向 `workspaceDir/E`(repoint);先確保 `workspaceDir/E`
     存在。
3. **`E` 是真實資料夾**:
   - 確保 `workspaceDir/E` 存在。
   - **聯集合併(workspace 優先)**,遞迴走訪 `E`:
     - 對每個相對路徑的**檔案 / symlink**:workspace 沒有 → `moveItem` 搬過去;
       workspace 已有 → 保留 workspace 版本,把 account 的複本搬到
       `accountDir/backups/premerge-<ISO8601>/E/<relpath>`(保留結構、不覆蓋)。
     - 對**子目錄**:workspace 沒有 → 整棵子樹 `moveItem` 搬過去;workspace 有 →
       遞迴進去。
   - 合併後刪掉已清空的 `accountDir/E`。
   - 建立 symlink `accountDir/E → workspaceDir/E`。

備份放在 `backups/`(private,不會外流),`premerge-<timestamp>` 以避免多次執行
互相覆蓋。

### 接入 `PrepareClaudeLaunchCommand`

在 `run()` 內:

1. **先**做既有的 `.claude.json` merge(關鍵路徑,維持不變)。
2. **再**呼叫 `linkAccountDirsToWorkspace(accountDir: acctDirURL, workspaceDir: wsDir)`。
   - best-effort:內部逐項 catch,任何項目失敗只往 stderr 印警告,**絕不 throw**,
     不影響 `.claude.json` 已寫好的結果,也不擋 claude 啟動(shell wrapper 本來就
     容忍 prepare 失敗)。

`wsDir` 已由現有程式從 `metadata.json` 的 `workspace` 欄位解析
(`envStore.claudeWorkspaceDir(workspace:)`),直接沿用。

### `prepareDirectory` 收斂到同一支 linker

現行 `prepareDirectory`(pin/use 時呼叫)仍用固定 5 項白名單,且遇真實資料夾會
throw。為了讓 pin 時與 launch 時**行為一致**,`prepareDirectory` 改為委派給
`linkAccountDirsToWorkspace`(搬移語意),移除「遇真實資料夾就拒絕」的舊行為。

這是刻意的行為變更:舊的 clobber-guard 是資料遺失保護;新語意改為「搬進 workspace
+ 衝突備份」,同樣不遺失資料,但會主動整併而非中止。

`verifySymlinks`(read-only 健康檢查)維持現狀,仍檢查已知的 `sharedSubdirs` 集合,
本次不擴大它的範圍——它只是狀態回報,repair 動作一律走 `linkAccountDirsToWorkspace`。

### 不受影響

- `_link-memory`:把 orrery 記憶 link 進 claude 的 memory 位置,層級不同,維持不變。
- 頂層檔案(憑證、設定、身分):完全不碰。

## 測試

新增 `linkAccountDirsToWorkspace` 單元測試:

1. 全新帳號(只有既有 symlink / 沒有多餘資料夾)→ 既有 symlink no-op。
2. account 有真實 `skills/`、workspace 沒有 → 整個搬移 + symlink;account/skills
   變成指向 workspace/skills 的 symlink。
3. 雙方都有 `agents/`,含重疊檔與相異檔 → 聯集;workspace 版本保留;account 重疊檔
   出現在 `backups/premerge-*/agents/`;相異檔搬進 workspace。
4. 既有正確 symlink → no-op。
5. symlink 指向錯誤 workspace → repoint。
6. private 清單(`backups/`、`cache/`)與 dot 開頭項目 → 完全不動。
7. 頂層檔案 → 完全不動。
8. 巢狀子目錄合併(account 有 `plugins/foo/bar`,workspace 有 `plugins/foo/baz`)
   → 兩者並存於 workspace。

## 未涵蓋(YAGNI)

- 不做跨 workspace 遷移工具(切 pin 走既有 `prepareDirectory` 路徑即可)。
- 不新增設定讓使用者自訂 private 清單;清單寫死在 code,新增機器本地資料夾時再改
  `privateSubdirs` 常數。
