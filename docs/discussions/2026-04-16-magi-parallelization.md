---
topic: "Orrery Magi 並行化設計"
status: consensus
created: "2026-04-16"
updated: "2026-04-16"
participants:
  - Claude (Opus 4.6)
  - Codex (GPT-5.4)
  - Gemini
facilitator: Claude
rounds_completed: 4
---

# Orrery Magi 並行化設計

## 議題定義

### 背景

目前 `MagiOrchestrator.swift` 的討論流程是依序呼叫三個模型（Claude → Codex → Gemini），使用 for loop 逐一啟動 subprocess 並等待完成。同一輪內三個模型收到相同 prompt、各自獨立回答，但技術上是序列執行，導致總等待時間為三者之和（A + B + C），而非理論最小值 max(A, B, C)。

此外，目前每次 Magi 討論都是全新 session（`resumeSessionId: nil`），無法延續先前的討論脈絡。

### 目標

1. 將三個模型的呼叫從序列改為並行，縮短等待時間約 3 倍
2. 設計 session 續接機制，讓 Magi 討論可以跨輪次延續
3. 強化共識報告格式，使其可直接作為 write-spec 的輸入
4. 設計討論 → spec 的整合流程

### 範圍

**In scope:**
- MagiOrchestrator 並行化實作
- Session 續接的資料結構與 API 設計
- 共識報告格式強化
- Magi → write-spec 的觸發機制

**Out of scope:**
- write-spec skill 本身的實作細節
- MCP server 協議變更
- 前端 UI

### 約束

- Orrery 是 Swift 專案，使用 Swift Package Manager
- 目前 MagiOrchestrator 是同步 API（`throws -> MagiRun`）
- DelegateProcessBuilder 啟動的是外部 CLI subprocess（claude/codex/gemini）
- 需要向後相容現有的 MagiRun JSON 格式

### 子議題

- [ ] 子議題 1：Swift 並行化方案選擇（DispatchGroup / async-await / Process 並行）
- [ ] 子議題 2：輸出收集、錯誤處理與 timeout 機制
- [ ] 子議題 3：Session 續接的資料結構與 API 設計
- [ ] 子議題 4：共識報告格式強化 + Magi → write-spec 流程整合

---

## 討論紀錄

### Round 1 (2026-04-16)

#### Claude (Opus 4.6)

**子議題 1：Swift 並行化方案 — DispatchGroup + Process 並行**

1. `MagiOrchestrator.run()` 是同步 `throws` 函式，改 `async` 會波及所有呼叫端（`MagiCommand`、`MCPServer`）
2. `DelegateProcessBuilder` 產出 `Process` 物件，可同時 `run()` 多個，用 `DispatchGroup` 等待最自然
3. 不需要引入 Swift Concurrency 的複雜度（structured concurrency + Sendable 合規）

**子議題 2：輸出收集與 timeout — 每 Process 獨立收集 + 120s timeout**

1. 每個 process 有自己的 `Pipe`，互不干擾
2. 某個模型失敗不應阻塞其他模型，fallback 到空回應（現有邏輯已有）
3. 用 `process.terminate()` + timer 實作 timeout，建議預設 120 秒

**子議題 3：Session 續接 — MagiRun 新增 `sessionMap: [String: String]`**

1. 每次 delegate 完成後解析 session ID，存入 `MagiRun.sessionMap`
2. 續接時接受 `previousRunId` 參數，載入前次 run 的 sessionMap
3. 傳入 `DelegateProcessBuilder` 的 `resumeSessionId`

**子議題 4：共識報告格式 — 加 Final Summary + spec-ready 模式**

1. `generateReport` 尾端加 `## Final Summary`（Goals / Decisions / Open Questions / Constraints）
2. MCP tool 新增可選參數 `outputFormat: "report" | "spec-ready"`
3. write-spec 可直接讀取 spec-ready 格式

---

#### Codex (GPT-5.4)

**子議題 1：Swift 並行化方案 — conditional：並行 Process，但不推薦 DispatchGroup 作主要設計**

1. 瓶頸在序列 subprocess lifecycle，不在 prompt building。`for tool in tools` + `waitUntilExit()` 逐一阻塞
2. 現有公開 API 是同步的，改 `async` 會波及 CLI entrypoint（同意保持同步）
3. `DispatchGroup` 可行，但加上 per-tool timeout、stdout/stderr 收集、termination status、session-id 抽取後，用專屬 per-tool runner struct 更容易推理
4. 建議：每個 tool 一個 runner，內部封裝 Process + Pipe + timeout + 結果收集

