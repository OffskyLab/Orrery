---
topic: "Delegate Session 功能設計"
status: consensus
created: "2026-04-13"
updated: "2026-04-13"
participants:
  - Claude (Opus 4.6)
  - Codex (GPT-5.4)
  - Gemini
facilitator: Claude
rounds_completed: 3
---

# Delegate Session 功能設計

## 議題定義

### 背景

`orrery delegate` 目前以 one-shot 模式運作（`claude -p`、`codex exec`、`gemini -p`），每次呼叫都是全新對話。使用者的主要場景是 AI 間互相討論或請其他 AI 實作功能，但每次都需要重新提供完整上下文，效率很低。

Orrery 已有 `sessions` 和 `resume` 命令可列出/恢復各 tool 的歷史 session，但 `delegate` 命令本身不具備 session 感知能力——無法建立可命名的 session，也無法在後續 delegate 呼叫中 resume 既有 session。

### 目標

為 `orrery delegate` 加入 session resume 能力，讓使用者可以：
1. 在 delegate 時指定 resume 某個既有 session（而非每次都從零開始）
2. 三種 tool（Claude、Codex、Gemini）都支援

### 範圍

**在範圍內：**
- `delegate` 命令的 `--resume` 選項設計
- 三種 tool 的 resume 指令差異處理
- session 與 environment 的交互（跨環境 session 可見性）

**不在範圍內：**
- 全新的 session 命名/標籤系統（可延後）
- session 匯出/分享功能
- 修改底層 tool 的 session 儲存格式

### 約束

- 各 tool 的 resume CLI 格式不同：Claude `--resume <id>`、Codex `resume <id>`（subcommand）、Gemini `--resume <id>`
- Codex session 是全域的（非 project-scoped），Claude 和 Gemini 是 project-scoped
- 現有 `orrery resume` 命令已實作 session-by-index 的 resume 邏輯，可復用
- delegate 目前使用 `-p` flag 做 non-interactive 模式，resume 時需考慮是否仍傳入 prompt

### 子議題

- [ ] 子議題 1：`delegate --resume` 的 CLI 介面設計（如何指定 session？by index? by id? 自動選最近？）
- [ ] 子議題 2：resume + prompt 的語義（resume 時能否追加新 prompt？各 tool 是否支援？）
- [ ] 子議題 3：session 跨環境可見性（delegate 在不同 environment 下能否看到/resume 其他環境的 session？優缺點？）
- [ ] 子議題 4：與現有 `orrery resume` 的關係（是否合併？共用邏輯？還是獨立路徑？）

---

## 討論紀錄

### Round 1 — 2026-04-13

#### 🟠 Claude (Opus 4.6)

**子議題 1：CLI 介面設計**

**立場**：支持 `--resume` 接受 index、ID、或 `last` 關鍵字，但 index 應為主路徑。

**論點**：

1. 使用者的核心場景是「我剛才 delegate 了一個任務，現在想接著做」。這個場景下 `--resume last` 或 `--resume 1` 是最自然的操作，不需要去查 session ID。
2. 但 Codex 認為 auto-select most recent 風險高（因 Codex session 是 global 的），這點合理。不過 `delegate` 已經有 `--claude`/`--codex`/`--gemini` tool flag，session 列表是 per-tool 的，所以 `last` 的歧義比 `orrery resume` 小得多——它只在指定 tool 的 sessions 中選最近的。
3. 同意 Gemini 提出的「純數字視為 index、否則視為 ID」的解析規則，簡潔且向後相容。
4. 不需要 `--resume-id` 和 `--resume-index` 兩個 flag（Codex 建議），一個 `--resume` 足夠，用值的格式自動判斷。

**證據**：`ResumeCommand.swift:29-46` 已有 index-based 解析；`SessionsCommand.swift:74-80` 的 `findSessions` 已 per-tool 過濾。

**子議題 2：resume + prompt 語義**

**立場**：resume 時 prompt 應為 optional。有 prompt = 追加新指令（non-interactive）；無 prompt = 進入互動模式。

**論點**：

1. 同意 Gemini 的分析——`prompt` 目前是 `@Argument`（必填），需改為 optional。
2. Codex 的 `resume + prompt` 不相容問題是真實限制。但不應因此讓 Codex 拖累其他 tool 的 UX。建議：Codex + resume + prompt 時，先 resume 進入互動模式，再透過 stdin pipe 注入 prompt。若不可行，才報錯。
3. 同意 Codex 的觀點：`delegate --resume` 不帶 prompt 時，語義退化為 `orrery resume`，但差異在於 delegate 會套用 `--environment` 的環境變數。這是有價值的，因為 `orrery resume` 目前只用 `ORRERY_ACTIVE_ENV`，不支援顯式 `-e`。

