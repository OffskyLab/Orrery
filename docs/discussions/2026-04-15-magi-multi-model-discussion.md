---
topic: "Magi 技能：多模型互相對話討論並達成共識"
status: consensus
created: "2026-04-15"
updated: "2026-04-15"
participants:
  - Claude (Opus 4.6)
  - Codex (GPT-5.4)
  - Gemini
facilitator: Claude
rounds_completed: 2
---

# Magi 技能：多模型互相對話討論並達成共識

## 議題定義

### 背景

Orrery 已有 `delegate` 指令可將任務委派給 Claude、Codex、Gemini 三個 AI 工具，並支援 session 管理（`--resume`、`--session-name`、picker）。但目前的架構是「單向委派」——使用者對單一模型下達指令。

使用者提出一個構想：讓已登入的多個模型能像真實人類一樣互相對話、討論，並在討論結束後產出最終共識。這類似於《新世紀福音戰士》中的 MAGI 系統——三台超級電腦各自獨立判斷後達成多數決。

### 目標

設計並實作一個 `magi` 技能（CLI 指令或 MCP tool），使用者提出一個議題後：
1. 多個已登入的模型各自表達觀點
2. 模型之間可以互相回應、反駁
3. 經過多輪討論後產出結構化的共識報告
4. 共識結果可被後續工作流程（如 spec 撰寫、實作）直接引用

### 範圍

**在討論範圍內：**
- magi 的架構設計（如何編排多模型對話）
- CLI 介面設計（`orrery magi` 的 UX）
- session/輪次管理
- 共識判定與輸出格式
- 與現有 orrery 架構（delegate、session mapping、environment）的整合方式

**不在討論範圍內：**
- 前端 UI（僅 CLI）
- 模型微調或自訂 prompt 系統
- 計費/token 預算控制（可提但不深入）

### 約束

- 必須基於 orrery 現有架構（EnvironmentStore、Tool、SessionMapping）
- 三個模型（Claude、Codex、Gemini）的 CLI 介面差異需處理
- 輸出必須是可持久化的 markdown 討論紀錄
- 需考慮模型不可用（未登入）時的 graceful degradation

### 子議題

- [ ] 子議題 1：架構模式——Orchestrator 主導 vs. P2P 輪詢 vs. 中介者模式？
- [ ] 子議題 2：CLI 介面設計——`orrery magi <topic>` 的 UX 與選項
- [ ] 子議題 3：多輪對話管理——如何傳遞上下文、控制輪數、判定收斂
- [ ] 子議題 4：共識判定機制——如何結構化判定「同意/分歧/待定」
- [ ] 子議題 5：與 orrery 現有架構整合——reuse delegate/session/environment 的程度

---

## 討論紀錄

### Round 1

#### Claude (Opus 4.6)

**子議題 1：架構模式**
- **立場**：Orchestrator 主導模式，由 orrery 本身擔任編排者。
- **論點**：
  1. `DelegateProcessBuilder`（`Helpers/DelegateProcessBuilder.swift`）是「啟動子進程 → 等待結束 → 取得結果」的同步模型。P2P 模式需要模型之間直接通信，但三個 CLI 工具沒有互相發現或通信的能力。
  2. 中介者模式和 orchestrator 本質相似，但 orchestrator 更明確——orrery 本身就是 orchestrator，它已經知道哪些 tool 可用（`Tool.allCases`，`Tool.swift:3`）。
  3. 上下文傳遞的自然方式是：orchestrator 收集前一輪所有 agent 的輸出，組合成下一輪的 prompt。這與 `DelegateProcessBuilder` 的 `-p` prompt 注入機制吻合。

**子議題 2：CLI 介面設計**
- **立場**：`orrery magi "<topic>"` 作為主要介面。
- **論點**：
  1. 命名 `magi` 直覺且有辨識度（NERV MAGI 三賢人系統）。
  2. 選項建議：`--rounds <N>`（預設 3）、`--tools claude,codex,gemini`、`--output <path>`、`-e <env>`。
  3. 不建議做成 subcommand 群組（如 `orrery magi start/continue/status`），`magi` 應該是「一次性跑完」的指令。

**子議題 3：多輪對話管理**
- **立場**：累積 markdown prompt + 結構化 JSON 中間狀態。
- **論點**：
  1. 每輪的 prompt 應包含：議題定義 + 前輪所有 agent 的回應。跨 agent 上下文不適合用單一 agent 的 session resume。
  2. 收斂判定：每輪結束後 orchestrator 解析各 agent 的立場，如果所有子議題都達成 agreed 或 majority，則提前結束。
  3. Token 預算考量：累積 prompt 會越來越長，建議設 `--max-context <tokens>` 並在超出時做摘要壓縮。