**子議題 2：輸出收集與 timeout — agree：隔離收集 + 執行 metadata + per-process timeout**

1. 目前只捕獲 stdout，stderr 直接傳遞，不存入 `MagiAgentResponse`
2. 未檢查 `process.terminationStatus`，subprocess non-zero exit 也可能被標為 parsed
3. 錯誤處理太粗糙：任何 error 變成 `rawOutput: ""`，無 exit code / stderr / timeout 欄位
4. `readDataToEndOfFile()` 在 `waitUntilExit()` 後呼叫，若 child 填滿 pipe buffer 可能 deadlock

**子議題 3：Session 續接 — agree：在 MagiRun 存 per-tool session ID**

1. `DelegateProcessBuilder` 已有 `resumeSessionId` 參數 + 各 tool 的 resume argv，但 Magi 從未使用
2. 目前跨輪次靠 prompt replay（`MagiPromptBuilder.collectOwnOutputs`），不是真正 session 續接
3. `MagiRun` 需要 `sessionMap: [String: String]`，`MagiAgentResponse` 需要記錄實際使用/產出的 session ID
4. 已有 `SessionResolver` 可掃描各 tool 的最新 session ID

**子議題 4：共識報告格式 — conditional：強化格式，但透過穩定 artifact 整合，非硬編碼直接呼叫**

1. 目前報告是人類可讀但作為 spec 輸入太弱（截斷 500 字元、缺乏結構化段落）
2. `MagiRun` JSON 是更強的 canonical source，已有結構化 rounds/responses/positions
3. `Sources/` 內無 `WriteSpecCommand`，write-spec 只存在於 docs，整合點應該是 `outputPath` + `magi/<runId>.json`
4. MCP stdout 混雜進度訊息和最終報告，下游消費者拿不到乾淨的 report-only channel

---

#### Gemini

**子議題 1：Swift 並行化方案 — agree：推薦 TaskGroup + async/await**

1. `withThrowingTaskGroup` 可並行執行且維持 parent-child 關係，取消時自動取消所有子任務
2. 比 `DispatchGroup` 更安全，不需手動 `enter()`/`leave()` 平衡
3. 將 `process.waitUntilExit()` 包在 `Task` 裡，主執行緒可保持響應

**子議題 2：輸出收集與 timeout — conditional：並行但需注意 pipe 處理與 timeout**

1. 每個 task 必須獨立處理自己的失敗，不能讓一個 hung process 阻塞整輪
2. 用 `Task.sleep` race 實作 per-tool per-round hard timeout
3. `readDataToEndOfFile()` 是阻塞呼叫，建議改用 `FileHandle.readabilityHandler` 做增量串流

**子議題 3：Session 續接 — agree：MagiRun 加 `sessionMapping: [String: String]`**

1. `resumeSessionId: nil` 硬編碼，DelegateProcessBuilder 的 `--resume` 從未被 Magi 使用
2. 加 `var sessionMapping: [String: String]`，orchestrator 在後續輪次取用
3. 有了 `--resume`，`MagiPromptBuilder.collectOwnOutputs` 的 workaround 可簡化或移除，減少 token 用量

**子議題 4：共識報告格式 — agree：雙輸出（machine-readable JSON + human-readable markdown）**

1. `generateReport` 純人類可讀 markdown，需加 Decision Object 給自動化管線
2. `computeConsensus` 應強化，納入 `reasoning` 欄位說明爭議原因
3. `MagiRun` 應有方法匯出 "Final Verdict" 結構化格式供下游工具使用

### Round 2 (2026-04-16) — 聚焦收斂子議題 1

#### Claude (Opus 4.6)

**修正立場：DispatchGroup + per-tool runner struct（吸收 Codex 建議）**

1. Codex 的 per-tool runner 和 DispatchGroup **不互斥**。Runner 是封裝模式，DispatchGroup 是同步等待原語，可以組合
2. Gemini 的 TaskGroup async/await 改動成本太高：`run()` → async 會波及 MagiCommand、MCPServer
3. 折衷方案：公開 API 保持同步，內部用 `DispatchQueue.global().async` + `DispatchGroup` 並行啟動 3 個 runner
4. `readDataToEndOfFile()` deadlock 解法不需要 async — 在 background thread 先讀再 wait 即可

---

#### Codex (GPT-5.4)

**接受折衷，但有修正**

