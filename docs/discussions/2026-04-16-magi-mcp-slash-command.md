---
topic: "MCP 整合：新增 orrery_magi MCP tool 及 /orrery:magi slash command"
status: consensus
created: "2026-04-16"
updated: "2026-04-16"
participants:
  - Claude (Opus 4.6)
  - Codex (GPT-5.4)
  - Gemini
facilitator: Claude
rounds_completed: 1
---

# MCP 整合：新增 orrery_magi MCP tool 及 /orrery:magi slash command

## 議題定義

### 背景

Orrery 已有 MCP server（`orrery mcp-server`），透過 JSON-RPC 2.0 stdio 協議暴露 6 個 MCP tool（`orrery_delegate`、`orrery_list`、`orrery_sessions`、`orrery_current`、`orrery_memory_read`、`orrery_memory_write`）。使用者執行 `orrery mcp setup` 後，可在 Claude Code 中用 `/orrery:delegate` 等 slash command 使用這些功能。

剛完成的 `orrery magi` 指令讓多模型（Claude/Codex/Gemini）能互相討論並達成共識，但目前只能從 CLI 使用。使用者希望在 Claude Code 中也能用 `/orrery:magi` 的方式啟動多模型討論。

### 目標

1. 在 MCPServer 中新增 `orrery_magi` MCP tool
2. 在 MCPSetupCommand 中新增 `.claude/commands/orrery:magi.md` slash command
3. 確保 MCP 模式下 magi 的 UX 合理（非同步長時間運行、輸出格式等）

### 範圍

**在討論範圍內：**
- `orrery_magi` MCP tool 的 input schema（參數設計）
- slash command prompt 設計（引導使用者提供議題、選擇工具/輪數）
- MCP 模式下的輸出策略（magi 執行可能耗時數分鐘）
- 與 MCPSetupCommand 的整合

**不在討論範圍內：**
- magi 核心邏輯變更（MagiOrchestrator、MagiPromptBuilder 等）
- 前端 UI
- 新增 MCP tool 以外的 magi 存取方式

### 約束

- MCPServer 是同步 stdio 模式，`callTool` 必須在回應前完成執行
- magi 執行時間可能長達數分鐘（3 輪 × 3 個 tool = 9 次 AI 呼叫）
- MCP tool 的回傳值是純文字（stripped ANSI）
- slash command 是 markdown prompt 檔案，無法攜帶程式邏輯

### 子議題

- [x] 子議題 1：`orrery_magi` MCP tool 的 input schema 設計（哪些參數？必填/選填？）
- [x] 子議題 2：長時間執行的 UX 策略（同步等待 vs 背景執行 vs 分階段）
- [x] 子議題 3：`/orrery:magi` slash command prompt 的設計（如何引導使用者輸入？）
- [x] 子議題 4：MCPSetupCommand 的修改範圍（新增哪些檔案/設定？）

---

## 討論紀錄

### Round 1

#### Claude (Opus 4.6)

**子議題 1：Input Schema**
- **立場**：schema 與 CLI 高度對齊，`tools` 用陣列取代三個 flag，`output` 在 MCP 模式無意義（直接回傳文字）。
- **論點**：
  1. `topic` (String, required) — 對齊 `MagiCommand.swift` 的 `@Argument`
  2. `tools` (Array<String>) — MCP JSON schema 原生支援 array，比三個布林更語意化
  3. `rounds` (Integer, default 3) — 可選，與 CLI 一致
  4. `environment` (String?) — 與 `orrery_delegate` 同語意
  5. `output` 不需要 — MCP 回傳值就是報告，caller 自行存檔
- **證據**：`MCPServer.swift` 的 `orrery_delegate` inputSchema 格式；`MagiCommand.swift` 參數定義

**子議題 2：長時間執行 UX**
- **立場**：同步等待（方案 A），slash command 建議 `--rounds 1`。
- **論點**：
  1. `orrery_delegate` 已是同步等待模式，Claude Code 可承受
  2. 背景執行（B）需新增 2+ MCP tool，v1 不值得
  3. 遞迴呼叫安全：`DelegateProcessBuilder.swift:99-101` 已 strip IPC vars

**子議題 3：Slash Command Prompt**
- **立場**：instruction markdown 引導 Claude 組 CLI 呼叫，建議 `--rounds 1`。
- **論點**：參考 `orrery:delegate.md` 格式；`$ARGUMENTS` 作為議題。

**子議題 4：MCPSetupCommand 修改**
- **立場**：最小改動——MCPServer 加 tool + MCPSetupCommand 加 slash command。
- **論點**：不需改 `.mcp.json`；使用者需重跑 `orrery mcp setup`。

---

#### Codex (GPT-5.4)

**子議題 1：Input Schema**
- **立場**：CLI 語意映射，但用 MCP 友善型別。`tools` 用陣列（`minItems: 2`），`rounds` 加 schema 驗證（`min: 1, max: 3`）。
- **論點**：
  1. `tools` 陣列比三個布林更好驗證、更利擴充
  2. `rounds` 應在 schema 層就限制，不要到執行期才發現
  3. `output` 保留為可選但非主流程
- **證據**：`MagiCommand.swift` L10/L37/L45；`MagiOrchestrator.swift` L26