**子議題 4：共識判定機制**
- **立場**：結構化 JSON 輸出 + orchestrator 比對。
- **論點**：
  1. 每個 agent 的 prompt 應要求輸出結構化的立場聲明：`{subtopic, position: agree|disagree|conditional, reasoning}`。
  2. Orchestrator 比對三方立場：三方 agree → `agreed`；兩方 agree → `majority`；各說各話 → `disputed`。
  3. 比自然語言解析更可靠，可用 `<output_format>` 標籤強制格式。

**子議題 5：與現有架構整合**
- **立場**：高度複用 DelegateProcessBuilder + EnvironmentStore，但不複用 SessionMapping。
- **論點**：
  1. `DelegateProcessBuilder` 已處理環境變數注入、tool-specific command array、process 生命週期——magi 每一輪對每個 agent 的呼叫就是一次 delegate call。
  2. `EnvironmentStore` 可直接複用。
  3. **不該複用** `SessionMapping`——magi 的 session 概念不同於 delegate 的 named session。討論紀錄用 markdown 檔案即可。
  4. 需新建 `MagiCommand.swift` 和 `MagiOrchestrator.swift`。

---

#### Codex (GPT-5.4)

**子議題 1：架構模式**
- **立場**：Orchestrator-driven 的 Mediator pattern，`orrery magi` 本身作為中央協調器。
- **論點**：
  1. 現有 `delegate` 由 Orrery 決定 tool/environment/resume session，再用 `DelegateProcessBuilder` 建立外部工具 process；模型本身沒有彼此發現或輪詢的入口，支持 Orrery 當 orchestrator。
  2. 現有 process builder 直接把 stdout/stderr 接到終端，`magi` 需要新增可 capture output 的 runner。
  3. MCP server 也是 mediator/orchestrator 風格（`MCPServer.swift` 的 `callTool/execCommand`），不是工具間 P2P。
  4. 第一版可用 deterministic mediator（不需額外 AI judge），必要時再讓指定 judge tool 做最終整理。
- **風險**：Mediator 若由單一模型擔任，可能把該模型偏見帶入共識；建議第一版保留 deterministic consensus summary。

**子議題 2：CLI 介面設計**
- **立場**：仿照 DelegateCommand 風格，強調參與者與輪數限制。
- **論點**：
  1. `-e/--environment` 沿用 delegate 和 run 的語意。
  2. tool selection 沿用 `--claude`、`--codex`、`--gemini` flag pattern，「沒有 flag」合理解讀為全部。
  3. 選項分三群：模型選擇、round 控制（`--rounds`、`--until-converged`）、輸出控制（`--format markdown|json`、`--output`）。
  4. 額外建議 `--judge claude|codex|gemini|none` 作為可選 judge。
- **風險**：`--tools` 與 `--claude/--codex/--gemini` 重複語意，建議第一版選一種。

**子議題 3：多輪對話管理**
- **立場**：Orrery 維護 canonical transcript，每輪注入摘要而非全量 raw output。
- **論點**：
  1. 可重用 `DelegateProcessBuilder` 的 tool command 與 environment 組裝，但需新增 capture stdout 路徑。
  2. 現有 `SessionMappingEntry` 只保存單一 tool/nativeSessionId，不足以表示 magi run 的三個模型 session。建議新增 `MagiRun` 類型。
  3. Convergence 判定：連續兩輪 consensus snapshot 沒有新增 disputed/pending，且所有模型對 agreed items 投 agree。
- **風險**：parallel 模式同時跑三個 process 時，用「latest session」回推有 race condition。多輪 transcript 膨脹需控制。

**子議題 4：共識判定機制**
- **立場**：兩階段結構化共識——第一階段提出 claims，第二階段對每個 claim 投票。
- **論點**：
  1. 新增 `MagiRoundResponse`、`ConsensusItem` 等 Codable 結構。
  2. 分類規則：`agreed` = 全部 agree 無 disagree；`disputed` = 至少一個 disagree；`pending` = 資訊不足或輸出缺失。
  3. 模型回覆應包含 `claims[]`、`evidence[]`、`risks[]`、`confidence`。
  4. JSON 不合法時保留 raw answer，計為 `pending`，不 silently drop。