1. async/await 的 ripple 其實沒 Round 1 說的那麼大：MCPServer 不是直接呼叫 orchestrator（是 shell out），唯一直接 caller 是 MagiCommand
2. 但 repo 目前沒有 async command path，採用 async 會強制新增 sync bridge 或改 CLI layer
3. **同意 DispatchGroup + per-tool runner struct** 是最佳近期平衡
4. **關鍵要求**：runner 必須完整封裝 process lifecycle、stdout/stderr 收集、termination status、timeout outcome、session-id capture。不能讓這些邏輯散落在 orchestrator 裡
5. async/await 可作為第二步重構，不是解決 latency 問題的前提

---

#### Gemini

**Conditional agree — 接受折衷方案**

1. 承認 async ripple 是合理考量：改 `run()` 為 async 會連帶需要 `AsyncParsableCommand` + MCPServer 重構
2. **強力支持 Runner struct**：建議命名 `MagiAgentRunner`，封裝 Process + Pipe + stderr buffer + 執行狀態
3. Deadlock 修復與 async/await 無關 — 是 I/O 模型問題，background thread 讀取即可解決
4. **Thread safety 警告**：目前 `responses.append(response)` 在並行下不安全，需要 serial queue 或 lock
5. **Timeout 需要主動清理**：`DispatchGroup.wait(timeout:)` 不會取消正在跑的 process，Runner 必須暴露 `terminate()` 方法

### Round 3 (2026-04-16) — 收斂子議題 2 和 4

#### Claude (Opus 4.6)

**子議題 2：MagiAgentRunner 具體介面整合提案**

```swift
struct MagiAgentRunner {
    let tool: Tool
    let process: Process
    let stdoutPipe: Pipe
    let stderrPipe: Pipe

    struct Result {
        let tool: Tool
        let rawOutput: String
        let stderrOutput: String
        let exitCode: Int32
        let timedOut: Bool
        let sessionId: String?
        let duration: TimeInterval
    }

    func run(timeout: TimeInterval) -> Result
    func terminate()
}
```

1. Codex 的 metadata 需求（exit code, stderr, duration）→ 全部放進 Result
2. 內部 background thread 讀取避免 deadlock，不暴露 streaming API
3. Timeout 用 DispatchWorkItem 延遲呼叫 `process.terminate()`

**子議題 4：報告格式整合提案**

1. 不改 markdown report（保持人類可讀）
2. MagiRun JSON 加 `finalVerdict` 欄位（Goals / Decisions / Open Questions / Constraints）
3. write-spec 讀 JSON 不讀 markdown = Codex 的 artifact-based 整合
4. Progress 訊息改 stderr，stdout 只輸出 final report

---

#### Codex (GPT-5.4)

**子議題 2：Amend — 同意 Runner 設計，補充修正**

1. Runner 必須吸收完整 process lifecycle，不只是持有 Tool + Process + Pipes
2. Streaming read on background thread 是正確修正，解決 deadlock 風險
3. **stderr 捕獲需要改 DelegateProcessBuilder**：目前 `DelegateProcessBuilder.swift:129` 硬寫 `process.standardError = FileHandle.standardError`，Runner 需要覆寫
4. `exitCode`、`timedOut`、`duration` 填補了真實的可觀測性缺口
5. `sessionId` 不應為必要 — 目前無抽取機制，`SessionResolver` 對 Codex 的掃描是 global 而非 project-scoped，建議 optional 或延遲至子議題 3
6. `MagiRun.save()` 的 `try?` 吞錯在下游自動化中是管線風險，需改為拋出或至少記錄

**子議題 4：Amend — 同意 JSON artifact，補充修正**

1. 同意 JSON 為 machine-readable source of truth，write-spec 消費 JSON
2. **不同意 "keep markdown as-is"**：目前 report 截斷各 agent 輸出為 500 字元（`MagiOrchestrator.swift:184`），太有損
3. `finalVerdict` 方向正確但 **需要額外生成步驟**：目前 prompt 只要求 positions JSON，parser 也只解碼此 schema，無法自動推導 Goals/Decisions/Open Questions
4. `finalVerdict` 必須 optional 以保向後相容（MagiRun 用 synthesized Codable）
5. MCP 需回傳 `runId` 或 JSON 路徑，目前存檔路徑只寫入 stderr（`MagiOrchestrator.swift:105`），MCP 成功回應丟棄 stderr
6. MCPServer 自身的 `execCommand()` 也有相同的 pipe-drain 問題

---

#### Gemini

**子議題 2：agree — 接受 Runner 設計，兩項微調**