**證據**：`DelegateCommand.swift:24` prompt 為 `@Argument`；`DelegateCommand.swift:65-69` 三種 tool 的 command 組裝；`ResumeCommand.swift:58` 只讀 `ORRERY_ACTIVE_ENV`。

**子議題 3：跨環境可見性**

**立場**：同意 Codex 和 Gemini——預設只看當前 environment + shared，不跨環境。

**論點**：

1. 三方一致。環境隔離是 Orrery 的核心設計。
2. 補充：`SessionEntry` 確實缺少 environment 來源資訊（Codex 指出），但這不影響 Phase 1 實作。Phase 1 只需限制搜尋範圍到當前 env + shared 即可，`SessionEntry` 的擴展可以延後。
3. 若使用者想跨環境，正確做法是 `orrery delegate -e <other-env> --resume last`，讓 `-e` 參數同時決定搜尋範圍和執行環境。

**子議題 4：與 `orrery resume` 的關係**

**立場**：CLI 分開、底層邏輯共用。同意 Codex 和 Gemini。

**論點**：

1. 三方一致方向。
2. Gemini 提出的 `SessionResolver.resolve(specifier:tool:cwd:store:)` 是正確的抽象層級。
3. Gemini 提出的 `Tool.buildCommand(prompt:resumeSessionId:)` 也很好，但我傾向放在獨立的 builder 而非 `Tool` enum 上，因為 command 組裝涉及 environment 變數，不純粹是 Tool 的責任。

---

#### ⚪ Codex (GPT-5.4)

**子議題 1：CLI 介面設計**

**立場**：反對自動選最近一個。主路徑應以明確 selector 為核心——優先 session ID，可提供 index 作為便利語法。建議用 `--resume-id` 和 `--resume-index` 兩個獨立 flag。

**論點**：

1. `ResumeCommand` 的 index 不是穩定識別，會隨時間漂移（`ResumeCommand.swift:29-47`）。
2. Codex session 是 global 的，「最近一個」很可能不是使用者想要的（`SessionsCommand.swift:126-146`）。
3. `SessionEntry` 無 environment/source 欄位，index 只適合暫時捷徑（`SessionsCommand.swift:67-72`）。

**建議**：用 `--resume-id <id>` 為主、`--resume-index <n>` 為輔。不做 auto-select，若需要則用顯式 `--latest` flag。

**子議題 2：resume + prompt 語義**

**立場**：`delegate --resume` 語義為「在既有 session 上追加新 prompt」，prompt 必填。純恢復應歸 `orrery resume`。

**論點**：

1. `DelegateCommand` 的核心是 one-shot prompt delegation，必填 prompt 是自然語義（`DelegateCommand.swift:23-24`）。
2. 三個工具的 resume+prompt 支援尚不確定（`ResumeCommand.swift:20-21, 49-55`）。
3. 建議做 tool adapter `buildResumeCommand(sessionID:prompt:interactive:)`。

**子議題 3：跨環境可見性**

**立場**：預設不跨環境。加入 scope 概念：`currentEnvironment`、`sharedOnly`、`allEnvironments`。

**論點**：

1. session discovery 和 resume execution 的 scope 不一致——`SessionsCommand` 掃所有 env，但 `ResumeCommand` 只用 active env（`SessionsCommand.swift:84-105`；`ResumeCommand.swift:58-65`）。
2. `SessionEntry` 缺少 environment 來源，dedup 只看 id（`SessionsCommand.swift:270-274`）。
3. 跨 env resume 可能用錯 credentials（`Tool.swift:8-13`；`DelegateCommand.swift:35-43`）。

**建議**：`SessionEntry` 加 `environmentName`、`storageScope` 欄位。`delegate --resume` 預設 `currentEnvironment + shared`。

**子議題 4：與 `orrery resume` 的關係**

**立場**：CLI 分開、實作共享。抽出 `SessionSelector`、`SessionScope`、`ResolvedSession`、`ToolCommandBuilder`。

**論點**：

1. 兩命令語義不同（non-interactive vs. interactive），但啟動流程重複（`DelegateCommand.swift:28-83`；`ResumeCommand.swift:25-79`）。
2. `SessionsCommand.findSessions` 已是共享 primitive（`SessionsCommand.swift:74-80`）。

---

#### 🟢 Gemini

**子議題 1：CLI 介面設計**

**立場**：支持 `--resume <index|id|last>` 作為單一入口。index 為主路徑（已建立的慣例），ID 為進階用法，`last` 為快捷方式。

