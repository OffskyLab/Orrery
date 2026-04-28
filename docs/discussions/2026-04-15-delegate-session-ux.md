---
topic: "delegate --session UX 改善：命名 session + 自動 mapping，消除 session ID 查詢痛點"
status: consensus
created: "2026-04-15"
updated: "2026-04-15"
participants:
  - Claude (Opus 4.6)
  - Codex (GPT-5.4)
  - Gemini
facilitator: Claude
rounds_completed: 1
---

# delegate --session UX 改善：命名 session + 自動 mapping，消除 session ID 查詢痛點

## 議題定義

### 背景

經過前面的驗證，三個 tool（Claude、Codex、Gemini）都原生支援 resume + prompt：
- Claude：`claude -p --resume <id> "prompt"`
- Codex：`codex exec resume <id> "prompt"` 或 `codex exec resume --last "prompt"`
- Gemini：`gemini --resume <id> -p "prompt"`

Codex fallback（TeeCapture、SessionContextBuilder、SessionTurn）不再需要。核心問題回到 UX：

1. **Session ID 是 UUID，看不懂記不住**——使用者看到 `f3bc5be6-4b75-4edc-807b-d68592c54e43` 不知道那是什麼對話
2. **每次都要手動查詢 session ID**——先跑 `orrery sessions`，找到 ID，再貼回 `--resume`
3. **需要重複指定 tool flag**——即使 session 本身就知道是哪個 tool 的，使用者還是得打 `--claude`
4. **AI 之間無法自主討論**——目前 `/discuss` 需要使用者手動觸發每一輪，無法讓 AI 自己跑完多輪討論

### 目標

1. **互動式 session 選擇器**：`orrery delegate --session` 彈出選擇器，列出所有 session（含名稱、tool、摘要、時間），選擇後直接輸入 prompt 繼續
2. **命名式建立**：`orrery delegate --session <name> "prompt"` 建立新的命名 session
3. **自動推斷 tool**：session 記錄了 tool 資訊，resume 時不需要再指定 `--claude`/`--codex`/`--gemini`
4. **AI 自主討論模式**：給定議題和輪數，AI 之間自動跑完多輪討論，使用者只在需要裁決時介入

### 範圍

**在範圍內：**
- 互動式 session picker 的 UX 設計
- session metadata 儲存（name → native ID + tool + 摘要）
- 自動 tool 推斷
- `--session` 無名稱時觸發 picker
- `--session <name>` 建立/接續命名 session
- AI 自主討論模式的流程設計（delegate 層面的 auto-discuss）
- 砍掉不需要的 Codex fallback 程式碼（TeeCapture、SessionContextBuilder、SessionTurn）

**不在範圍內：**
- 跨 tool session 共享（一個 session 用多個 tool）
- session 匯出/分享
- 修改各 tool 的 session 儲存格式

### 約束

- 各 tool 的 resume CLI 語法不同（已驗證，見背景）
- Codex session 是全域的（非 project-scoped），Claude 和 Gemini 是 project-scoped
- 互動式選擇器需要 TTY（非 pipe/MCP 環境）
- `DelegateProcessBuilder` 的 Codex command 組裝需要修正（`codex exec resume` 而非 `codex resume`）
- AI 自主討論需要 delegate 能以 chain 方式運作（A 的輸出成為 B 的輸入）

### 子議題

- [ ] 子議題 1：互動式 session picker 設計（觸發方式、顯示內容、選擇後的 prompt 輸入流程）
- [ ] 子議題 2：session metadata 與自動 tool 推斷（儲存什麼、怎麼推斷、與 native session discovery 的整合）
- [ ] 子議題 3：DelegateProcessBuilder command 修正（三個 tool 的正確 resume + prompt 語法）
- [ ] 子議題 4：AI 自主討論模式設計（議題輸入、自動多輪、裁決機制、輸出格式）
- [ ] 子議題 5：清理不需要的程式碼（TeeCapture、SessionContextBuilder、SessionTurn）