1. Deadlock 修正正確：background thread 讀取再 waitUntilExit() 是標準 POSIX 模式
2. Timeout 用 DispatchWorkItem + `process.terminate()` 比 `DispatchGroup.wait(timeout:)` 更好，後者不會取消 process
3. Thread safety 用 serial DispatchQueue 收集結果，比 lock 更 idiomatic
4. **微調 1**：Runner 自己建 stderr Pipe 並覆寫 `process.standardError`（不改 DelegateProcessBuilder）
5. **微調 2**：sessionId 用 `SessionResolver` post-exit 掃描取得，不從 stdout 解析

**子議題 4：agree — 確認三方其實是同一設計**

1. Markdown report 保持人類可讀（可選加 Final Summary）
2. MagiRun JSON 加 `finalVerdict: FinalVerdict?`，提議結構：

```swift
public struct FinalVerdict: Codable {
    public let decisions: [VerdictDecision]
    public let openQuestions: [String]
    public let constraints: [String]
}
public struct VerdictDecision: Codable {
    public let subtopic: String
    public let status: ConsensusStatus
    public let summary: String
    public let reasoning: String
    public let dissent: String?
}
```

3. write-spec 讀 `magi/<runId>.json` 的 `finalVerdict.decisions`
4. Progress 訊息改 stderr，stdout = final report only
5. `finalVerdict` 的 summary/reasoning 需要從 parsed positions 合成，這是實作細節

---

### Round 4 (2026-04-16) — 風險緩解方案

#### Claude (Opus 4.6)

**風險 1 — SessionResolver 精度**：記錄 launch 前時間戳，只接受之後的 session；或從 CLI stdout 解析 session ID
**風險 2 — Prompt 重複**：有 resumeSessionId 時，MagiPromptBuilder 只提供本輪新資訊（其他模型回應），不重播自己歷史
**風險 3 — FinalVerdict 品質**：A+C 混合 — 最後一輪 prompt 要求結構化 verdict，程式碼從三方 merge

---

#### Codex (GPT-5.4)

**風險 1**：不同意純 timestamp（時鐘精度不足）也不同意 stdout 解析（三個 CLI 輸出格式不穩定）。推薦 **scoped file diff**：launch 前 snapshot session files，launch 後取新增的 file ID，timestamp 只當輔助排序

**風險 2**：不同意直接移除 `collectOwnOutputs`（fresh session 仍需要）。推薦 **conditional replay**：`MagiPromptBuilder.buildPrompt()` 加 `includeOwnHistory: Bool` 參數，resume 時傳 false，fresh 時傳 true

**風險 3**：同意 A+C hybrid。先新增 FinalVerdict model，最後一輪 prompt 要求輸出結構化 verdict，程式碼做 deterministic merge。純 C 不夠（reasoning 太短），純 B 太貴

---

#### Gemini

**風險 1**：推薦 **filesystem snapshot diff**（launch 前後各掃一次 session files，取差集）。比 timestamp 可靠（不依賴時鐘精度），比 stdout 解析可靠（不依賴外部 CLI 格式）

**風險 2**：同意 conditional replay。建議加 `includeOwnHistory: Bool` 參數。Resume 時只注入最新一輪的 cross-model positions，不注入所有歷史輪次（避免另一種重複）。省下的 token budget 可分配給更豐富的跨模型上下文

**風險 3**：推薦 **refined A+C**：最後一輪 prompt 不改（避免 prompt 污染），改為純程式碼從 final positions 生成 FinalVerdict — majority/agreed 的 reasoning 做 summary，disagreeing 的做 dissent，disputed 做 openQuestions，conditional 的 reasoning 做 constraints。另外提供 opt-in `--summarize` flag，需要高品質時額外呼叫單一模型做 summarization pass

---

## 共識看板

