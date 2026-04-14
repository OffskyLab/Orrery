---
topic: "Orrery 自建 delegate session：自管對話歷史，讓 Codex 也能 resume + prompt"
status: consensus
created: "2026-04-14"
updated: "2026-04-14"
participants:
  - Claude (Opus 4.6)
  - Codex (GPT-5.4)
  - Gemini
facilitator: Claude
rounds_completed: 1
---

# Orrery 自建 delegate session：自管對話歷史，讓 Codex 也能 resume + prompt

## 議題定義

### 背景

我們剛完成了 `orrery delegate --resume` 功能（基於各 tool 原生 `--resume` 機制），但使用上有兩個痛點：

1. **需要先查 session ID**：使用者必須先跑 `orrery sessions` 查詢 ID 或 index，再回來下 `delegate --resume`。雖然有 `last` 快捷，但多個 session 時仍需查表。
2. **Codex resume + prompt 不可行**：Codex CLI 的 `resume` 和 `exec` 是互斥 subcommand，無法在 resume 時追加新 prompt。目前只能進入互動模式，無法 non-interactive 委派。

此外，原生 resume 的 session 由各 tool 自己管理，格式和儲存位置各異，Orrery 無法統一操作。

### 目標

為 `orrery delegate` 新增一套 Orrery 自管的 session 機制（`--session <name>`），讓使用者可以：
1. 用自訂名稱建立/接續 session（不需查 ID）
2. 三種 tool 都能以統一方式 resume + prompt（包含 Codex）
3. 此功能與原生 `--resume` 並存，不取代

### 範圍

**在範圍內：**
- `--session <name>` 的 CLI 介面設計
- session 儲存格式（對話歷史如何持久化）
- stdout 捕捉機制（捕捉 tool 回應以存入 session）
- context 注入策略（如何將歷史注入新的 prompt）
- 與現有 `--resume` 的共存關係

**不在範圍內：**
- 取代原生 `--resume` 機制
- 修改各 tool 的 session 儲存格式
- 跨 tool session 共享（一個 session 同時用 Claude 和 Codex）
- 即時同步/多使用者

### 約束

- `codex exec` 和 `gemini -p` 的 stdout 混合了 ANSI escape、progress indicator 等非對話內容
- context window 有限：Claude ~200k tokens、Codex ~128k、Gemini ~1M——長對話歷史會爆
- 現有 `DelegateProcessBuilder` 將 one-shot 的 stdout 設為 passthrough（`FileHandle.standardOutput`），需要改為 tee（同時捕捉和顯示）
- Orrery 不擁有各 tool 的對話壓縮/摘要能力——若需摘要需另外呼叫 tool 或自行實作

### 子議題

- [ ] 子議題 1：CLI 介面設計（`--session <name>` 的語義、與 `--resume` 的互斥/共存、session 生命週期管理）
- [ ] 子議題 2：session 儲存格式（jsonl？markdown？存什麼？怎麼存？路徑？）
- [ ] 子議題 3：stdout 捕捉機制（tee 實作方式、ANSI stripping、效能影響）
- [ ] 子議題 4：context 注入策略（全量注入？最近 N 輪？摘要？context window 管理？）
- [ ] 子議題 5：與現有架構的整合（`DelegateProcessBuilder` 改動、`DelegateCommand` 改動）

---

## 討論紀錄

### Round 1 — 2026-04-14

#### 🟠 Claude (Opus 4.6)

**子議題 1：CLI 介面設計**

**立場**：同意 Codex 和 Gemini——`--session <name>` 與 `--resume` 互斥。v1 要求 prompt 必填。create-or-continue 隱式語義。

補充：
1. session scope 應為 `(tool, project-key)`，與 native session 的 project-scoping 一致。
2. Codex 提出的「v1 只做 create-or-continue，list/delete 延後」合理——先穩定 write/read path。
3. Gemini 提出的 `orrery sessions --managed` 是好方向，但可等 v2。

**子議題 2：儲存格式**

**立場**：三方一致用 JSONL。