- **風險**：模型可能不遵守 JSON schema；prompt 應保留 dissent 通道避免趨同偏見。

**子議題 5：與現有架構整合**
- **立場**：重用 environment 與 tool invocation 底層，但不要 shell-out `orrery delegate`。新增 `MagiCommand` + orchestration layer。
- **論點**：
  1. `Tool` 完整重用。`EnvironmentStore` 完整重用。
  2. `DelegateProcessBuilder` 部分重用或重構——需擴充為可 capture output。
  3. `SessionMapping` 不應直接作 magi run storage——需新的 `MagiRun` 結構管理多 tool sessions + 多輪 transcript。
  4. 若暴露給 MCP，新增 `orrery_magi` tool definition。
- **風險**：重構 `DelegateProcessBuilder` 時避免破壞既有 interactive resume（`StdinMode.interactive`）。

---

#### Gemini

**子議題 1：架構模式**
- **立場**：Orrery 作為中介者 (Mediator) 模式。
- **論點**：
  1. `Tool.swift` 中三個工具的實作細節完全不同（envVarName、installCommand），由 Orrery 擔任中介者可統一處理差異。
  2. `DelegateProcessBuilder` 已實作子程序建構邏輯，中介者可直接調用。
  3. 中介者模式方便在 Orrery 內部維護 `MagiSession` 結構。
- **風險**：`DelegateProcessBuilder.build()` 將 stdout 直接導向系統 stdout（第 114 行），**必須修改 Builder 以支援 Pipe 攔截輸出**。

**子議題 2：CLI 介面設計**
- **立場**：仿照 DelegateCommand 風格，加上參與者與輪數限制。
- **論點**：
  1. 參考 `DelegateCommand.swift` 的 `--claude`、`--gemini` flag 來決定參與模型（預設全部已登入模型）。
  2. 加入 `--rounds`（限制輪數）與 `--threshold`（共識門檻，如 2/3 同意）。
  3. 語法範例：`orrery magi "是否應遷移至 Swift 6?" --rounds 3 --output discussion.md`。
- **風險**：未設定 API Key 的模型應能 graceful degradation。

**子議題 3：多輪對話管理**
- **立場**：Sequential Prompt Injection 結合 Session Resume。
- **論點**：
  1. 利用 `DelegateProcessBuilder` 的 `--resume <id>` 參數，第一輪建立 session，後續帶前一模型輸出作為 prompt resume。
  2. 收斂控制：模型輸出包含「結束標籤」時進入準備就緒狀態。
- **風險**：`codex exec resume` 與 `gemini --resume` 行為可能不一致（上下文長度限制）。`StdinMode.nullDevice` 可能不適用於複雜多輪互動。

**子議題 4：共識判定機制**
- **立場**：強制模型在輸出結尾包含結構化元數據（`<MAGI_STATUS>AGREE|DISAGREE|PENDING</MAGI_STATUS>`）。
- **論點**：
  1. 系統提示注入要求模型以結構化標籤結尾。
  2. 需改用 Pipe 獲取輸出後搜尋標籤更新狀態。
- **風險**：模型可能忽略指令（Hallucination），需 regex fallback 從非結構化文本推斷立場。

**子議題 5：與現有架構整合**
- **立場**：高度重用 Helpers 層級，獨立 Commands 層級。
- **論點**：
  1. 重用 `SessionMapping` 儲存 Magi 討論的 session ID，方便事後追蹤模型思維路徑。
  2. 重用 `DelegateProcessBuilder` 但需擴充 `captureOutput: Bool` 參數。
  3. 在 `OrreryCommand.swift` 註冊新的 `MagiCommand`。
- **風險**：`DelegateProcessBuilder` 重構處理不當可能破壞 `RunCommand` 或 `DelegateCommand` 的互動式模式。

---

### Round 2（聚焦 6 個開放問題）

#### Q1: stdout capture 機制

| Agent | 立場 | 理由 |
|-------|------|------|
| **Claude** | **B（新建 MagiProcessRunner）** | 剛清理完 Builder（刪除 captureStdout/TeeCapture），不該又加回去。MagiProcessRunner 用 composition 複用 Builder，在 process.run() 前換 stdout 為 Pipe。 |
| **Codex** | **A（擴充 DelegateProcessBuilder）** | Builder 已封裝所有 tool-specific 邏輯，新建 Runner 會複製大量程式碼。加 `outputMode: .passthrough \| .capture` 枚舉，預設 `.passthrough` 不影響既有路徑。 |
| **Gemini** | **A（擴充 DelegateProcessBuilder）** | 改動僅在第 114 行。新建 Runner 要嘛重複邏輯，要嘛仍依賴 Builder 再包一層——後者本質就是擴充 Builder。 |