---

## 討論紀錄

### Round 1 — 2026-04-15

#### 🟠 Claude (Opus 4.6)

**子議題 1（picker）**：同意。`--session` 無名稱 → SingleSelect picker。TTY guard 必須，非 TTY 時 throw error。picker 列出所有 tool 的 named sessions（跨 tool 扁平化），每行顯示 `name · tool · firstMessage · time`。選取後自動推斷 tool，再輸入 prompt。

**子議題 2（metadata）**：同意擴展 `SessionMappingEntry` 加 `summary`。但同意 Gemini 的觀點——summary 可作為 cache，picker 顯示時優先用 native session 即時解析。新增 `SessionMapping.allMappings(cwd:)` 方法列出所有命名 session。tool 推斷以 mapping 為準，flag 為 fallback（僅建立新 session 時需要）。

**子議題 3（command fix）**：三方一致，這是 bug fix。Codex 的三個 case 需修正為 `codex exec resume`/`codex exec`。刪除 Codex resume+prompt guard。同意 Gemini 指出 `--allowedTools Bash` 硬編碼的問題，但建議 v1 先保留，另開 issue。

**子議題 4（auto-discuss）**：同意 Codex 的架構——orchestrator 層在 delegate 之上。但我認為 auto-discuss 和互動式 picker 是不同的功能維度，應分開實作。auto-discuss 的 stdout capture 可以用簡單的 `Pipe` + `readDataToEndOfFile()`（不需 tee，因為使用者不需即時看到），比 TeeCapture 簡單得多。output 追加到 discussion markdown。

**子議題 5（cleanup）**：三方一致。刪除 TeeCapture、SessionContextBuilder、SessionTurn + Codex fallback path。auto-discuss 如果需要 capture，到時用更簡單的 Pipe 實作。

---

#### ⚪ Codex (GPT-5.4)

**子議題 1**：SingleSelect picker for named sessions。TTY guard，非 TTY 報錯。picker rows 格式：`name · tool · summary · time`。選取後忽略 tool flags，由 metadata 決定。新 session 才需 explicit tool。

**子議題 2**：擴展 `SessionMappingEntry` 加 `summary`。discovery flow：`SessionMapping.list(cwd)` → 用 `SessionsCommand.findSessions` 補齊/刷新 metadata。auto tool inference 從 mapping，不從 `SessionResolver`。

**子議題 3**：bug fix。修正 Codex command 為 `codex exec resume <id> <prompt>`。刪除 resume+prompt guard。保留 pure resume 分支。

**子議題 4**：orchestrator 層，不塞進 delegate。round-robin + named sessions per agent。裁決用 explicit stop conditions。不綁 picker。

**子議題 5**：7 步 cleanup 順序。淨刪 ~150-170 行。managed path 收斂為單一 native mapping flow。

---

#### 🟢 Gemini

**子議題 1**：SingleSelect，跨 tool 合併列出帶 tool badge。`--session` 改為 `@Flag`（picker）+ `--session-name`（命名式），或用 optional value 區分。非 TTY throw error。

**子議題 2**：summary 作 cache，優先即時解析。新增 `allMappings(cwd:)`。tool 推斷從 mapping，flag 為 fallback + conflict check。

**子議題 3**：bug fix。修正 Codex 三個 case。刪 guard。指出 `--allowedTools Bash` 硬編碼問題。

**子議題 4**：sequential round-robin。capture stdout via Pipe（不需 tee）。output 追加到 discussion markdown。Phase 1 sequential，Phase 2 consensus detection + auto-pause。

**子議題 5**：7 步刪除清單，約 150-170 行淨刪。注意 auto-discuss 可能需要 simpler capture（但比 TeeCapture 簡單）。

---

## 共識看板