**論點**：

1. `ResumeCommand` 已以 1-based index 作為介面，使用者已習慣（`ResumeCommand.swift:29-31`）。
2. Raw session ID 對腳本自動化有價值，可透過偵測數字 vs. 非數字區分（`SessionsCommand.swift:52`）。
3. `last` 是最高頻場景——使用者多半想繼續最近一次對話。

**建議**：新增 `@Option var resume: String?`，解析邏輯：`last` → index=1、純數字 → index、否則 → raw ID。

**子議題 2：resume + prompt 語義**

**立場**：prompt 改為 optional。resume + prompt = 追加新 user message。需處理 Codex 不相容。

**論點**：

1. `prompt` 目前是必填 `@Argument`（`DelegateCommand.swift:24`），需改 optional。
2. Claude/Gemini 支援 `--resume <id> -p <prompt>`；Codex 的 `resume` 和 `exec` 是不同 subcommand，無法同時使用。
3. Codex + resume + prompt 應報錯，不應靜默丟棄。

**建議**：分三種情境處理：有 resume + 有 prompt、有 resume + 無 prompt、無 resume + 有 prompt。

**子議題 3：跨環境可見性**

**立場**：預設不跨環境。使用者應先切換環境再 resume。

**論點**：

1. 環境隔離是核心設計（`DelegateCommand.swift:36-44`）。
2. Session 路徑已 environment-scoped（`SessionsCommand.swift:84-105`）。
3. Shared session 本來就跨環境可見，無需改動。

**子議題 4：與 `orrery resume` 的關係**

**立場**：Command 獨立、邏輯共用。抽出 `SessionResolver.resolve(specifier:tool:cwd:store:)` 和 `Tool.buildCommand(prompt:resumeSessionId:)`。

**論點**：

1. 執行模式根本不同——互動 vs. one-shot（`ResumeCommand.swift:49-54`；`DelegateCommand.swift:65-69`）。
2. `SessionsCommand.findSessions` 已是共用入口（`SessionsCommand.swift:74-80`）。

**建議實作順序**：Phase 1 prompt optional + `--resume`、Phase 2 抽 `SessionResolver`、Phase 3 抽 `Tool.buildCommand`、Phase 4 處理 Codex edge case。

---

### Round 2 — 2026-04-13（聚焦開放問題）

#### 🟠 Claude (Opus 4.6)

**Q1：單一 flag vs. 雙 flag**

**立場**：維持單一 `--resume`。Codex 已改變立場，三方一致。

補充：同意 Codex 提出的 `SessionSpecifier.parse(_:)` 共用解析器，讓 `orrery resume` 未來也能收斂到同一套規則。

**Q2：prompt optional vs. required**

**立場**：維持 optional。Codex 已改變立場，三方一致。

同意 Codex 的 refinement：optionality 是有條件的——只有 `--resume` 存在時 prompt 才可省略。驗證規則：`guard resume != nil || prompt != nil`。

**Q3：Codex resume + prompt 不相容**

**立場**：傾向 Codex 的「直接報錯」而非 Gemini 的「stdin pipe」。

理由：
1. stdin pipe 看似優雅，但 Gemini 自己也承認需要 fallback 到 error。如果要走兩條路（先嘗試 pipe → 失敗再 error），增加了不確定性和除錯難度。
2. `DelegateCommand` 目前把 stdin 設為 `FileHandle.standardInput`（非 nullDevice），所以互動式 resume 本身沒問題。但 **programmatic stdin injection**（寫入 prompt 再保持 pipe open）涉及 timing、encoding、Codex 是否會在收到第一個 newline 就開始處理等未知行為。
3. 先做最安全的（報錯），未來如果 Codex CLI 原生支援 `resume --exec` 或類似功能再升級。YAGNI。

**建議**：Codex + resume + prompt → `ValidationError("Codex does not support resume + prompt. Use --resume without prompt for interactive mode, or remove --resume for one-shot mode.")`。

**Q4：共用 builder 位置**

**立場**：同意獨立 builder。Gemini 已改變立場，三方一致。

同意 Codex 提出的兩層架構：
- `SessionResolver`：`specifier → SessionEntry`
- `ToolCommandBuilder`（或 Gemini 的 `DelegateProcessBuilder`）：`(tool, prompt?, sessionId?, env) → (Process, stdinPayload?)`

放在 `Sources/OrreryCore/Helpers/` 下。`Tool` enum 維持純 metadata。

---

#### ⚪ Codex (GPT-5.4)

**Q1：單一 flag vs. 雙 flag**

**立場**：**已改變**，改支持單一 `--resume <index|id|last>`。