**結果**：majority — A（Codex + Gemini），Claude 保留意見但不阻擋。

#### Q2: 上下文傳遞策略

| Agent | 立場 | R1→R2 變化 |
|-------|------|-----------|
| **Claude** | **A（累積 prompt）** | 維持 |
| **Codex** | **A（累積 prompt）** | 維持 |
| **Gemini** | **A（累積 prompt）** | **改變**（從 B 改為 A）：承認 resume 行為不一致是致命問題，累積 prompt 完全由 Orrery 控制，保證上下文一致性。 |

**結果**：agreed — 三方一致。

#### Q3: 共識判定格式

| Agent | 立場 | 理由 |
|-------|------|------|
| **Claude** | **A（JSON）+ regex fallback** | JSON 比 XML 更結構化，兩階段太複雜（token 成本翻倍）。第一版用一階段 JSON。 |
| **Codex** | **C+A 混合（兩階段 + JSON 載體）** | 第一階段提出 claims 降低格式壓力，第二階段投票結構簡單。容許 dissent 避免趨同偏見。 |
| **Gemini** | **A（JSON）+ regex fallback** | **改變**（從 B 改為 A+fallback）：XML 太簡單無法攜帶 reasoning；兩階段太複雜；JSON 是最佳平衡。 |

**結果**：majority — A+fallback（Claude + Gemini），Codex 保留兩階段構想但同意 JSON 為載體。

**折衷**：第一版用一階段 JSON + regex fallback。v2 可選擇性加入第二階段投票（Codex 方案），作為 `--deep-consensus` flag。

#### Q4: Run storage 方案

| Agent | 立場 | R1→R2 變化 |
|-------|------|-----------|
| **Claude** | **A（新建 MagiRun）** | 維持 |
| **Codex** | **A（新建 MagiRun）** | 維持。可在 MagiRun 中加 optional `sessionIds: [Tool: String]` 兼顧 Gemini 需求。 |
| **Gemini** | **A（新建 MagiRun）** | **改變**（從 B 改為 A）：重新檢視 SessionMappingEntry 後認為結構不匹配，magi 需要層級查詢。 |

**結果**：agreed — 三方一致。

#### Q5: 第一版 scope

| Agent | `--judge` | `--until-converged` | 其他 |
|-------|-----------|---------------------|------|
| **Claude** | 不包含 | 不包含 | `--rounds`、tool flags、`-e`、`--output` |
| **Codex** | 不包含 | 不包含 | 同上。可 register 參數但標 hidden，為 v2 保留。 |
| **Gemini** | 不包含 | 不包含 | 同上。排除 `--threshold`（固定用多數決）。 |

**結果**：agreed — 三方一致。

#### Q6: Parallel vs. Serial 預設模式

| Agent | 立場 | 理由 |
|-------|------|------|
| **Claude** | Serial 預設 | 更安全、debug 更容易。`--parallel` 作為 opt-in，v1 可實作但不預設。 |
| **Codex** | Serial 預設 | Serial 可中途判斷「已全部 agree，跳過剩餘輪次」。Parallel 所有 agent 都會跑完。 |
| **Gemini** | Serial 預設 | UX 更好（使用者即時看到逐一回應）。效能差異可接受（90 秒 vs 30 秒）。 |

**結果**：agreed — 三方一致。

---

## 共識看板

