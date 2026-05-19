# Account Pool 從 Env 拆分設計

- **Date**: 2026-05-19
- **Status**: Draft
- **Author**: Grady Zhuo

## 1. Motivation

Orrery 的初衷是讓使用者可以**切換 AI 工具的帳號**。第一版的設計把帳號塞進 env：每個 env 各自持有 Claude / Codex / Gemini 的憑證，切帳號就等於切 env。

實際使用後發現兩個問題：

1. **共用負擔**：env 同時負責「帳號隔離」「memory/sessions 隔離」「環境變數隔離」三件事。但大部分使用者只想換帳號，不需要 memory/sessions 沙箱。
2. **學習曲線**：新使用者要先理解「env == account」這個非自然對應，才能開始用 orrery 的主要功能。

本設計把 **account 從 env 拆出來**成為獨立的池子。env 概念保留，作為進階使用者的沙箱。對只想切帳號的人，env 完全隱形（只用 origin），命令面只剩 `orrery account ...`。

### 設計核心

- **Account**：每個工具獨立的憑證池，所有 env 共用
- **Env**：保留為沙箱（memory / sessions / project state / env vars），引用 accounts
- **Origin**：隱式 env，初學者唯一接觸到的 env
- **目標**：第一次使用 orrery 的人不必學 env 概念，直接 `orrery account add` 就能用

## 2. 核心抽象

### Account

```
~/.orrery/accounts/{claude,codex,gemini}/<id>/
```

- 每工具獨立一個池子（單位由設計討論確認）
- 一個 account 只包含**憑證**（OAuth token / API key / Keychain item reference）
- **不**包含 project history、settings 等狀態檔（這些隨 env）
- 可被 0..N 個 env 引用

### Env

```
~/.orrery/origin/
~/.orrery/envs/<UUID>/
```

- 結構大致同現在，但 `env.json` 新增欄位：
  ```json
  {
    "accounts": {
      "claude": "<account-id>",
      "codex": "<account-id>",
      "gemini": "<account-id>"
    }
  }
  ```
- 每個啟用的工具**必須**釘一個 account（可以同個 account 被多 env 共用）
- 仍然持有：memory、sessions、`.claude.json` 之類的 project state、env vars

### Origin（隱式 env）

- 對「只想切帳號」的使用者，這是唯一接觸到的 env
- 命令面上不顯露 env 概念，只說「換帳號」
- `orrery account use` 不指定 env 時作用在 origin

## 3. CLI 命令面

### Account 命令（旗標風格，預設 `--claude`）

```
orrery account add --name "work"              # = --claude
orrery account add --codex --name "work"
orrery account add --gemini --name "work"
orrery account remove --name "old"            # = --claude
orrery account list                            # 列出所有工具的所有帳號
orrery account list --claude                   # 只看 claude 池
orrery account show                            # 目前 env 各工具釘的帳號
orrery account use --name "work"               # 把 claude 切到 work
orrery account use --codex --name "work"       # 把 codex 切到 work
```

**規則：**

- `--claude` / `--codex` / `--gemini` 三選一，預設 `--claude`
- 同時下兩個以上 → 報錯：「`--claude`、`--codex`、`--gemini` 三選一，預設 `--claude`」
- `add` 沒帶 `--name` → 互動式 prompt 詢問名稱
- `account use` 永遠作用在當前 active env（沒切就是 origin），這是兩種使用模式的橋樑

### Env 命令（不變，語意更新）

```
orrery create <env>      # 建 env，預設繼承當前 active env 的 account pins
orrery use <env>         # 切到該 env
orrery list              # 列出所有 env + 各自釘的 accounts
orrery remove <env>      # 刪除 env（accounts pool 不受影響）
```

## 4. 啟動流程（Materialize）

Symlink 是**持久**的，並非每次啟動才建。觸發時機有三：

- 自動遷移時建立一次
- `orrery account use` 改變 pin 時更新
- `orrery run <tool>` 啟動前做一次冪等檢查（修復任何 drift）

