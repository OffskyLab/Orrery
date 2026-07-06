# Share the statusline program in the workspace (per-account settings point at it)

日期:2026-07-06
狀態:設計待實作
相關記憶:`project-statusline-shared-program`

## 背景 / 目標

目前 `orrery install statusline` 把 `statusline.js` 複製到**每個 account dir**,並在該 account 的 `settings.json` 寫 `statusLine.command = node <CLAUDE_DIR>/statusline.js`。同一個 workspace 下每個帳號各存一份 `statusline.js`。

目標:把 statusline **主程式**改成裝在 **workspace**(一份共用),每個帳號的 `settings.json`(本來就 per-account)指向那份。這是「一份共用、更新一次全帳號生效」的**去重/維護**優化;**不是隔離需求**——隔離已由 `CLAUDE_CONFIG_DIR` + per-account statusline cache 處理。

使用者選定的模型:**讀取的真實依據是 `settings.json`,而它已經是 per-account,所以由帳號自己的設定宣告「用哪個 workspace 的 statusline」,與 pin 概念一致。**(不用 account-dir symlink,不動 launch linker。)

### 關鍵前提:`statusline.js` 是 account-agnostic

`statusline.js` 執行時從 `CLAUDE_CONFIG_DIR`(+ stdin)讀當前帳號資料,程式本身不含帳號狀態。因此 command 指向**任何** workspace 的那份都會正確渲染。這讓 re-pin 的「command 還指著舊 workspace」變成無害(只要那份還在),v1 因此不需要自動 re-patch。

## 範圍

全部在 **orrery repo**:`Sources/OrreryThirdParty`(ManifestRunner + copyFile/patchSettings executors + lock/uninstall)與 `Sources/OrreryThirdParty/Manifests/statusline.json`。`orrery-claude-statusline`(statusline.js 原始碼)**不變**。

## 詳細設計

### 1. ManifestRunner:解析 workspace claude dir

`ManifestRunner` 已持有 `store: EnvironmentStore`,且能從 account dir 的 `metadata.json` 讀 `workspace` 欄位。新增解析:

```
workspaceClaudeDir = store.claudeWorkspaceDir(workspace: <account.metadata.workspace>)
```

`resolveClaudeDir` 維持回傳 **account dir**(settings.json / lock 仍在 account dir);另新增 `resolveWorkspaceClaudeDir(env:)` 回傳 workspace claude dir。

### 2. `<WORKSPACE_CLAUDE_DIR>` placeholder

- **patchSettings**:placeholders 由 `["<CLAUDE_DIR>": claudeDir.path]` 增為同時含 `"<WORKSPACE_CLAUDE_DIR>": workspaceClaudeDir.path`。這樣 manifest 的 command 可寫 `node <WORKSPACE_CLAUDE_DIR>/statusline.js`,寫進的是 **account 的 settings.json**(root 不變),但值指向 workspace。
- **copyFile**:`CopyFileExecutor` 的 `to` 支援 `<WORKSPACE_CLAUDE_DIR>` 前綴——有此前綴時目標解析到 workspace claude dir;否則維持相對 account dir(現況不變)。

### 3. Lock / uninstall 追蹤 workspace 檔案

目前 lock 記錄 copied 檔案為「相對 claudeDir(account)」,uninstall 以 `claudeDir.appendingPathComponent(rel)` 刪除。workspace 檔案不在 account dir 底下,所以:

- **選定做法(單一格式,消除歧義)**:copyFile 記進 lock 的 `copiedFiles` 時,workspace 目標一律存成**帶標記的字串** `<WORKSPACE_CLAUDE_DIR>/statusline.js`(account 目標維持現況的純相對路徑,如 `statusline.js`)。
- uninstall 逐條解析:字串以 `<WORKSPACE_CLAUDE_DIR>/` 開頭 → 解析到 workspace claude dir 後刪除;否則 → 相對 account dir 刪除(現況不變)。
- lock 檔本身仍放 account dir 的 `.thirdparty/`(per-account 安裝記錄)。

### 4. statusline.json manifest

```json
"steps": [
  { "type": "copyFile", "from": "statusline.js", "to": "<WORKSPACE_CLAUDE_DIR>/statusline.js" },
  { "type": "patchSettings", "file": "settings.json",
    "patch": { "statusLine": {
      "type": "command",
      "command": "node <WORKSPACE_CLAUDE_DIR>/statusline.js",
      "refreshInterval": 30 } } }
]
```

### 5. Re-pin 行為(v1)

不自動 re-patch。帳號 re-pin 到別的 workspace 後,command 仍指舊 workspace 的 `statusline.js`,因程式 account-agnostic 而**照常正確運作**(只要舊 workspace 那份還在)。要移到新 workspace 的那份:重跑 `orrery install statusline`。README/help 註明即可。自動 re-patch 列為未來選項。

### 6. 不受影響

- `AccountMigration.mergedClaudeSettings` 仍會剝除**繼承自 workspace settings** 的 `statusLine`;帳號自己 settings.json 的 command(現在指 workspace)照樣保留。
- 隔離不變(`CLAUDE_CONFIG_DIR` + per-account cache)。
- launch linker 不動(statusline.js 不進 account dir,也非 symlink)。
- `orrery-claude-statusline` repo 不變。

## 測試

`Sources/OrreryThirdPartyTests`(既有 ManifestRunner 測試風格,使用隔離 ORRERY_HOME):

1. copyFile 目標帶 `<WORKSPACE_CLAUDE_DIR>` → 檔案落在 **workspace** claude dir,不在 account dir。
2. patchSettings 的 `<WORKSPACE_CLAUDE_DIR>` 正確解析 → account `settings.json` 的 `statusLine.command` 指向 workspace 路徑。
3. 兩個帳號 pin 同一 workspace:各自 install → 只有一份 workspace `statusline.js`,兩個帳號 settings.json 都指它。
4. uninstall → 刪除 workspace 的 `statusline.js` 並還原 account settings.json(command 移除)。
5. account 相對路徑的 copyFile(無 placeholder)行為不變(回歸保護)。
6. 解析不到 workspace(壞 pin)→ 清楚錯誤,不誤寫。

## 未涵蓋(YAGNI)

- re-pin 自動 re-patch command(v1 靠重跑 install)。
- 把 workspace-install 泛化成 manifest 層級 `scope`;只做 `<WORKSPACE_CLAUDE_DIR>` placeholder(statusline 目前唯一需求)。
- 清理既有「每帳號一份」的舊 `statusline.js`(重跑 install 後帳號 settings 指向 workspace;舊的 account-dir `statusline.js` 變孤兒,無害,可手動刪)。