| # | 子議題 | Claude | Codex | Gemini | 狀態 |
|---|--------|--------|-------|--------|------|
| 1 | 架構模式 | Orchestrator | Orchestrator+Mediator | Mediator | agreed |
| 2 | CLI 介面設計 | `orrery magi "<topic>"` + flags | 同左 | 同左 | agreed |
| 3 | 多輪對話管理 | 累積 prompt | 累積 prompt | 累積 prompt | agreed |
| 4 | 共識判定機制 | JSON + fallback | 兩階段 JSON（v2） | JSON + fallback | majority |
| 5 | 與現有架構整合 | 新建 MagiRun，重用 Builder+Store | 同左 | 同左 | agreed |
| Q1 | stdout capture | 新建 MagiProcessRunner | 擴充 Builder | 擴充 Builder | majority |
| Q5 | 第一版 scope | 精簡（無 judge/converge） | 同左 | 同左 | agreed |
| Q6 | 預設執行模式 | Serial | Serial | Serial | agreed |

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
| 1 | 架構模式採 Orchestrator/Mediator（Orrery 本身作為中央協調器），排除 P2P | 2026-04-15 | R1 | 三方一致 |
| 2 | CLI 指令為 `orrery magi "<topic>"`，新增獨立 `MagiCommand` 子命令 | 2026-04-15 | R1 | 三方一致 |
| 3 | 上下文傳遞用累積 prompt（不用 native session resume） | 2026-04-15 | R2 | 三方一致（Gemini R2 改變立場）：resume 行為不一致、無法跨 agent 可見 |
| 4 | Run storage 新建 `MagiRun` 結構，不複用 `SessionMapping` | 2026-04-15 | R2 | 三方一致（Gemini R2 改變立場）：結構不匹配 |
| 5 | 共識判定用一階段 JSON + regex fallback（兩階段延至 v2） | 2026-04-15 | R2 | majority（Claude+Gemini），Codex 同意 JSON 載體但保留兩階段構想 |
| 6 | 第一版不含 `--judge`、`--until-converged`，用 deterministic 多數決 | 2026-04-15 | R2 | 三方一致 |
| 7 | 預設 Serial 執行，`--parallel` 為 opt-in（第一版可不實作） | 2026-04-15 | R2 | 三方一致 |
| 8 | stdout capture 擴充 `DelegateProcessBuilder` 加 `OutputMode` 枚舉 | 2026-04-15 | R2 | majority（Codex+Gemini），Claude 偏好新建 Runner 但不阻擋 |
| 9 | v1 MagiRun schema 預留 v2 兩階段投票欄位（`votes: [Vote]?` optional） | 2026-04-15 | R2 | 使用者決定：偏好前瞻做法 |
| 10 | Prompt 差異化摘要：自己前輪 = 完整 raw output（延續思考脈絡）；其他 agent = 結構化 positions | 2026-04-15 | spec | 使用者提議：模型需要知道自己的思考流程才能堅定立場 |

---

## 開放問題

1. ~~stdout capture 機制~~ → **已決定 D8**：擴充 Builder 加 `OutputMode`
2. ~~上下文傳遞策略~~ → **已決定 D3**：累積 prompt
3. ~~共識判定格式~~ → **已決定 D5**：一階段 JSON + fallback
4. ~~Run storage~~ → **已決定 D4**：新建 MagiRun
5. ~~第一版 scope~~ → **已決定 D6**：精簡
6. ~~Parallel vs. Serial~~ → **已決定 D7**：Serial 預設

### 新開放問題（R2 衍生）

7. ~~MagiRun JSON schema 細節~~ → 在 spec 中定義
8. ~~Prompt template 設計~~ → 在 spec 中定義
9. ~~兩階段投票 v2 預留~~ → **已決定 D9**：v1 預留 optional 欄位
10. ~~OutputMode regression 驗證~~ → 在 spec 驗收標準中定義

---

## 下次討論指引

### 進度摘要

Round 2 完成。6 個 R1 開放問題全部收斂（4 個 agreed、2 個 majority）。共達成 8 項決策。Gemini 在 Q2/Q3/Q4 改變立場趨向共識。討論已接近可產出 spec 的狀態。

### 待處理事項

- 確定 `MagiRun`/`MagiRound`/`ConsensusItem` 的 Codable schema
- 設計 prompt template（要求 JSON 輸出的格式指令）
- 決定 v1 schema 是否為 v2 兩階段投票預留欄位
- 確認 `OutputMode` 擴充的 regression test 範圍

### 閱讀建議

- `Sources/OrreryCore/Helpers/DelegateProcessBuilder.swift` — `OutputMode` 擴充基礎
- `Sources/OrreryCore/Commands/DelegateCommand.swift` — regression 對照
- `Sources/OrreryCore/Commands/OrreryCommand.swift` — 新增 MagiCommand 的註冊點

### 注意事項

- 擴充 `DelegateProcessBuilder` 時 Claude 建議用 composition（MagiProcessRunner 內部使用 Builder）而非直接修改 Builder——若 `OutputMode` 方案在實作時顯得侵入性過高，可回退到 Claude 方案
- Codex 的觀點仍然重要：多模型共識 ≠ 事實正確，最終報告應標明這是「模型間的共識判定」