理由：`delegate` 已有 per-tool flags 限縮 scope，`SessionsCommand.findSessions(tool:)` 本來就 per-tool。`last` 是顯式值非隱式 auto-select。解析規則確定性高（`last` → keyword、純數字 → index、否則 → ID）。

**建議**：抽 `SessionSpecifier.parse(_:)` 共用解析器。

**Q2：prompt optional vs. required**

**立場**：**已改變**，改支持有條件 optional。

理由：`DelegateCommand` 有 `-e` 而 `ResumeCommand` 只讀 `ORRERY_ACTIVE_ENV`，「不帶 prompt 但指定 environment 的 resume」是有效需求。非 resume 呼叫仍維持 prompt 必填。

**Q3：Codex resume + prompt 不相容**

**立場**：維持直接報錯（`ValidationError`）。

理由：無法從程式碼證明 Codex CLI 支援 stdin prompt injection。`DelegateCommand` 的 stdin 設定不應為此特殊 case 改變執行模型。

**Q4：共用 builder 位置**

**立場**：維持獨立 builder（非 `Tool` enum）。

理由：`Tool.swift` 只承載靜態 metadata，command building 涉及 env store、API key 處理、stdin 模式，超出 `Tool` 責任。建議抽 `SessionResolver` + `ToolCommandBuilder` 兩層。

---

#### 🟢 Gemini

**Q1：單一 flag vs. 雙 flag**

**立場**：維持單一 `--resume`。

補充：session ID 是 UUID 或 `rollout-` 前綴 hash，永遠不會是純整數，解析零歧義。

**Q2：prompt optional vs. required**

**立場**：維持 optional，細化為有條件驗證（`guard resume != nil || prompt != nil`）。

**Q3：Codex resume + prompt 不相容**

**立場**：**改為** stdin pipe 嘗試 + error fallback。

理由：resume 模式下 stdin 需改為 live，此時 pipe injection 是自然延伸。若 pipe 不可靠，fallback 到 `ValidationError`。嚴格優於只有 error。

**Q4：共用 builder 位置**

**立場**：**已改變**，同意獨立 `DelegateProcessBuilder`。

理由：command building 涉及 env variable 處理，超出 `Tool` enum 的靜態 metadata 責任。建議放 `Sources/OrreryCore/Helpers/DelegateProcessBuilder.swift`。

---

### Round 3 — 2026-04-13（聚焦 Codex resume+prompt）

#### 🟠 Claude (Opus 4.6)

**立場**：維持 Phase 1 報錯。同意 Codex 提出的 `StdinMode` enum 架構。

理由：
1. Codex 指出 Gemini 的前提有誤——目前 `DelegateCommand` 的 stdin 是 `nullDevice`（非 `standardInput`），resume 路徑的 live stdin 是未來才會加的行為。stdin pipe injection 不是「自然延伸」，而是 stdin multiplexing，本質上是不同的執行模型。
2. 同意 Codex 提出的 `StdinMode` enum 設計：`.nullDevice`（one-shot）、`.interactive`（resume 無 prompt）、`.injectedThenInteractive`（未來 Phase 2）。Phase 1 實作前兩者，第三個 case 存在於型別系統中但 throw error。
3. 這個架構讓 Gemini 的方案在未來仍可實現，不會被 foreclose。

#### ⚪ Codex (GPT-5.4)

**立場**：維持 Phase 1 報錯。提出 `StdinMode` enum 作為架構妥協。

關鍵論證：
1. Gemini 的 stdin 論點基於錯誤前提——`DelegateCommand.swift` 使用 `nullDevice`，不是 live stdin。
2. stdin pipe injection 需要 `Pipe()` → write prompt → splice real stdin，這是 stdin multiplexing，不是 passthrough。
3. 「try pipe + fallback error」無法在 runtime 偵測是否成功，只能在開發時二選一。
4. 提出 `StdinMode` enum，讓 `.injectedThenInteractive` case 存在於型別中，Phase 2 可無痛實作。

#### 🟢 Gemini

**立場**：**已改變**，接受 Phase 1 報錯。

理由：
1. 承認 stdin pipe 前提有誤——interactive stdin 和 programmatic stdin injection 是根本不同的使用模式。
2. 「try pipe + fallback error」確實是兩條程式碼路徑、兩倍測試負擔，對不確定的收益來說成本過高。
3. 接受分階段方案：Phase 1 = `ValidationError`，Phase 2 = 若 Codex CLI 支援或 stdin pipe 驗證可行再升級。`DelegateProcessBuilder` 的 `stdinPayload: String?` 已預留擴展點。