路徑問題有分歧：Codex 建議放在 `sharedSessionDir(tool:)` 下的 managed 子目錄（per-tool），Gemini 建議放在 `~/.orrery/sessions/<project-key>/` 下（tool-agnostic path）。我傾向 Gemini 的方案——因為 managed session 是 Orrery 自己的概念，不應混在 tool 的 config dir 裡。但每行 JSONL 需包含 `tool` 欄位（Gemini 已建議），這樣即使路徑 tool-agnostic，資料層仍可區分。

同意 Gemini 的欄位設計：`role`、`content`（cleaned）、`timestamp`、`tool`、`token_estimate`。

**子議題 3：stdout 捕捉**

**立場**：三方一致——Pipe + streaming tee。ANSI strip 只對持久化內容，stderr 不捕捉。

同意 Gemini 提出的 `TeeCapture` class 封裝。`readabilityHandler` 是 Foundation 的標準 async I/O pattern，適合這個場景。

**子議題 4：context 注入策略**

**立場**：三方一致——recent turns with token budget，v1 不做 summary。

同意 Gemini 提出的 60% budget 和 per-tool 預設值。XML-delimited preamble（`<session_history>`）格式清晰，三種 tool 都能理解。

token 估算用 `chars / 4` 在 v1 足夠——精確 tokenizer 是 overkill。

**子議題 5：架構整合**

**立場**：三方一致——DelegateCommand 負責 orchestration，builder 只管 process construction + optional tee wiring。

關鍵洞見（Codex 提出）：managed session path 不設定 `resumeSessionId`，而是把歷史 + 新 prompt 組合後當普通 `prompt` 傳入 builder。builder 自然走 `["codex", "exec", combinedPrompt]`，完全繞過 Codex 的 resume+prompt 限制。

新增 3 個型別：`TeeCapture`、`SessionContextBuilder`、`ManagedSessionStore`。

---

#### ⚪ Codex (GPT-5.4)

**子議題 1**：`--session` 與 `--resume` 互斥。v1 只支援有 prompt 的 non-interactive 模式。create-or-continue 隱式語義，list/delete 延後。per-tool scope。

**子議題 2**：JSONL，normalized structured messages，cleaned text。路徑放 `sharedSessionDir(tool:)` 下的 managed 子目錄。raw stdout 可作 secondary artifact 但非 replay source。

**子議題 3**：Pipe + streaming tee。ANSI strip 只對持久化。stderr 不捕捉。不用 readDataToEndOfFile（會 buffer 全部），要 streaming append。

**子議題 4**：recent N turns with hard cap，不做 summary。超出 budget 則 drop oldest。interactive managed session 等 `.injectedThenInteractive` 實作後再做。

**子議題 5**：DelegateCommand orchestration，builder 保持 process-focused。managed path 設 `resumeSessionId: nil`，把 replay prompt 當普通 prompt。`SessionSpecifier` / `SessionResolver` 不動。

---

#### 🟢 Gemini

**子議題 1**：`--session` 與 `--resume` 互斥。requires prompt。session scope 為 `(tool, cwd)`。implicit create-or-continue。需要 `orrery sessions --managed` 列表和 `--delete` 清理。

**子議題 2**：JSONL。欄位：`role`、`content`、`timestamp`、`tool`、`token_estimate`。不存 raw stdout。路徑 `~/.orrery/sessions/<project-key>/<session-name>.jsonl`（tool-agnostic）。新增 `EnvironmentStore.managedSessionFile(name:cwd:)`。

**子議題 3**：Pipe + `readabilityHandler` tee。封裝為 `TeeCapture` class。ANSI strip at storage time。stderr 不捕捉。效能影響可忽略。

**子議題 4**：recent turns fitting token budget（60% of tool context window）。預設 budget: Claude 120k、Codex 76k、Gemini 600k。XML preamble `<session_history>`。token 估算 `chars / 4`。封裝為 `SessionContextBuilder`。

**子議題 5**：additive changes。DelegateCommand + DelegateProcessBuilder 修改。新增 `TeeCapture`、`SessionContextBuilder`、`ManagedSessionStore`。`SessionSpecifier` / `SessionResolver` 不動。

---

## 共識看板