| # | 子議題 | Claude | Codex | Gemini | 狀態 |
|---|--------|--------|-------|--------|------|
| 1 | Swift 並行化方案選擇 | agree (DispatchGroup+Runner) | agree (DispatchGroup+Runner) | conditional agree (DispatchGroup+Runner) | agreed |
| 2 | 輸出收集、錯誤處理與 timeout | agree (Runner+Result) | agree (amend: stderr pipe+save error) | agree (Runner owns stderr pipe) | agreed |
| 3 | Session 續接的資料結構與 API | agree (sessionMap) | agree (sessionMap+response metadata) | agree (sessionMapping+SessionResolver) | agreed |
| 4 | 共識報告格式 + write-spec 流程 | agree (JSON artifact) | agree (amend: finalVerdict需生成步驟) | agree (FinalVerdict struct) | agreed |
| 5 | 風險：SessionResolver 精度 | timestamp cutoff | scoped file diff | filesystem snapshot diff | agreed (file diff) |
| 6 | 風險：Prompt 重複 | drop own history on resume | conditional replay param | conditional replay + latest-round only | agreed (conditional) |
| 7 | 風險：FinalVerdict 品質 | B 為預設 (user override) | A+C hybrid | refined A+C + opt-in B | agreed (B 為預設) |

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
| 1 | Session 續接：MagiRun 新增 `sessionMap: [String: String]`，搭配 DelegateProcessBuilder 已有的 resumeSessionId | 2026-04-16 | Round 1 | 三方一致同意 |
| 2 | 並行化方案：DispatchGroup + per-tool `MagiAgentRunner` struct，公開 API 保持同步 | 2026-04-16 | Round 2 | 三方同意（Gemini conditional） |
| 3 | Runner 介面：`MagiAgentRunner` 封裝 process lifecycle + stdout/stderr pipe + exit code + timeout + duration。Runner 自建 stderr Pipe。sessionId 用 SessionResolver post-exit 掃描 | 2026-04-16 | Round 3 | 三方同意 |
| 4 | 報告格式：MagiRun JSON 加 `finalVerdict: FinalVerdict?`，含 decisions/openQuestions/constraints。write-spec 讀 JSON artifact。Progress 改 stderr。MCP 回傳 runId | 2026-04-16 | Round 3 | 三方同意 |
| 5 | SessionResolver 精度：用 filesystem snapshot diff（launch 前後各掃一次，取差集），不依賴時鐘或 CLI 輸出格式 | 2026-04-16 | Round 4 | 三方同意 |
| 6 | Prompt 重複：`MagiPromptBuilder.buildPrompt()` 加 `includeOwnHistory: Bool`，resume 時 false + 只注入最新一輪 cross-model positions | 2026-04-16 | Round 4 | 三方同意 |
| 7 | FinalVerdict 品質：**預設用 B（summarization call）**。所有輪次結束後，自動呼叫 facilitator 模型，傳入完整 MagiRun JSON，產出去重、合併的高品質 FinalVerdict。可用 `--no-summarize` 跳過降為純程式碼 merge | 2026-04-16 | Round 4 → user override | 使用者決定：B 為預設，理由是 opt-in 的 UX 太差 |

---

## 開放問題

1. ~~**並行化方案分歧**~~ → Round 2 已收斂
2. ~~**Session ID 取得**~~ → Round 3 決定用 SessionResolver post-exit 掃描
3. ~~**stdout 污染問題**~~ → Round 3 決定 progress 改 stderr
4. ~~**pipe buffer deadlock**~~ → Round 3 決定 Runner 在 background thread 先讀再 wait
5. ~~**Thread safety**~~ → Round 3 決定用 serial DispatchQueue
6. ~~**Timeout 主動清理**~~ → Round 3 Runner 用 DispatchWorkItem + terminate()

### 實作待確認事項（非設計問題）

1. `MagiRun.save()` 的 `try?` 吞錯 — 下游自動化依賴 JSON artifact，需改為拋出或記錄（Codex 提出）
2. `MCPServer.execCommand()` 也有相同 pipe-drain 問題，需一併修復（Codex 提出）
3. MCP 成功回應需包含 `runId` 或 JSON 路徑（Codex 提出）

---

## 下次討論指引

### 進度摘要

Round 4 完成。原始 4 個子議題 + 3 個風險緩解方案，共 7 項決策全部 agreed 或 majority。討論可結束，進入 write-spec 階段。

### 決策總覽

1. **並行化**：DispatchGroup + MagiAgentRunner struct，公開 API 同步
2. **Runner 介面**：封裝 process lifecycle、stdout/stderr pipe、exit code、timeout、duration。Runner 自建 stderr Pipe
3. **Session 續接**：MagiRun 新增 `sessionMap: [String: String]`
4. **報告格式**：MagiRun JSON 加 `finalVerdict: FinalVerdict?`。write-spec 讀 JSON。Progress 改 stderr。MCP 回傳 runId
5. **SessionResolver 精度**：filesystem snapshot diff（launch 前後掃描取差集）
6. **Prompt 重複**：`buildPrompt()` 加 `includeOwnHistory: Bool`，resume 時只注入最新一輪 cross-model positions
7. **FinalVerdict 品質**：預設 B（自動 summarization call），可用 `--no-summarize` 降為純程式碼 merge