| # | 子議題 | Claude | Codex | Gemini | 狀態 |
|---|--------|--------|-------|--------|------|
| 1 | 互動式 picker | SingleSelect + TTY guard | SingleSelect + TTY guard | SingleSelect + TTY guard | `agreed` |
| 2 | metadata + auto tool | mapping 加 summary，auto infer from mapping | mapping 加 summary，auto infer from mapping | mapping 加 summary，auto infer from mapping | `agreed` |
| 3 | command fix | 修正 Codex 為 `exec resume`，刪 guard | 修正 Codex 為 `exec resume`，刪 guard | 修正 Codex 為 `exec resume`，刪 guard | `agreed` |
| 4 | AI auto-discuss | orchestrator 層，round-robin，Pipe capture | orchestrator 層，round-robin，named sessions | sequential round-robin，Pipe capture | `agreed` |
| 5 | cleanup | 刪 TeeCapture/ContextBuilder/SessionTurn | 刪 TeeCapture/ContextBuilder/SessionTurn | 刪 TeeCapture/ContextBuilder/SessionTurn | `agreed` |

---

## 決策紀錄

| # | 決定 | 達成日期 | 依據 Round | 備註 |
|---|------|---------|-----------|------|
| 1 | `--session` 無名稱 → SingleSelect picker（跨 tool 扁平化），含 TTY guard | 2026-04-15 | Round 1 | 三方一致 |
| 2 | `SessionMappingEntry` 加 `summary` 欄位，picker 優先即時解析 native session | 2026-04-15 | Round 1 | 三方一致 |
| 3 | auto tool inference 從 mapping，不需 `--claude` flag；建立新 session 時才需指定 tool | 2026-04-15 | Round 1 | 三方一致 |
| 4 | 修正 `DelegateProcessBuilder` 的 Codex command 為 `codex exec resume <id> <prompt>`，刪除 resume+prompt guard | 2026-04-15 | Round 1 | 三方一致（bug fix） |
| 5 | 刪除 TeeCapture.swift、SessionContextBuilder.swift、SessionTurn、Codex fallback path、captureStdout | 2026-04-15 | Round 1 | 三方一致 |
| 6 | AI auto-discuss 為 orchestrator 層，不塞進 DelegateCommand，sequential round-robin + Pipe capture + discussion markdown output | 2026-04-15 | Round 1 | 三方一致 |
| 7 | managed session path 收斂為單一 native mapping flow（三個 tool 走同一條路徑） | 2026-04-15 | Round 1 | 三方一致（Codex 提出） |

---

## 開放問題

1. **`--session` 的 ArgumentParser 實作方式**：Gemini 建議改為 `@Flag`（picker）+ `--session-name`（命名），Codex/Claude 傾向保留 `@Option var session: String?`（無值=picker，有值=命名）。需確認 ArgumentParser 是否支援 optional value 的 `@Option`。

（所有核心方向已達共識，此為實作細節）

---

## 下次討論指引

### 進度摘要

Round 1 完成。**5/5 子議題三方一致**。核心架構大幅簡化：三個 tool 走同一條 native mapping path，Codex fallback 完全移除，新增 interactive picker 和 auto-discuss orchestrator。

### 最終決策清單

1. `--session` 無名稱 → SingleSelect picker（跨 tool），自動推斷 tool
2. `SessionMappingEntry` 加 `summary`，新增 `allMappings(cwd:)`
3. 修正 Codex command 為 `codex exec resume`，刪 guard
4. 三個 tool 共用 native mapping path
5. 刪除 TeeCapture、SessionContextBuilder、SessionTurn、Codex fallback
6. AI auto-discuss = orchestrator + round-robin + Pipe capture + discussion markdown

### 建議實作順序

1. command fix（bug fix，最緊急）
2. cleanup（刪除 fallback code）
3. 統一 native mapping path
4. picker + auto tool inference
5. auto-discuss orchestrator（最大，可獨立 PR）

### 注意事項

- auto-discuss 需要 stdout capture（但用 simple Pipe，不用 TeeCapture）
- `--allowedTools Bash` 硬編碼問題暫不處理