| # | 子議題 | Claude | Codex | Gemini | 狀態 |
|---|--------|--------|-------|--------|------|
| 1 | CLI 介面設計 | 互斥、prompt 必填、implicit create | 互斥、prompt 必填、implicit create | 互斥、prompt 必填、implicit create | `agreed` |
| 2 | 儲存格式 | JSONL，tool-agnostic path | JSONL，per-tool path | JSONL，tool-agnostic path | `majority` — Claude+Gemini tool-agnostic；Codex per-tool |
| 3 | stdout 捕捉 | Pipe + streaming tee + TeeCapture | Pipe + streaming tee | Pipe + streaming tee + TeeCapture | `agreed` |
| 4 | context 注入 | recent turns + token budget | recent turns + hard cap | recent turns + token budget (60%) | `agreed` |
| 5 | 架構整合 | DelegateCommand orchestration | DelegateCommand orchestration | DelegateCommand orchestration | `agreed` |

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
| 1 | `--session` 與 `--resume` 互斥，v1 要求 prompt 必填，create-or-continue 隱式語義 | 2026-04-14 | Round 1 | 三方一致 |
| 2 | 儲存格式用 JSONL，欄位含 role/content/timestamp/tool/token_estimate | 2026-04-14 | Round 1 | 三方一致 |
| 3 | stdout 用 Pipe + streaming tee 捕捉，ANSI strip 只對持久化，stderr 不捕捉 | 2026-04-14 | Round 1 | 三方一致 |
| 4 | context 注入用 recent turns + token budget（60% of tool window），v1 不做 summary | 2026-04-14 | Round 1 | 三方一致 |
| 5 | DelegateCommand 負責 managed session orchestration，builder 加 optional tee，`SessionSpecifier`/`SessionResolver` 不動 | 2026-04-14 | Round 1 | 三方一致 |
| 6 | managed session path 不設 `resumeSessionId`，將歷史+prompt 組合後當普通 prompt 傳入 builder（繞過 Codex 限制） | 2026-04-14 | Round 1 | 三方一致（Codex 提出） |
| 7 | 儲存路徑用 tool-agnostic `~/.orrery/sessions/<project-key>/<name>.jsonl` | 2026-04-14 | Round 1 | 使用者裁決，採 Claude+Gemini 方案 |
| 8 | 架構改為 Hybrid：Claude/Gemini 走 native session ID mapping（保留完整 internal state）；Codex fallback 到文字注入 | 2026-04-14 | 使用者裁決 | 取代決策 #2-#6 的「純文字注入」方向 |

---

## 開放問題

1. ~~儲存路徑~~ → **已決定**：tool-agnostic `~/.orrery/sessions/<project-key>/<name>.jsonl`（使用者裁決，Round 1 多數方案）

---

## 下次討論指引

### 進度摘要

Round 1 完成。5 個子議題中 4 個三方一致，1 個（儲存路徑）為 majority。核心架構方向已確定。

### 最終決策清單

1. `--session <name>` 與 `--resume` 互斥，v1 prompt 必填，隱式 create-or-continue
2. JSONL 格式，欄位：`role`/`content`/`timestamp`/`tool`/`token_estimate`
3. Pipe + streaming tee，`TeeCapture` 封裝，ANSI strip 只對持久化
4. recent turns + 60% token budget，per-tool 預設值，v1 不做 summary
5. DelegateCommand orchestration，builder 加 optional tee
6. managed path 不用 `resumeSessionId`，歷史+prompt 組合成普通 prompt

### 待處理事項

- 決定儲存路徑（tool-agnostic vs. per-tool）——可由使用者裁決
- 開始寫 spec（`/write-spec`）

### 閱讀建議

- `DelegateProcessBuilder.swift` — tee 改動主體
- `DelegateCommand.swift` — orchestration 改動
- `SessionsCommand.swift` — 可復用的 parse helpers 和 JSONL utilities

### 注意事項

- managed session 的 prompt 會很長（歷史 + 新 prompt），注意各 tool CLI 對 argument 長度的限制（shell ARG_MAX ~262144 bytes on macOS）
- XML preamble 格式需測試各 tool 是否正確解讀