`orrery run <tool>` 流程：

1. 讀目前 active env 的 `env.json` → 取得 `accounts.<tool>` 對應的 account id
2. 冪等 materialize（檢查既有 symlink 是否指對地方，不對就重建）：
   - **檔案型憑證**（Codex `auth.json`、Gemini `oauth_creds.json`、Linux Claude `.credentials.json`）：env 的 tool dir 內憑證檔是 **symlink** 到 account pool 的對應檔案
   - **Keychain 型**（macOS Claude OAuth）：account 存的是 Keychain item 識別資訊，launcher 在啟動前把該 item 映射到工具預期讀取的位置（tool-specific adapter）
3. 設 `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / `GEMINI_CONFIG_DIR` 指向 env 的 tool dir
4. exec 工具

### Materialize Strategy 表

| 工具 | 平台 | 憑證形式 | Materialize 方式 |
|------|------|---------|------------------|
| Claude | macOS | Keychain item | Metadata-pointer：寫入 Claude 預期的 Keychain key |
| Claude | Linux | `.credentials.json` | Symlink |
| Codex | All | `auth.json` | Symlink |
| Gemini | All | `oauth_creds.json` | Symlink |

實作上有一層 `CredentialAdapter` protocol，每個工具 × 平台組合提供自己的實作。

### macOS Keychain Materialize 細節（Metadata-pointer）

每個 Claude account 在 macOS 上存一個 orrery 專屬的 Keychain item，並在 account dir 內以 metadata JSON 記錄對應關係：

```
~/.orrery/accounts/claude/work/
  ├── metadata.json   # { "keychainItem": "Claude Code-orrery-<uuid>", "createdAt": "...", "displayName": "work" }
  └── (no credential file — token 在 Keychain 內)