---

## 共識看板

| # | 子議題 | Claude | Codex | Gemini | 狀態 |
|---|--------|--------|-------|--------|------|
| 1 | CLI 介面設計 | 單一 `--resume` | 單一 `--resume`（R2 改變） | 單一 `--resume` | `agreed` |
| 2 | resume + prompt 語義 | 有條件 optional | 有條件 optional（R2 改變） | 有條件 optional | `agreed` |
| 3 | 跨環境可見性 | 預設當前 env + shared | 預設當前 env + shared | 預設當前 env + shared | `agreed` |
| 4 | 與 orrery resume 關係 | CLI 分開、底層共用 | CLI 分開、底層共用 | CLI 分開、底層共用 | `agreed` |
| 5 | Codex resume+prompt | Phase 1 報錯 | Phase 1 報錯 | Phase 1 報錯（R3 改變） | `agreed` |
| 6 | 共用 builder 位置 | 獨立 builder | 獨立 builder | 獨立 builder（R2 改變） | `agreed` |

**狀態說明**：
- `agreed` — 三方達成共識
- `majority` — 兩方同意，一方保留意見
- `disputed` — 有根本分歧
- `pending` — 尚未充分討論
- `deferred` — 延後到後續議題

---

## 決策紀錄

| # | 決定 | 達成日期 | 依據 Round | 備註 |
|---|------|---------|-----------|------|
| 1 | session 預設只看當前 env + shared，不跨環境 | 2026-04-13 | Round 1 | 三方一致 |
| 2 | CLI 保持 `delegate` 與 `resume` 獨立，底層邏輯共用 | 2026-04-13 | Round 1 | 三方一致，抽 SessionResolver |
| 3 | 使用單一 `--resume <index\|id\|last>` flag | 2026-04-13 | Round 2 | Codex R2 改變立場，三方一致 |
| 4 | prompt 有條件 optional（有 `--resume` 時可省略） | 2026-04-13 | Round 2 | Codex R2 改變立場，三方一致 |
| 5 | 共用 builder 放獨立 `DelegateProcessBuilder`，不放 `Tool` enum | 2026-04-13 | Round 2 | Gemini R2 改變立場，三方一致 |
| 6 | Codex resume+prompt Phase 1 報錯，用 `StdinMode` enum 預留擴展 | 2026-04-13 | Round 3 | Gemini R3 改變立場，三方一致 |

---

## 開放問題

1. ~~單一 vs. 雙 flag~~ → **已決定**：單一 `--resume`（Round 2 三方一致）
2. ~~prompt 必填 vs. optional~~ → **已決定**：有條件 optional（Round 2 三方一致）
3. ~~Codex resume + prompt~~ → **已決定**：Phase 1 報錯 + `StdinMode` enum 預留擴展（Round 3 三方一致）
4. ~~共用 builder 位置~~ → **已決定**：獨立 `DelegateProcessBuilder`（Round 2 三方一致）

（所有開放問題已解決）

---

## 下次討論指引

### 進度摘要

Round 3 完成。**所有 6 個子議題達成三方共識。討論結束，可進入實作。**

### 最終決策清單

1. **單一 `--resume <index|id|last>` flag**，抽 `SessionSpecifier` 共用解析器
2. **`prompt` 有條件 optional**（`guard resume != nil || prompt != nil`）
3. **session 預設只看當前 env + shared**，不跨環境
4. **CLI `delegate` 與 `resume` 獨立**，底層共用 `SessionResolver` + `DelegateProcessBuilder`
5. **共用 builder 放 `Sources/OrreryCore/Helpers/`**，`Tool` enum 維持純 metadata
6. **Codex resume+prompt = Phase 1 報錯**，用 `StdinMode` enum 預留 Phase 2 擴展

### 建議實作順序

1. 新建 `SessionSpecifier` enum（解析 `last`/index/id）
2. 新建 `SessionResolver`（specifier → SessionEntry）
3. 新建 `DelegateProcessBuilder` + `StdinMode` enum
4. 修改 `DelegateCommand`：加 `--resume` option、prompt 改 optional、使用新 builder
5. 重構 `ResumeCommand` 使用共用 `SessionResolver` + builder
6. 測試 `claude --resume <id> -p <prompt>` 和 `gemini --resume <id> -p <prompt>` 實際行為

### 注意事項

- Codex CLI 的 `resume` 是 subcommand，與 `exec` 互斥——硬限制
- Claude/Gemini 的 `--resume + -p` 行為仍需實際測試驗證
- `StdinMode.injectedThenInteractive` 在 Phase 1 throw error，保留 Phase 2 升級空間