**子議題 2：長時間執行 UX**
- **立場**：**MCP 預設單輪（方案 C）**。A 會讓 MCP 卡住數分鐘；B 需大幅重構。
- **論點**：
  1. 現有 MCP server 完全同步阻塞，3 輪 × 3 tools = 9 次 subprocess 等待
  2. 單輪在現有架構自然成立——prompt builder 已處理 `previousRounds.isEmpty`
  3. 若未來做 B，應是顯式 run-based API，不是在 `tools/call` 裡偷偷 background
- **建議**：MCP 預設 `rounds: 1`，使用者可覆蓋

**子議題 3：Slash Command Prompt**
- **立場**：教 Claude 組正確 CLI，預設單輪、預設目前環境、預設所有可用工具。
- **論點**：
  1. 不該像 delegate 那樣每次追問 environment
  2. 應明確教使用者分號切 subtopics
  3. 應明示長耗時風險，多輪需使用者明確要求
- **建議流程**：解析 `$ARGUMENTS` → 預設 `orrery magi --rounds 1 "$TOPIC"` → 多輪需確認

**子議題 4：MCPSetupCommand 修改**
- **立場**：MCPServer 加 tool 定義 + MCPSetupCommand 加 slash command + L10n 更新成功訊息。
- **證據**：`MCPSetupCommand.swift` L26/L60；`en.json` L118

---

#### Gemini

**子議題 1：Input Schema**
- **立場**：完整對齊 CLI，`tools` 用陣列，`output` 可省略。
- **論點**：與 Claude/Codex 一致。

**子議題 2：長時間執行 UX**
- **立場**：**同步等待（方案 A）**，但 MCP 預設輪數降為 2。
- **論點**：
  1. 架構一致性——改異步需大幅重構
  2. 單輪模式（C）會破壞 magi「多輪共識推演」的核心價值
  3. 務實建議：MCP 預設 2 輪（而非 CLI 的 3）

**子議題 3：Slash Command Prompt**
- **立場**：設計為「引導式專家諮詢」，Claude 作為 Magi 議會主席。
- **論點**：Claude 收到結果後應解讀共識報告並總結。

**子議題 4：MCPSetupCommand 修改**
- **立場**：MCPServer toolDefinitions() + callTool() + MCPSetupCommand installSlashCommands() + L10n。
- **額外觀察**：遞迴呼叫技術上安全（IPC vars 已 strip），但需注意 API rate limit。

---

## 共識看板

| # | 子議題 | Claude | Codex | Gemini | 狀態 |
|---|--------|--------|-------|--------|------|
| 1 | Input schema | `{topic, tools[], rounds?, env?}` | 同左 + schema 驗證 | 同左 | agreed |
| 2 | 長時間執行 UX | 同步等待，slash cmd 建議 1 輪 | MCP 預設 1 輪 | 同步等待，預設 2 輪 | majority |
| 3 | Slash command prompt | instruction markdown + --rounds 1 | 同左 + 教分號切 subtopics | 引導式 + 解讀結果 | agreed |
| 4 | MCPSetupCommand 修改 | MCPServer + slash cmd | 同左 + L10n | 同左 + L10n | agreed |

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
| 1 | Input schema 採 `{topic (required), tools (array, optional), rounds (int, optional), environment (string, optional)}`，不含 `output` | 2026-04-16 | R1 | 三方一致 |
| 2 | v1 採同步等待，MCP 預設 `rounds: 1`（slash command 建議 1 輪，使用者可覆蓋） | 2026-04-16 | R1 | Claude+Codex 偏好 1 輪；Gemini 偏好 2 輪但不阻擋 |
| 3 | Slash command 採 instruction markdown 格式，教 Claude 組 CLI 呼叫，含分號切 subtopics 提示 | 2026-04-16 | R1 | 三方一致 |
| 4 | 改動範圍：MCPServer.swift（tool 定義 + callTool）+ MCPSetupCommand.swift（slash command 檔案）+ L10n（成功訊息） | 2026-04-16 | R1 | 三方一致 |

---

## 開放問題

1. ~~Input schema~~ → **已決定 D1**
2. ~~執行模式~~ → **已決定 D2**：同步等待 + 預設 1 輪
3. ~~Slash command 設計~~ → **已決定 D3**
4. ~~改動範圍~~ → **已決定 D4**

---

## 下次討論指引

### 進度摘要

Round 1 完成。4 個子議題全部收斂（3 個 agreed、1 個 majority）。核心分歧在 MCP 預設輪數（1 vs 2），最終採 1 輪作為預設。

### 待處理事項

- 產出實作 spec（/write-spec）
- 確認 `orrery_magi` 的 `tools` 參數在未指定時的行為（CLI 是 fallback 到 `Tool.allCases`）
- 確認 `mCPSetup.success` L10n 訊息是否需列出 `/orrery:magi`

### 閱讀建議

- `Sources/OrreryCore/MCP/MCPServer.swift` — tool 定義和 callTool 格式
- `Sources/OrreryCore/Commands/MCPSetupCommand.swift` — slash command 安裝方式
- `Sources/OrreryCore/Commands/MagiCommand.swift` — CLI 參數對照

### 注意事項

- 遞迴呼叫安全（IPC vars 已 strip），但使用者需知悉 API quota 消耗
- 背景執行 + 輪詢（方案 B）是長期正解，但 v1 不做