```

Materialize 流程：

1. 讀 account dir 的 `metadata.json`，找出該 account 對應的 Keychain item key
2. 從該 item 讀出 token，**複寫**到 Claude 預期讀取的 Keychain key（覆蓋上一個 active account 的內容）
3. exec Claude

設計取捨：

- account rename 只改 metadata，**不**動 Keychain item naming
- 「active token」位置是 mutable 的；不擔心多進程競爭，因為 `orrery run` 是序列化的入口
- metadata.json 也是未來放 token 過期時間、user-friendly 顯示名、登入時間戳等資訊的位置

## 5. Sessions 與 Memory

**結論：維持 env-scoped，account 切換不影響。**

- **Sessions**：env-scoped（同現在）。Session 是本地 JSONL（如 Claude Code 的 `~/.claude/projects/.../<id>.jsonl`），id 是本地檔名而非後端 token，resume 時是把整段歷史以當前憑證重送，所以「換帳號繼續同一段對話」本來就 work。
- **Memory**：env-scoped 或依 `isolateMemory` 共用（同現在）。
- **Account 切換的唯一作用**：替換 API 認證用的憑證；不動 conversation 歷史、不動 memory、不動 project history。

理由：同一台電腦的使用者就是同一個人，切帳號的常見動機是「A 帳號額度用完，切到 B 繼續同一件事」。把 sessions/memory 也按 account 分流會違反這個直覺，且實作複雜度毫無回報。

## 6. 自動遷移

第一次跑新版 orrery 時自動觸發，不需使用者介入。

### 步驟

1. 偵測 `~/.orrery/` 存在但無 `accounts/` 目錄 → 進入遷移模式
2. 對每個 env（含 origin）：
   - 對每個工具，讀目前 env tool dir 內的憑證
   - **去重**：用憑證指紋（檔案 sha256 或 Keychain item identifier）判斷是否已在 accounts pool
     - 已存在 → env.json 引用已有 account id
     - 不存在 → 在 `accounts/<tool>/` 建新項目，命名規則 `<env-name>` 或衝突時 `<env-name>-<n>`
3. 重寫每個 `env.json`，加入 `accounts: { ... }` 欄位
4. 把原本 env 內的憑證檔換成 symlink 指向 pool 中對應 account 的檔（檔案型）；Keychain 型則寫入 account 的 metadata 紀錄
5. 寫 `.migration-v3` 旗標檔，避免重跑

### 備份

遷移前先把 `~/.orrery/` 整個 copy 到 `~/.orrery-backup-<timestamp>/`，遷移失敗時可手動 rollback。對齊現有 `.repo-backup/` 慣例。

### Edge Cases

- **某 env 的某工具沒登入過** → `env.json` 的 `accounts.<tool>` 為 null，`orrery run <tool>` 時提示先 `orrery account add`
- **多 env 共用同份憑證** → 自動去重，多 env 引用同一個 account（這正是新架構的價值）
- **遷移失敗** → 中止、印出錯誤、指向備份目錄

## 7. Phantom 切換更新

`/orrery:phantom` 在新模型下分成兩種子命令：

- `/orrery:phantom env <name>` — 切 env（行為同現在）
- `/orrery:phantom account --name <name>` — 同 env 內切帳號

切帳號的流程：

1. Supervisor 偵測到 trigger
2. 更新當前 env.json 的 `accounts.<tool>` 釘到新 account
3. 重啟工具（exec）
4. 重跑 materialize，帶入新憑證
5. `--resume <session_id>` 接回同一個 session

比現在切 env 輕量很多：memory 不變、sessions 不變、`.claude.json` 不變、就只是換了憑證。

## 8. 主要程式碼變更面

| 檔案 | 變更 |
|------|------|
| `Sources/OrreryCore/Models/OrreryEnvironment.swift` | 新增 `accounts` 欄位，移除直接持有憑證的概念 |
| `Sources/OrreryCore/Models/Account.swift` | 新增 model |
| `Sources/OrreryCore/Storage/AccountStore.swift` | 新增 store，負責 accounts pool CRUD |
| `Sources/OrreryCore/Storage/EnvironmentStore.swift` | 移除憑證管理，加入 `accounts` 引用解析 |
| `Sources/OrreryCore/Setup/CredentialAdapter.swift` | 新增 protocol，提供 file-based / Keychain materialize |
| `Sources/OrreryCore/Commands/AccountCommands.swift` | 新增 `account add/remove/list/show/use` 子命令 |
| `Sources/OrreryCore/Commands/RunCommand.swift` | 啟動前先 materialize |
| `Sources/OrreryCore/Setup/Migration.swift` | 新增 v2→v3 自動遷移 |
| `Sources/OrreryCore/Commands/PhantomCommand.swift` | 加入 `account` 子命令 |
| `Sources/OrreryCore/MCP/MCPServer.swift` | currentVersion bump、加入 account 相關 tool |
| `Sources/OrreryCore/Version.swift` | Bump version |
| `CHANGELOG.md` | 記錄 |

## 9. Out of Scope（不做）

- **跨工具 account profile**（「work profile = Claude work + Codex work + Gemini work」一鍵切）：保留語意空間，第一版不做
- **同時下多個 `--claude --codex`** 旗標：第一版報錯
- **Account-level memory**：使用者要不同 memory 請開新 env
- **Account 共用憑證的 server-side 額度合併**：不可能也不該做

## 10. 開放問題

- 遷移期間 phantom supervisor 是否要暫停？建議是。
- `account remove` 仍被 env 引用時的行為：擋下並列出引用方（建議），還是強制刪除並設 null？

---

## Migration Path

1. 在 main 上實作新架構，預設**不**啟用遷移
2. 加 `ORRERY_ENABLE_ACCOUNT_POOL=1` 環境變數作為 opt-in，內部測試
3. 確認穩定後預設啟用，舊版 `~/.orrery/` 自動遷移
4. CHANGELOG 中提示備份路徑

## Versioning

照 CLAUDE.md 中「Release Checklist」執行，視變更程度判斷 minor / major bump（建議 minor，例如 2.7.0 → 2.8.0）。
