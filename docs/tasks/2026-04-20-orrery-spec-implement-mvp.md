# Orrery `orrery_spec_implement` MVP 實作 spec

## 來源

`docs/discussions/2026-04-20-orrery-spec-implement-mvp.md`

## 目標

把「discuss → spec → implement → verify」閉環中、繼 `orrery_spec_verify`（2026-04-19 完成）後的下一塊實作：`orrery_spec_implement` MCP tool + 配套 `orrery_spec_status` polling tool。此 phase 將 spec 餵給 delegate agent（claude-code / codex / gemini）subprocess 寫碼，並以 **early-return + polling** 模型解決「5-60 分鐘任務 vs MCP client 60-120s timeout」的結構張力。

實作 MVP 恪守 9 項共識（DI1-DI9）：早期回傳 session_id、0 retry（僅 transport-launch 例外）、序列執行但預留並行欄位、prompt 妥協版（介面合約 + 驗收標準必 inline）、spec 即 plan（加靜態完整性安全閥）、richer output 但禁止 delegate 內部 self-check、新目錄 `~/.orrery/spec-runs/`、progress jsonl + `git diff --name-only` 混合資料來源。破壞半徑透過「不 auto-commit、不執行 sandbox shell、stop-and-report」收斂，延續 D11/D16。

## 介面合約（Interface Contract）

### 1. CLI：`orrery spec-run --mode implement | status` 新增分支

**所在位置**：`Sources/OrreryCore/Spec/SpecRunCommand.swift`（既有檔案擴充，沿用 verify MVP 的 `ParsableCommand` shell）

```swift
// 既有 options 保留；新增 --session-id / --watch
@Option(name: .long) public var sessionId: String?   // 僅 --mode status 必填
@Flag(name: .long)   public var watch: Bool = false  // --mode implement 同步 block 直到結束（debug 用）
```

- **Mode 分派（擴充自 verify MVP）**：
  - `--mode implement` → `SpecImplementRunner.run(...)` → 印 `SpecRunResult`（implement shape）JSON 到 stdout。
  - `--mode status` → `SpecRunStateStore.load(sessionId:)` → 印 `SpecStatusResult` JSON 到 stdout。
  - `--mode plan | run` 仍 throw `L10n.SpecRun.modeNotImplemented(mode)`（沿用 verify MVP 處理）。
- **Throws（新增）**：
  - `ValidationError(L10n.SpecRun.missingInterfaceContractSection)` — spec 缺「## 介面合約」段（DI5 安全閥 [inferred: 鍵名延伸 verify 的 L10n pattern]）。
  - `ValidationError(L10n.SpecRun.missingChangedFilesSection)` — spec 缺「## 改動檔案」段。
  - `ValidationError(L10n.SpecRun.missingImplementationStepsSection)` — spec 缺「## 實作步驟」段。
  - `ValidationError(L10n.SpecRun.missingAcceptanceSection)` — 沿用既有鍵，缺「## 驗收標準」段（四段必備）。
  - `ValidationError(L10n.SpecRun.sessionIdRequired)` — `--mode status` 未帶 `--session-id`。
  - `ValidationError(L10n.SpecRun.sessionNotFound(id))` — `--mode status` 找不到 `~/.orrery/spec-runs/{id}.json`。
  - `ValidationError(L10n.SpecRun.delegateLaunchFailed(stderr))` — transport-launch fail 經一次 auto-retry 後仍失敗。
- **觀察不變式**：
  - CLI 永遠印一個 JSON 物件到 stdout（即使失敗走 `SpecRunResult.errorShell`）。
  - `--mode implement` 預設 early-return：fork detached subprocess 後 print `{session_id, phase:"implement", status:"running", ...}` 然後退出（exit 0）。
  - `--mode implement --watch`：block 至 delegate 結束，同步印最終 `SpecRunResult`（僅供 debug / CI）。
  - `--mode status` 純讀檔、永不啟動任何 subprocess。
  - Session ID 格式：UUIDv4 字串（由 `SpecImplementRunner` 生成，對應 delegate agent 的 resume session id）[inferred]。

### 2. MCP Tool：`orrery_spec_implement`（DI1）

**所在位置**：`Sources/OrreryCore/MCP/MCPServer.swift`（`toolDefinitions()` + `callTool()`）

**Input schema**：

```json
{
  "type": "object",
  "properties": {
    "spec_path":         { "type": "string", "description": "Path to spec markdown file (relative to CWD or absolute)" },
    "tool":              { "type": "string", "enum": ["claude", "codex", "gemini"] },
    "resume_session_id": { "type": "string", "description": "Optional orrery spec-run session UUID (returned by a prior orrery_spec_implement call). Do NOT pass the delegate agent's native session id — orrery resolves delegate resume internally." },
    "timeout":           { "type": "integer", "description": "Overall seconds for delegate subprocess (default 3600)" },
    "environment":       { "type": "string" }
  },
  "required": ["spec_path"],
  "additionalProperties": false
}
```

（`token_budget` 已從 MVP 移除以避免誤導 — Runner 的 `tokenBudget: Int?` 仍保留做未來擴充點，MVP 僅透過 CLI 內部 hook 傳入，不對 MCP client 暴露。見 Q-impl-7 follow-up。）

**Output schema**（early-return 形狀；**error case 亦遵循同一 schema**）：

```json
{
  "session_id": "string|null",
  "phase": "implement",
  "status": "running|done|failed|aborted",
  "started_at": "ISO8601 string",
  "completed_at": "ISO8601 string|null",
  "completed_steps": ["string"],
  "touched_files": ["string"],
  "diff_summary": "string|null",
  "blocked_reason": "string|null",
  "failed_step": "string|null",
  "child_session_ids": ["string"],
  "execution_graph": "object|null",
  "error": "string|null"
}
```

- `status` 在第一次 tool call 回傳時通常為 `"running"`；呼叫方需透過 `orrery_spec_status` polling 取得最終狀態（DI1）。
- `child_session_ids` / `execution_graph` 為**預留欄位**（DI3）：MVP 永遠填空陣列 / `null`，runtime 不使用。
- `completed_steps` / `touched_files` 在 early-return 當下可能為空陣列；最終值由 polling 讀到完成後的狀態檔取得（DI6）。
- `diff_summary` 由 orchestrator 自動跑 `git diff --stat`（完成時）或 `git diff --name-only` 組合（進度階段）填入（DI8）。
- `error` 正常路徑為 `null`；validation error 時填訊息字串，其餘欄位以空陣列 / 空字串保持 schema 可穩定反序列化（沿用 verify MVP 的 H5 pattern）。

### 3. MCP Tool：`orrery_spec_status`（DI1 + DI7）

**Input schema**：

```json
{
  "type": "object",
  "properties": {
    "session_id":     { "type": "string", "description": "Required. The implement session id returned by orrery_spec_implement." },
    "include_log":    { "type": "boolean", "description": "If true, include the last N lines of progress jsonl in `log_tail`. Default false." },
    "since_timestamp":{ "type": "string", "description": "Optional ISO8601 timestamp; only progress events after this are returned in log_tail." }
  },
  "required": ["session_id"],
  "additionalProperties": false
}
```

**Output schema**：

```json
{
  "session_id":  "string",
  "phase":       "implement",
  "status":      "running|done|failed|aborted",
  "started_at":  "ISO8601 string",
  "updated_at":  "ISO8601 string",
  "progress":    { "current_step": "string|null", "total_steps": "integer|null" },
  "last_error":  "string|null",
  "result":      "SpecRunResult|null",
  "log_tail":    ["string"]
}
```

- `result` 僅在 `status != "running"` 時填入完整 `SpecRunResult`（與 §2 輸出同形）；`running` 時為 `null`。
- **Polling cadence 建議**（寫入 tool description 供呼叫方 LLM 參考）：首次 2s → exponential backoff `next = min(30s, prev * 1.5)` → 長跑 >5min 固定 30s。
- `progress.current_step` / `total_steps` 由 `SpecProgressLog` 從 jsonl 最後一筆 `start` event 推斷（DI8）；log 為空 → 兩者皆 `null`。
- `log_tail`：預設 `[]`；`include_log=true` 時回最後 50 行（MVP 固定 [inferred]），每行為 jsonl 原始字串。
- **Throws**：
  - `toolError(L10n.SpecRun.sessionIdRequired)` — 缺 `session_id`。
  - `toolError(L10n.SpecRun.sessionNotFound(id))` — 狀態檔不存在。

### 4. `SpecImplementRunner`（T5）

**所在位置**：`Sources/OrreryCore/Spec/SpecImplementRunner.swift`（新檔）

```swift
public struct SpecImplementRunner {
    public static func run(
        specPath: String,
        tool: Tool?,
        environment: String?,
        store: EnvironmentStore,
        resumeSessionId: String?,        // orrery spec-run session UUID (our tracking id)
        overallTimeout: TimeInterval,
        tokenBudget: Int?,
        watch: Bool
    ) throws -> SpecRunResult
}
```

- **Session ID identity（C2 釐清）**：
  - `sessionId`（UUID）= **orrery spec-run 追蹤 id**，用於 state 檔 `~/.orrery/spec-runs/{id}.json` 以及 MCP `resume_session_id` 參數。
  - `delegateSessionId`（claude-code / codex / gemini 各自原生 id）= delegate agent 真正能 `--resume` 的 id；**與 UUID 不同**。
  - 兩者解耦：orrery 追蹤自己的 UUID；delegate 原生 id 在 subprocess 啟動後由 `SessionResolver.findScopedSessions` 做 pre/post snapshot diff 捕獲（沿用 Magi `MagiAgentRunner.swift:52-58,115-123` pattern），存進 `SpecRunState.delegateSessionId`。
  - Resume 流程：MCP client 傳 `resume_session_id = <UUID>` → Runner load `SpecRunState` → 取 `state.delegateSessionId` → 傳給 `DelegateProcessBuilder.resumeSessionId`。
- **Detached lifecycle（C1 解法：wrapper shell + `_spec-finalize` 隱藏子命令）**：
  - 問題：`process.terminationHandler` 在 orrery parent 程序 exit 後不會 fire；detached subprocess 會變 orphan，state 永遠停在 `"running"`。
  - 解法：Runner 不直接 spawn delegate CLI；改 spawn 一段 **wrapper shell** 作為 owner，wrapper 負責：
    1. 跑真正的 delegate command。
    2. Delegate 結束後 **回 call `orrery _spec-finalize <session_id> <exit_code>`**（一個新增的**隱藏子命令**）做收尾。
  - Wrapper shell 範本（以字串形式組好後 `bash -c` 執行；**含 timeout watchdog 以兌現 MCP input schema 的 `timeout` 承諾 / G1**）：
    ```bash
    {delegate_cmd} </dev/null >>"{stdout_log}" 2>>"{stderr_log}" &
    DELEGATE_PID=$!
    ( sleep {TIMEOUT_SECONDS} && kill -TERM $DELEGATE_PID 2>/dev/null ) &
    WATCHDOG_PID=$!
    wait $DELEGATE_PID
    RC=$?
    kill $WATCHDOG_PID 2>/dev/null || true
    "{orrery_path}" _spec-finalize "{session_id}" "$RC" </dev/null >/dev/null 2>&1 || true
    ```
  - 這樣 wrapper 本身就是 detached process 的 owner；orrery parent 隨時可 exit，delegate 結束時 wrapper 照常呼叫 finalize；若 delegate 超過 `timeout` 秒，watchdog 發 SIGTERM 終止 delegate、`wait` 得到 `RC=143`（`128 + SIGTERM`），finalize 收尾時填 `status="aborted"`, `blockedReason="overall timeout"`。
  - 若 `TIMEOUT_SECONDS` 為 0 或負數 → 省略 watchdog 那兩行（`--watch` 模式由 Swift 端的 DispatchWorkItem 接手；detached 且無 timeout 即無限跑，非預設）。
  - `_spec-finalize` 子命令由 `SpecFinalizeCommand.swift` 實作：
    1. Load state；若不存在 → no-op（防呆）。
    2. 取 postSnapshot via `SessionResolver.findScopedSessions`，與 state 存的 `preSessionSnapshot` diff → 推斷 `delegateSessionId`。
    3. Read progress jsonl → `completedSteps` + `inferFailedStep`（DI8）。
    4. 跑 `git diff --stat` / `git diff --name-only` → 填 `diffSummary` / `touchedFiles`。
    5. 依 exit code 填 `status`（0 → done / 非零 → failed / subprocess 被 SIGTERM(15) → aborted）、`completedAt = now`、`lastError = stderr_log tail`（若 fail）。
    6. Write state；exit 0（靜默）。
- **流程（DI1 + DI4 + DI5 + DI6 + DI8 + 上述 C1/C2/C3 設計）**：
  1. Resolve spec path（絕對 / 相對 CWD），檢查存在；不存在 → `specNotFound`。
  2. 讀 spec → `SpecAcceptanceParser.validateStructure(markdown:)`（T1 新增，靜態檢查四 heading）；缺任一 → throw 對應 L10n error（DI5 安全閥）。
  3. 決定 orrery session id：
     - `resumeSessionId` 非 nil → 驗證 `SpecRunStateStore.load(sessionId: resumeSessionId)` 成功；取 `state.delegateSessionId` 作為後續傳給 DelegateProcessBuilder 的 resume id。
     - `resumeSessionId` 為 nil → 生成新 `UUID().uuidString`，`delegateSessionId = nil`（fresh session）。
  4. 組 prompt：`SpecPromptExtractor.buildImplementPrompt(markdown:specPath:sessionId:progressLogPath:tokenBudget:)` 回傳字串（見 §5）。
  5. 寫／更新 state store：`SpecRunStateStore.write(sessionId:, state:)`，初始 `status="running"`, `startedAt=now`（resume 時保留舊 startedAt），`preSessionSnapshot = SessionResolver.findScopedSessions(...).map(\.id)`（作為 finalize 階段 diff 基準）。
  6. 建立 progress log path（`SpecRunStateStore.progressLogPath(sessionId:)`）與 stdout/stderr log path（`{id}.stdout.log` / `{id}.stderr.log`，同目錄）。
  7. 透過 `DelegateProcessBuilder(tool:, prompt:, resumeSessionId: delegateSessionId, environment:, store:)` 組出 delegate command array。用 `build(outputMode: .passthrough)` 拿 process — 但**不用**它的 process；只取它的 `arguments` / `environment` 組成 wrapper shell 要呼叫的 delegate command（見下）。
  8. 組 wrapper shell 字串（如上範例），其中 `{delegate_cmd_quoted}` 是 delegate command 用 `'...'` 單引號包起（含 shell-safe quoting）。
  9. 以 `Process` spawn `/bin/bash -c <wrapper>`：
     - 設 `process.standardInput = FileHandle.nullDevice`。
     - `watch == false`（C3：detached stdout/stderr 必須走檔案）：
       - `process.standardOutput = FileHandle.nullDevice`（wrapper 自己重導至 `{id}.stdout.log`）
       - `process.standardError = FileHandle.nullDevice`
     - `watch == true`：process standardOutput/Error 設 `FileHandle.standardOutput/standardError`（passthrough）。
     - 環境變數（透過 wrapper 組時已注入 `$ORRERY_SPEC_PROGRESS_LOG` / `$ORRERY_SPEC_SESSION_ID` / `$ORRERY_SPEC_PATH`）。
  10. **Transport-launch retry（DI2）**：包 `try process.run()` 於 do/catch；catch 到 POSIX launch errno（`EACCES` / `ENOENT` / `ETXTBSY` 等）且 state 檔尚未被 wrapper 寫入（檢查 stdout_log size == 0）→ 重建 process 再 run 一次；仍失敗 → throw `delegateLaunchFailed(stderr)` + state 寫 `status="failed"`。
  11. 分 watch / detached：
      - `watch == false`（預設，MCP 路徑）：spawn 完成後**立即 return** early-return `SpecRunResult(status:"running", ...)`。wrapper 與 delegate 繼續背景跑；orrery parent exit 不影響；wrapper 結束後自己呼 `_spec-finalize` 寫最終 state。
      - `watch == true`（CLI debug）：`process.waitUntilExit()`；然後 load 最新 state（_spec-finalize 已在 wrapper 內跑過）→ 回完整 shape。
  12. **overallTimeout 執行**：scheduleDispatchWorkItem(deadline: now + timeout, `process.terminate()`)；若觸發，wrapper 被 SIGTERM，bash 中斷；`_spec-finalize` 仍會在 bash 結束前透過 `trap` 呼叫並填 `blockedReason="overall timeout"`。
- **絕對不執行**：`swift build` / `swift test` / 任何 shell self-check（DI6：禁止 delegate 內部 self-check，但 `_spec-finalize` 內的 `git diff --stat` / `git diff --name-only` 是 passive 訊號收集，非 self-check）。
- **絕不 git commit / stash / reset**（D11 + D16 繼承）。
- **Session 行為（D9 繼承 + DI2 + C2）**：delegate resume id 永遠取自 `SpecRunState.delegateSessionId`，不直接接收 MCP 傳來的 UUID。

### 5. `SpecPromptExtractor`（T2）

**所在位置**：`Sources/OrreryCore/Spec/SpecPromptExtractor.swift`（新檔）

```swift
public struct SpecPromptExtractor {
    public static func extractInterfaceContract(markdown: String) throws -> String
    public static func extractAcceptance(markdown: String) throws -> String
    public static func buildImplementPrompt(
        markdown: String,
        specPath: String,
        sessionId: String,
        progressLogPath: String,
        tokenBudget: Int?
    ) throws -> String
}
```

- **`extractInterfaceContract` / `extractAcceptance`**：沿用 `SpecAcceptanceParser` 的 heading scan pattern，切出整段 markdown（**保留 fence / 表格 / 子標題原文**，非結構化 extraction）。找不到 → throw 對應 L10n error（DI5）。
- **`buildImplementPrompt` 輸出結構**（DI4 妥協版）：
  ```
  # 任務
  閱讀 spec 並實作所有改動檔案、實作步驟、不改動的部分、失敗路徑段落。

  # Spec 路徑
  <specPath>
  你可用 Read 工具讀完整 spec 以取得：改動檔案表、實作步驟、失敗路徑、不改動的部分。

  # 介面合約（必讀 inline）
  <extractInterfaceContract() 全文>

  # 驗收標準（停止條件）
  <extractAcceptance() 全文>

  # 進度回報協議
  每步邊界（進入 / 完成 / 跳過）請 append 一行 JSON 到 $ORRERY_SPEC_PROGRESS_LOG：
  {"ts":"<ISO8601>","step":"step-<N>","event":"start|done|skip","note":"<短描述>"}
  範例：{"ts":"2026-04-20T12:00:00Z","step":"step-1","event":"start","note":"create SpecPromptExtractor.swift"}

  # 約束
  - 禁止執行 git commit / push / reset / stash。
  - 禁止執行 swift build / swift test / 任何驗證指令（留給 orrery_spec_verify）。
  - 完成時輸出 structured summary：`## Touched files` 列表、`## Completed steps` 列表。
  - (若 tokenBudget 非 nil) 預估 token 預算：<tokenBudget>（僅 hint，未 enforce）
  ```
- Prompt 措辭細節（Q-impl-8）實作期可迭代；本 spec 只定輪廓。

### 6. `SpecProgressLog`（T3 + DI8）

**所在位置**：`Sources/OrreryCore/Spec/SpecProgressLog.swift`（新檔）

```swift
public struct SpecProgressLog {
    public struct Event: Codable, Equatable {
        public let ts: String          // ISO8601
        public let step: String
        public let event: String       // "start" | "done" | "skip"
        public let note: String?
    }

    public static func append(path: String, event: Event) throws
    public static func read(path: String) throws -> [Event]
    public static func inferFailedStep(events: [Event]) -> String?
    public static func completedSteps(events: [Event]) -> [String]
    public static func tail(path: String, lines: Int, since: String?) throws -> [String]
}
```

- **`inferFailedStep`**：掃 events，找最後一個 `event == "start"` 且**其後沒有**同 `step` 的 `done` / `skip` 事件者；沒有 → `nil`。
- **`completedSteps`**：回所有存在 `done` 事件的 step 名（保留順序）。
- **容錯（DI8）**：任何 parse error（壞 JSON 行）→ 該行**跳過**、**不**讓整體 fail；上層會把 fallback `failed_step = nil` + stderr 標註。
- **不使用 transcript parsing**（DI8 明確拒絕 (b)）。

### 7. `SpecRunStateStore`（T4 + DI7）

**所在位置**：`Sources/OrreryCore/Spec/SpecRunStateStore.swift`（新檔）

```swift
public struct SpecRunStateStore {
    public static let rootDir: URL  // = ~/.orrery/spec-runs/
    public static func statePath(sessionId: String) -> URL
    public static func progressLogPath(sessionId: String) -> URL

    public static func write(sessionId: String, state: SpecRunState) throws
    public static func update(sessionId: String, mutate: (inout SpecRunState) -> Void) throws
    public static func load(sessionId: String) throws -> SpecRunState
}

public struct SpecRunState: Codable {
    public var sessionId: String              // orrery UUID (our tracking id)
    public var delegateSessionId: String?     // C2: delegate's own session id (claude-code/codex/gemini native)
    public var preSessionSnapshot: [String]   // C1: scoped session ids captured before spawn, used by _spec-finalize to diff
    public var phase: String              // "implement"
    public var status: String             // running|done|failed|aborted
    public var startedAt: String
    public var updatedAt: String
    public var completedAt: String?
    public var completedSteps: [String]
    public var touchedFiles: [String]
    public var diffSummary: String?
    public var blockedReason: String?
    public var failedStep: String?
    public var childSessionIds: [String]  // DI3 reserve
    public var executionGraph: String?    // DI3 reserve
    public var lastError: String?
}
```

- **存放位置**：`~/.orrery/spec-runs/{session_id}.json`（**獨立新目錄**，不與 `~/.orrery/magi/` 混合；DI7）。
- **寫入策略**：每次 update 時 rewrite 整個 state JSON（覆寫，非 append）— 搭配 `updatedAt` 時間戳讓讀者判斷 freshness。MVP 不做 append-style journal；若未來需要 audit trail，再加 `.history.jsonl`。
- **Codable keys**：與 §2 / §3 output schema 對齊的 snake_case（透過 `CodingKeys` 顯式映射）。`delegateSessionId` → `"delegate_session_id"`, `preSessionSnapshot` → `"pre_session_snapshot"`。
- **C2 不暴露給 MCP**：`delegateSessionId` / `preSessionSnapshot` 為 orrery 內部 bookkeeping；**不**出現在 `orrery_spec_implement` 或 `orrery_spec_status` 的對外 output schema（§2 / §3）— 僅 SpecRunState 檔案持有。

### 8. `SpecAcceptanceParser.validateStructure`（T1 擴充，DI5）

**所在位置**：`Sources/OrreryCore/Spec/SpecAcceptanceParser.swift`（既有檔案擴充）

```swift
public extension SpecAcceptanceParser {
    /// Validates that the spec contains all four mandatory headings
    /// required by DI5 before an implement run can begin.
    static func validateStructure(markdown: String) throws
}
```

- 掃四 heading：`## 介面合約（Interface Contract）`（允許後綴 `（Interface Contract）` 或獨立 `## 介面合約` 或 `## Interface Contract`）、`## 改動檔案`（/ `## Changed Files`）、`## 實作步驟`（/ `## Implementation Steps`）、`## 驗收標準`（/ `## Acceptance Criteria`）。
- 缺任一 → throw 對應 L10n `ValidationError`；錯誤訊息建議：`"Spec is missing '<heading>' section — run orrery_spec_plan first or enrich the spec before implement"`（DI5 fail-fast 精神）。
- 不 double-validate `parse(markdown:)`（驗收指令解析仍沿用既有行為，只新增此輕量前置檢查）。

### 9. 依賴的既有契約（MVP 使用關係）

- `DelegateProcessBuilder`（既有 public API）— `SpecImplementRunner` 組 subprocess 的核心。MVP 不遷移至 `AgentExecutor` protocol（Magi extraction 後再統一）。
- `SessionResolver`（既有）— 若 MVP 需要做「有沒有既存 plan session」偵測，可複用；但 DI5 選 (c) fresh session，實務上不啟用。
- `EnvironmentStore` / `Tool` enum — 沿用 verify MVP 的注入方式。
- `MCPSetupCommand.installSlashCommands(projectDir:)`（T11）— 抄 `orrery:spec-verify.md` pattern 新增 `orrery:spec-implement.md` 與 `orrery:spec-status.md`。

## 改動檔案

| File Path | Change Description |
|---|---|
| `Sources/OrreryCore/Spec/SpecAcceptanceParser.swift` | 擴充 `validateStructure(markdown:)` 靜態檢查四 mandatory heading（T1 + DI5）。 |
| `Sources/OrreryCore/Spec/SpecPromptExtractor.swift` | 新增 prompt 建構器，提供 `extractInterfaceContract` / `extractAcceptance` / `buildImplementPrompt`（T2 + DI4）。 |
| `Sources/OrreryCore/Spec/SpecProgressLog.swift` | 新增 jsonl append / read / failed_step 推斷 helper（T3 + DI8）。 |
| `Sources/OrreryCore/Spec/SpecRunStateStore.swift` | 新增 `~/.orrery/spec-runs/{id}.json` 讀寫與 `SpecRunState` 型別；state 含 `delegateSessionId` / `preSessionSnapshot` 兩個內部欄位（C1/C2）（T4 + DI7）。 |
| `Sources/OrreryCore/Spec/SpecImplementRunner.swift` | 新增 implement phase 主 orchestrator：靜態檢查 → 寫初始 state（含 preSnapshot）→ 組 wrapper shell 字串 → spawn `/bin/bash -c <wrapper>` → early-return。不在 Swift 端等 delegate 結束，收尾由 `_spec-finalize` 子命令負責（C1）（T5 + DI1/DI2/DI6/DI8）。 |
| `Sources/OrreryCore/Spec/SpecFinalizeCommand.swift` | **新增隱藏子命令** `orrery _spec-finalize <session_id> <exit_code>`（前綴底線標註隱藏、`CommandConfiguration.shouldDisplay = false`）。由 wrapper shell 在 delegate 結束後呼叫：load state → postSnapshot diff 填 `delegateSessionId` → read progress jsonl → `git diff --stat` + `git diff --name-only` → 依 exit code 寫最終 `status`（C1 解法核心）。 |
| `Sources/OrreryCore/Spec/SpecRunResult.swift` | 擴充 `SpecRunResult` 新增 `status` / `startedAt` / `completedAt` / `touchedFiles` / `blockedReason` / `failedStep` / `childSessionIds` / `executionGraph` 欄位；新增 `SpecStatusResult` 型別；顯式 `encode(to:)` 包覆新 Optional 欄位以穩定 schema（T6 + DI6）。 |
| `Sources/OrreryCore/Spec/SpecRunCommand.swift` | 加 `--mode implement` / `--mode status` 分派；新增 `--session-id` / `--watch` flag；`--mode status` 純讀 `SpecRunStateStore`（T7 + T8）。 |
| `Sources/OrreryCore/Commands/OrreryCommand.swift` | **新增一條 subcommand 註冊**：`SpecFinalizeCommand.self`（即使 `shouldDisplay = false` 也必須註冊進 subcommands array，否則 `orrery _spec-finalize` 無法被 wrapper shell 呼叫）。原 `SpecRunCommand.self` 仍保留。 |
| `Sources/OrreryCore/MCP/MCPServer.swift` | `toolDefinitions()` 新增 `orrery_spec_implement` 與 `orrery_spec_status` 兩項；`callTool()` 對應 case 組 CLI args、呼 `execCommand`（T8 + T9 + DI1/DI7）。**不**暴露 `_spec-finalize` 為 MCP tool（僅 CLI 內部用）。 |
| `Sources/OrreryCore/Commands/MCPSetupCommand.swift` | `installSlashCommands(projectDir:)` 新增 `orrery:spec-implement.md` 與 `orrery:spec-status.md` 寫入段；success 訊息列出兩個新 tool（T11）。 |
| `.claude/commands/orrery:spec-implement.md` | 新增 slash command 定義（由 `orrery mcp setup` 寫入）；usage、flag 映射、結果摘要規範（T11）。 |
| `.claude/commands/orrery:spec-status.md` | 同上，針對 `orrery_spec_status` 的 polling 協議與 cadence 建議（T11）。 |
| `Sources/OrreryCore/Resources/Localization/en.json` | 新增 `specRun.missingInterfaceContractSection` / `missingChangedFilesSection` / `missingImplementationStepsSection` / `sessionIdRequired` / `sessionNotFound` / `delegateLaunchFailed` / `modeImplementRunning` / `modeStatusTail` 等鍵（T12）。 |
| `Sources/OrreryCore/Resources/Localization/zh-Hant.json` | 同上中文翻譯（T12）。 |
| `Sources/OrreryCore/Resources/Localization/ja.json` | 同上日文翻譯（T12）。 |
| `Sources/OrreryCore/Resources/Localization/l10n-signatures.json` | 由 L10nCodegen plugin 自動更新。 |
| `Tests/OrreryTests/SpecAcceptanceParserTests.swift` | 擴充 `validateStructure` 測試：四 heading 齊全 → 通過；缺任一 → throw 對應 key（T13）。 |
| `Tests/OrreryTests/SpecProgressLogTests.swift` | 新增：append/read/inferFailedStep/tail 單元測試；含壞行容錯（T13 + DI8）。 |
| `Tests/OrreryTests/SpecRunStateStoreTests.swift` | 新增：write/update/load 往返、rootDir 隔離、snake_case JSON 驗證（T13 + DI7）。 |
| `Tests/OrreryTests/SpecPromptExtractorTests.swift` | 新增：extractInterfaceContract / extractAcceptance / buildImplementPrompt 格式驗證（T13 + DI4）。 |
| `Tests/OrreryTests/SpecImplementRunnerTests.swift` | 新增：fixture spec → early-return shape、transport-launch retry 分支、watch 模式、childSessionIds/executionGraph 預留欄位空值 round-trip（T13 + DI1/DI2/DI3）。 |
| `Tests/OrreryTests/SpecRunStatusTests.swift` | 新增：`--mode status` 讀檔路徑、缺 session-id throws、sessionNotFound throws、running/done 兩態 `result` 欄位行為（T13 + DI7）。 |
| `Tests/OrreryTests/SpecImplementCommandTests.swift` | 新增：CLI 層級測試 `--mode implement` dry-flow、schema stability、mode-status reader、four-heading fail-fast（T13）。 |
| `CHANGELOG.md` | `## [Unreleased]` 加入 `orrery spec-run --mode implement|status` + `orrery_spec_implement` + `orrery_spec_status` MCP tools；同步 D13 pickup 並行第二階段公告（T14）。 |
| `Package.swift` | **不改**（Phase 1 新檔案集中於 `OrreryCore/Spec/`，延 D17）。 |

## 實作步驟

### Step 1 — `Sources/OrreryCore/Spec/SpecAcceptanceParser.swift`

1. 保留既有 `parse(markdown:)` 不變。
2. 新增 `public static func validateStructure(markdown: String) throws`。
3. 內部實作：以 `markdown.components(separatedBy: "\n")` 切行，對四個 required heading 各自掃描（allow both 中文與英文 variant，允許後綴括弧標註）：
   - `## 介面合約` / `## 介面合約（Interface Contract）` / `## Interface Contract`
   - `## 改動檔案` / `## Changed Files`
   - `## 實作步驟` / `## Implementation Steps`
   - `## 驗收標準` / `## Acceptance Criteria`
4. 任一缺少 → `throw ValidationError(L10n.SpecRun.missing<Xxx>Section)`（依順序先檢查先報）。
5. Unit test fixture：三份 markdown，分別缺 interface / changed-files / implementation steps；預期各自 throw 對應 key。

### Step 2 — `Sources/OrreryCore/Spec/SpecPromptExtractor.swift`（新檔）

1. 定義三個 static func 簽名如 §5。
2. `extractInterfaceContract(markdown:)`：掃到 `## 介面合約`（含 variant）的 heading line index → 起點為該 line；終點為下一個 `^##\s+` heading 的前一行（exclusive）；join 回字串。缺 heading → `throw ValidationError(L10n.SpecRun.missingInterfaceContractSection)`。
3. `extractAcceptance(markdown:)`：同 pattern，改找 `## 驗收標準`；缺 heading → throw 既有 `missingAcceptanceSection`。
4. `buildImplementPrompt(markdown:specPath:sessionId:progressLogPath:tokenBudget:)`：
   - 先呼 extractInterfaceContract / extractAcceptance 拿兩段（任一 throw 不吞）。
   - 以 §5 的模板字串插值拼接。
   - progressLogPath 以注入方式寫進 prompt 的「進度回報協議」段（prompt 文內直接 reference `$ORRERY_SPEC_PROGRESS_LOG`，subprocess 環境變數會設成此路徑）。
   - tokenBudget 為 nil → 略過 hint 段落。
5. Unit test：給定 fixture spec，驗證 prompt 包含「# 介面合約」與「# 驗收標準」兩段原文、包含 progressLogPath 引用、包含 禁止 git commit / swift build 兩條約束。

### Step 3 — `Sources/OrreryCore/Spec/SpecProgressLog.swift`（新檔）

1. 定義 `Event: Codable` 如 §6。
2. `append(path:event:)`：
   - 確保 parent directory 存在（`FileManager.createDirectory(at:withIntermediateDirectories:true)`）。
   - 序列化 event 為單行 JSON（no pretty print），尾加 `\n`。
   - Open file handle（append mode），write data，close。
3. `read(path:)`：
   - 檔案不存在 → 回 `[]`（**非 error**，fallback 路徑 DI8）。
   - 讀全檔 → split by `\n` → 每行 try `JSONDecoder.decode(Event.self, from:)`；**解析失敗的行 skip**，不 throw。
4. `inferFailedStep(events:)`：
   - 反向掃描 events。
   - 遇第一個 `event == "start"` 時，檢查 events 後續是否存在 `(step == x.step && (event == "done" || event == "skip"))`；存在則繼續找前一個 start；不存在 → 回 `x.step`。
   - 全部都有 done 對應 → `nil`。
5. `completedSteps(events:)`：filter `event == "done"` → map `step` → 保序。
6. `tail(path:lines:since:)`：
   - 讀全檔 → split by `\n`。
   - `since` 非 nil 時，先 filter 出 `events.ts > since` 的行（lexical compare ISO8601 可行）[inferred]。
   - 取最後 `lines` 行 → 回 string array（原始 JSON 行，不重序列化）。
7. Unit test：append 三筆 → read 回三筆、inferFailedStep 邏輯正確、壞行 skip 不影響 read、tail 取 N 行正確、since filter 正確。

### Step 4 — `Sources/OrreryCore/Spec/SpecRunStateStore.swift`（新檔）

1. 定義 `SpecRunState: Codable` 如 §7（所有欄位 snake_case via `CodingKeys`）。
2. `rootDir`：`URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".orrery/spec-runs", isDirectory: true)`。
3. `statePath(sessionId:)` / `progressLogPath(sessionId:)`：join rootDir 與 `{id}.json` / `{id}.progress.jsonl`。
4. `write(sessionId:state:)`：
   - 確保 rootDir 存在。
   - `JSONEncoder`（`.sortedKeys, .prettyPrinted`）serialize state。
   - 寫入 statePath（覆寫整檔）。
5. `update(sessionId:mutate:)`：
   - `load(sessionId:)` → `mutate(&state)` → 更新 `state.updatedAt = ISO8601` → `write`。
   - 檔案不存在 → throw `sessionNotFound(id)`。
6. `load(sessionId:)`：讀檔 → decode → 回；不存在 → throw。
7. Unit test：round-trip（write → load 還原）、update mutate 行為、rootDir 使用 temp HOME 環境變數隔離（`ProcessInfo.processInfo.environment["HOME"]` [inferred]）、JSON 驗證 snake_case 鍵、`child_session_ids` / `execution_graph` 預留空值 round-trip。

### Step 5 — `Sources/OrreryCore/Spec/SpecRunResult.swift`（擴充）

1. 對 `SpecRunResult` 新增欄位：
   ```swift
   public let status: String           // running|done|failed|aborted|pass|skipped_dry_run  // pass/skipped_dry_run 保留給 verify phase
   public let startedAt: String
   public let completedAt: String?
   public let touchedFiles: [String]
   public let blockedReason: String?
   public let failedStep: String?
   public let childSessionIds: [String]  // DI3 reserve
   public let executionGraph: String?    // DI3 reserve — encoded JSON string; nil for MVP
   ```
2. 更新 `CodingKeys` 加入所有新欄位的 snake_case 映射。
3. 更新 `encode(to:)` 把所有 Optional 欄位顯式 `try c.encode(value, forKey: .x)`（令 nil 序列化為 `null`）。
4. 更新 `errorShell(phase:error:)` 讓 `status = "failed"`, `startedAt = now`, `completedAt = now`, 其他陣列欄位為 `[]`。
5. **Backward compat for verify（H4 修正）**：verify MVP 既有呼叫點（`SpecRunCommand.swift` verify case、`SpecVerifyRunner` 等）目前**不**產生新欄位。兩條路線：
   - **a. 擴 memberwise init 並在 verify runner 補上新欄位預設值**：`status = "done"`（或 dry-run 時 `"skipped_dry_run"`）、`startedAt / completedAt = now` 字串、`touchedFiles = []`、其餘 Optional = nil、陣列 = []。**本 spec 採此方案**。
   - b. 加靜態 factory `SpecRunResult.verify(...)` 包裝預設 — 不採用，因需改既有 call site 且沒有實質好處。
   **動作**：修改 `SpecVerifyRunner.swift`（verify MVP 既有檔）的 `SpecRunResult(...)` 建構呼叫，補入新欄位的預設值；既有 verify tests（`SpecRunCommandTests` 的 4 個 testcase）需同步更新 assertion 以接受新欄位出現（預期 null/空陣列）。
6. 新增 `SpecStatusResult: Encodable`（含 §3 output schema 所有欄位 + explicit `encode(to:)`）。
7. 為 `SpecStatusResult` 提供 `static func from(state: SpecRunState, logTail: [String]) -> SpecStatusResult` 便利建構子；`from` 當 `state.status != "running"` 時 `result` 填 `SpecRunResult.fromState(state)`（新增的另一個 factory），否則 `result = nil`。
8. Unit test：encode → decode 對稱、null fields 出現於 JSON 而非省略；verify MVP 既有 output 仍含新增欄位但語意穩定。

### Step 6 — `Sources/OrreryCore/Spec/SpecImplementRunner.swift`（新檔）

1. 簽名如 §4。
2. 解析 spec path → 驗證存在 → 讀 markdown。
3. 呼 `SpecAcceptanceParser.validateStructure(markdown:)`（缺 heading 即 throw，DI5 安全閥）。
4. **Resolve session id 與 delegate resume id（C2 + G8）**：
   ```swift
   let sessionId: String
   let delegateResumeId: String?
   if let orreryResumeId = resumeSessionId {
       let prior = try SpecRunStateStore.load(sessionId: orreryResumeId)
       sessionId = orreryResumeId
       delegateResumeId = prior.delegateSessionId  // 可能 nil（初次 launch 失敗前未捕獲）

       // G8: resume 時若 delegate session 從未被捕獲（例如初次啟動 transport fail），
       // 必須明示 client "formally resumed orrery session, but delegate starts fresh"，
       // 避免靜默降級讓使用者誤以為 delegate context 有被延續。
       if delegateResumeId == nil {
           FileHandle.standardError.write(Data(
               ("resume_session_id=\\(orreryResumeId) provided but delegate_session_id "
                + "was never captured (likely prior run failed before delegate spawned); "
                + "starting fresh delegate session.\\n").utf8
           ))
       }
   } else {
       sessionId = UUID().uuidString
       delegateResumeId = nil
   }
   ```
5. `let progressLogPath = SpecRunStateStore.progressLogPath(sessionId: sessionId).path`；其 parent directory 由 StateStore 保證存在。
6. Build prompt：`try SpecPromptExtractor.buildImplementPrompt(markdown: md, specPath: resolvedPath, sessionId: sessionId, progressLogPath: progressLogPath, tokenBudget: tokenBudget)`。
7. **捕獲 preSnapshot 並寫初始 state**：
   ```swift
   let preSnapshot = SessionResolver.findScopedSessions(
       tool: resolvedTool, cwd: FileManager.default.currentDirectoryPath,
       store: store, activeEnvironment: environment
   ).map(\.id)

   var state = (try? SpecRunStateStore.load(sessionId: sessionId)) ?? SpecRunState.initial(sessionId: sessionId)
   state.status = "running"
   state.startedAt = state.startedAt.isEmpty ? ISO8601DateFormatter().string(from: Date()) : state.startedAt
   state.updatedAt = ISO8601DateFormatter().string(from: Date())
   state.preSessionSnapshot = preSnapshot
   state.delegateSessionId = delegateResumeId  // 若 resume，保留舊值；fresh 則 nil
   try SpecRunStateStore.write(sessionId: sessionId, state: state)
   ```
8. **取 delegate command array（但不跑 DelegateProcessBuilder 的 process）**：
   ```swift
   let builder = DelegateProcessBuilder(
       tool: resolvedTool, prompt: prompt,
       resumeSessionId: delegateResumeId,
       environment: environment, store: store
   )
   let (internalProcess, _, _) = try builder.build(outputMode: .passthrough)
   let delegateArgs = internalProcess.arguments ?? []  // e.g. ["claude", "-p", "--resume", "...", ...]
   let delegateEnv = internalProcess.environment ?? [:]
   ```
   然後不用 `internalProcess` 本身（它只是個 scratch instance）。
9. **組 wrapper shell 字串**（C1 核心 + G1 timeout + G3 絕對路徑）：
   ```swift
   let stdoutLog = SpecRunStateStore.stdoutLogPath(sessionId: sessionId).path
   let stderrLog = SpecRunStateStore.stderrLogPath(sessionId: sessionId).path

   // G3: arguments[0] 可能是相對路徑（e.g. swift run → ".build/debug/orrery"）；
   // wrapper 在 subprocess 裡執行時 cwd 可能不同，必須展開成絕對路徑。
   let rawArg0 = ProcessInfo.processInfo.arguments[0]
   let orreryBin: String
   if rawArg0.hasPrefix("/") {
       orreryBin = rawArg0
   } else {
       // 先解析相對 cwd
       let resolved = URL(fileURLWithPath: rawArg0,
                          relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
           .standardizedFileURL.path
       // 若解析後仍不是真實檔案（例如 rawArg0 就是 "orrery" 靠 PATH），就靠 PATH 繼承給 wrapper
       orreryBin = FileManager.default.isExecutableFile(atPath: resolved) ? resolved : "orrery"
   }

   let cmdQuoted = delegateArgs.map { shellQuote($0) }.joined(separator: " ")
   let timeoutSec = Int(overallTimeout)  // G1：注意 0/負值時省略 watchdog 行（見下）
   let watchdogBlock = timeoutSec > 0 ? """
   ( sleep \(timeoutSec) && kill -TERM $DELEGATE_PID 2>/dev/null ) &
   WATCHDOG_PID=$!
   """ : ""
   let watchdogCleanup = timeoutSec > 0 ? "kill $WATCHDOG_PID 2>/dev/null || true" : ""

   let wrapper = """
   \(cmdQuoted) </dev/null >>"\(stdoutLog)" 2>>"\(stderrLog)" &
   DELEGATE_PID=$!
   \(watchdogBlock)
   wait $DELEGATE_PID
   RC=$?
   \(watchdogCleanup)
   "\(orreryBin)" _spec-finalize "\(sessionId)" "$RC" </dev/null >/dev/null 2>&1 || true
   """
   ```
   `shellQuote` helper：以單引號包住並 escape 內嵌單引號（classic `'` → `'\''`）。
10. **Spawn wrapper**：
    ```swift
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", wrapper]
    process.environment = delegateEnv.merging([
        "ORRERY_SPEC_PROGRESS_LOG": progressLogPath,
        "ORRERY_SPEC_SESSION_ID": sessionId,
        "ORRERY_SPEC_PATH": resolvedPath,
        "ORRERY_SPEC_TOOL": resolvedTool.rawValue    // G2: finalize 用它決定 SessionResolver tool
    ], uniquingKeysWith: { _, new in new })
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = watch ? FileHandle.standardOutput : FileHandle.nullDevice
    process.standardError  = watch ? FileHandle.standardError  : FileHandle.nullDevice
    ```
11. **Transport-launch retry（DI2）**：
    ```swift
    do {
        try process.run()
    } catch let error as NSError {
        let launchErrnos: Set<Int32> = [EACCES, ENOENT, ETXTBSY]
        let isLaunchErrno = launchErrnos.contains(Int32(error.code))
        let wrapperUntouched = (try? FileManager.default.attributesOfItem(atPath: stdoutLog)[.size] as? Int) ?? 0 == 0
        guard isLaunchErrno && wrapperUntouched else { throw error }
        // retry once
        try process.run()
    }
    ```
    （若第二次仍拋 → 不被 catch，直接傳到 Runner 外層 catch，轉為 `delegateLaunchFailed(stderr)`。）
12. **分 watch / detached**：
    - `watch == true`：`process.waitUntilExit()` → load state（此時 `_spec-finalize` 已被 wrapper 呼叫寫好）→ 回完整 `SpecRunResult`。
    - `watch == false`：spawn 後**立即** `return SpecRunResult.implementEarlyReturn(sessionId:, startedAt: state.startedAt)`；wrapper 與 delegate 繼續跑；orrery parent 可以安全 exit。
13. **timeout**：只在 `watch == true` 時 schedule DispatchWorkItem `process.terminate()`；detached 模式下 timeout 靠 wrapper 內部的 `timeout` 命令或 `ulimit` 實作 — **MVP 暫不實作 detached timeout**（留 Q-impl-timeout follow-up：detached 的 timeout 需要 wrapper bash 用 `( cmd ) & pid=$!; sleep N; kill $pid` pattern）。
14. **失敗路徑**：Runner 階段任何 throw 前都呼 `SpecRunStateStore.update(sessionId:) { $0.status = "failed"; $0.lastError = ... }`。
15. Unit test：
    - Fixture spec pass → early-return shape 欄位齊全、statePath 檔案已建、`delegateSessionId == nil`、`preSessionSnapshot` 非 nil。
    - 缺 heading → validateStructure throws、無 subprocess 啟動、state 檔未建立。
    - Transport retry：用 mock `DelegateProcessBuilder`（或 test-only seam）第一次拋 `POSIXError(.EACCES)` → 第二次成功；第二次失敗 → throw `delegateLaunchFailed`。
    - `watch: true` + fake delegate（wrapper 中 delegate 部份改成 `echo done` + `true` 快速退出）→ `_spec-finalize` 被呼叫 → load state `status == "done"`。
    - Resume：先 `write` 一個 state 帶 `delegateSessionId = "fake-delegate-id"`；再以 `resumeSessionId = <uuid>` 呼 `run(...)` → 檢查 built delegate command contains `"--resume", "fake-delegate-id"`。

### Step 6b — `Sources/OrreryCore/Spec/SpecFinalizeCommand.swift`（新檔，C1 核心）

1. 定義 `public struct SpecFinalizeCommand: ParsableCommand` with：
   ```swift
   public static let configuration = CommandConfiguration(
       commandName: "_spec-finalize",
       abstract: L10n.SpecRun.finalizeAbstract,
       shouldDisplay: false   // 不出現在 help 裡
   )

   @Argument public var sessionId: String
   @Argument public var exitCode: Int32
   ```
2. `run()` 邏輯：
   1. Load state；若不存在 → 立即 exit 0（防呆，避免 finalize 對空 session 爆掉）。
   1b. **Idempotency 檢查（G5）**：若 `state.status` 已是 terminal（`"done"` / `"failed"` / `"aborted"`）→ stderr 標註 `finalize called twice for session=<id>; state already <status>, skipping` → exit 0。防止被意外重複呼叫時覆寫 preSnapshot 已 stale 的 state。
   2. 從 state 取 `preSessionSnapshot`；若為空 array → 跳過 delegate session diff（fallback：`delegateSessionId` 留 nil）。
   3. 取 postSnapshot via `SessionResolver.findScopedSessions(tool:, cwd: FileManager.default.currentDirectoryPath, store: .default, activeEnvironment: ORRERY_ACTIVE_ENV env)`；tool 從 delegate command prefix 推斷（`claude` / `codex` / `gemini`）或從 `ORRERY_SPEC_TOOL` env var 取得（由 wrapper 注入）。
   4. `diff = Set(post) - Set(pre)`；若 diff.count == 1 → 填 `state.delegateSessionId`；其他 → 留 nil 並 stderr 標註 ambiguous。
   5. `SpecProgressLog.read(path: progressLogPath)` → `completedSteps` + `inferFailedStep`。
   6. 跑 `git diff --stat` （`/usr/bin/env git diff --stat`，取 stdout）填 `diffSummary`；跑 `git diff --name-only` 拆成 `touchedFiles: [String]`。
   7. 依 `exitCode` 填 `state.status`：
      - `0` → `"done"`
      - `143`（SIGTERM）或 state 有 `blockedReason == "overall timeout"` → `"aborted"`
      - 其他 → `"failed"` + `lastError = tail(stderr_log, 2000 bytes)`。
   8. `state.completedAt = ISO8601.now`；`state.updatedAt = now`。
   9. `SpecRunStateStore.write(sessionId:, state:)`；exit 0。
3. **永遠不 throw 到 parent**：finalize 的目的是清理，任何內部錯誤應吞掉 + stderr 標註、exit 0（因為沒人會讀 wrapper 的 exit code）。
4. Unit test：建 fake state 檔 + fake progress jsonl → 呼 finalize → 驗證 state.status / completedSteps / failedStep / touchedFiles 正確。

### Step 7 — `Sources/OrreryCore/Spec/SpecRunCommand.swift`（擴充）

1. 新增 `@Option(name: .long) public var sessionId: String?`、`@Flag(name: .long) public var watch: Bool = false`。
2. `run()` mode switch 擴充：
   ```swift
   switch mode {
   case "verify": /* 既有 */
   case "implement":
       let toolEnum = try Tool.parse(tool)
       let result = try SpecImplementRunner.run(
           specPath: specPath, tool: toolEnum, environment: environment,
           store: .default, resumeSessionId: resumeSessionId,
           overallTimeout: TimeInterval(timeout ?? 3600),
           tokenBudget: nil, watch: watch
       )
       print(try result.toJSONString())
       // exit code: early-return 永遠 0；watch 模式依 result.status
   case "status":
       guard let id = sessionId else {
           throw ValidationError(L10n.SpecRun.sessionIdRequired)
       }
       let state = try SpecRunStateStore.load(sessionId: id)
       let log = includeLog ? try SpecProgressLog.tail(path: SpecRunStateStore.progressLogPath(sessionId: id).path, lines: 50, since: nil) : []
       let result = SpecStatusResult.from(state: state, logTail: log)
       print(try result.toJSONString())
   case "plan", "run":
       throw ValidationError(L10n.SpecRun.modeNotImplemented(mode))
   default:
       throw ValidationError(L10n.SpecRun.invalidMode(mode))
   }
   ```
3. 新增 `@Flag public var includeLog: Bool = false`、`@Option public var sinceTimestamp: String?` 供 `--mode status` 使用 [inferred]。
4. catch ValidationError → 用 `SpecRunResult.errorShell(phase: mode == "status" ? "status" : mode, error: msg)` 印完整 schema JSON，throw 讓 ArgumentParser 設非零 exit。
5. Unit test：CLI 層級測試（見 `SpecImplementCommandTests`）。

### Step 7b — `Sources/OrreryCore/Commands/OrreryCommand.swift`（註冊隱藏子命令）

1. 在 `subcommands` array 加入 `SpecFinalizeCommand.self`（位置可放在 `SpecRunCommand.self` 之後）。
2. 即便 `SpecFinalizeCommand.configuration.shouldDisplay = false`，仍需**明確註冊進 subcommands**，否則 `orrery _spec-finalize ...` 無法被 ArgumentParser 派發、wrapper shell 會得到「unknown command」而 finalize 不會執行。
3. 不新增任何其他 subcommand；`orrery --help` 輸出的命令清單不變（因 `shouldDisplay: false`）。

### Step 8 — `Sources/OrreryCore/MCP/MCPServer.swift`（擴充）

1. `toolDefinitions()` 於 `orrery_spec_verify` 後新增兩項：
   - `orrery_spec_implement`（description: `"Run the implement phase: spawn a delegate agent to write code per the spec. Returns immediately with a session_id; use orrery_spec_status to poll."`，input schema 見 §2）。
   - `orrery_spec_status`（description: `"Poll status of a running orrery_spec_implement session. Recommended polling cadence: first 2s, then exponential backoff min(30s, prev*1.5); after 5min settle at 30s."`，input schema 見 §3）。
2. `callTool(name:arguments:)` 新增兩 case：
   - `orrery_spec_implement`：
     - 取 `spec_path`（缺 → `toolError("Missing required parameter: spec_path")`）。
     - 組 `args = ["orrery", "spec-run", "--mode", "implement", spec_path]` + 依 args 加 `--tool` / `--environment` / `--timeout` / `--resume-session-id`。
     - `execCommand(args)` → 回 CLI stdout（already JSON）。
   - `orrery_spec_status`：
     - 取 `session_id`（缺 → `toolError(L10n.SpecRun.sessionIdRequired)`）。
     - 組 `args = ["orrery", "spec-run", "--mode", "status", "--session-id", id]` + `include_log` / `since_timestamp` 映射。
     - `execCommand(args)` → 回 stdout。
3. **不**暴露 `_spec-finalize` 為 MCP tool（僅 CLI / wrapper shell 內部用）。
4. 沿用 verify MVP 修訂後的 `execCommand` exit-非零路徑（優先回 stdout）— 不動 `execCommand` 本身。

### Step 9 — `Sources/OrreryCore/Commands/MCPSetupCommand.swift`（擴充）

1. `installSlashCommands(projectDir:)` 於 `orrery:spec-verify.md` 寫入段後新增兩段寫入（抄 verify MVP pattern）：
   - `orrery:spec-implement.md`：列 usage、`--tool` / `--environment` / `--resume-session-id` / `--timeout` 對應，範例「若任務 >1min 立即 poll `orrery_spec_status`」，結果摘要規範（session_id、status、diff_summary、failed_step）。
   - `orrery:spec-status.md`：列 usage，polling cadence 明示，`include_log=true` 時摘要 tail。
2. Success 訊息最後列出三個新 spec tool 可用：`orrery_spec_verify`, `orrery_spec_implement`, `orrery_spec_status`。

### Step 10 — Localization（T12）

1. 三 `*.json` 新增鍵（English 參考字串）：
   - `specRun.missingInterfaceContractSection`: `"Spec is missing the '## 介面合約' section — enrich the spec or run orrery_spec_plan first"`
   - `specRun.missingChangedFilesSection`: `"Spec is missing the '## 改動檔案' section"`
   - `specRun.missingImplementationStepsSection`: `"Spec is missing the '## 實作步驟' section"`
   - `specRun.sessionIdRequired`: `"--mode status requires --session-id"`
   - `specRun.sessionNotFound`: `"Spec-run session not found: {id}"`
   - `specRun.delegateLaunchFailed`: `"Delegate subprocess failed to launch after retry: {stderr}"`
   - `specRun.modeImplementRunning`: `"implement phase started; poll orrery_spec_status with session_id={id}"`
2. 同步 `mCPSetup.success` 訊息加入 implement / status tool 提示（三語同步）。
3. 不手改 `l10n-signatures.json`；plugin 在 `swift build` 時重生。

### Step 11 — Tests（T13）

依 §改動檔案 table 新增 6 個 test 檔案，覆蓋：parser validate、progress log（含壞行容錯）、state store（round-trip + rootDir 隔離）、prompt extractor（含介面合約 / 驗收標準兩段原文 + 約束段）、implement runner（early-return / watch / transport retry / 預留欄位）、status command（缺 id / 不存在 / running / done）、implement command CLI 層（mode 分派 / schema stability / four-heading fail-fast）。

### Step 12 — CHANGELOG（T14）

1. `## [Unreleased] - Added`：
   - `orrery spec-run --mode implement`（early-return + detached delegate subprocess）
   - `orrery spec-run --mode status --session-id <id>`
   - `orrery_spec_implement` / `orrery_spec_status` MCP tools
2. `## [Unreleased] - Notes`：
   - DI3 預留 `child_session_ids` / `execution_graph` schema，runtime 尚未使用；未來並行觸發條件為 plan phase 能明確標註 dependency + file ownership。
   - DI9：暫不實作 lightweight plan；若未來新增需 schema 與 `orrery_spec_plan` 一致並加 `plan_source` 欄位。
   - D13 pickup 並行第二階段公告：推薦使用 `orrery_spec_implement` MCP tool；後續 +1 release 對 pickup skill 加 `@deprecated` 提示。
3. **不**動版本字串（保持 release 階段一次 bump）。

## 失敗路徑

1. **Spec 檔不存在** → `SpecImplementRunner.run` 偵測 → `throw ValidationError(L10n.SpecRun.specNotFound)` → CLI catch 印 `errorShell` JSON 後 throw → ArgumentParser 非零 exit；MCP `callTool` 收到非零 exit → 回 `toolError(stderr)`。**不可恢復**。
2. **Spec 缺四 mandatory heading 任一**（DI5 安全閥）→ `SpecAcceptanceParser.validateStructure` throw 對應 `missing<Xxx>Section` → 同上路徑；error message 指示「先跑 `orrery_spec_plan` 或補齊 spec」。**不可恢復**。
3. **Delegate subprocess launch failure（transport-level）** → `SpecImplementRunner` 捕捉 → auto-retry 一次（DI2）；若第二次仍失敗且尚未寫入任何 progress log → throw `delegateLaunchFailed(stderr)`；狀態檔 `status = "failed"`, `lastError = stderr`。**可恢復**（使用者可 `--resume-session-id <id>` 重試）。
4. **Delegate 執行中錯誤（semantic failure）** — 例如 compile error、agent 放棄、spec 語意與 code 不匹配：delegate subprocess exit 非零；terminationHandler 寫 state `status = "failed"`, `failedStep = <inferFailedStep>`, `lastError = <subprocess stderr tail>`；**不 auto-retry**（DI2 明文拒絕）；使用者透過 `orrery_spec_status` 看 `failed_step` + `log_tail` 判斷後手動 `resume_session_id` 或修 spec。**可恢復（手動）**。
5. **Overall timeout**（預設 3600s）→ `SpecImplementRunner` 的 timer `process.terminate()` → terminationHandler 看到 non-zero + 時間已過 → state `status = "aborted"`, `blockedReason = "overall timeout"`。**可恢復（手動）**。
6. **Progress log 檔案壞／空**（DI8 fallback）→ `SpecProgressLog.read` skip 壞行；`inferFailedStep` 回 `nil`；state 欄位 `failedStep = null` + stderr tail 標註「progress log empty/corrupted; failed_step unknown」；**tool 不 fail**，整體 status 仍依 subprocess exit code 判斷。**非錯誤，劣化輸出**。
7. **MCP client 在 implement 跑完前重複呼叫 `orrery_spec_implement`（同 session_id）** → `DelegateProcessBuilder` 轉傳 `--resume-session-id`；claude-code / codex 走 native resume。若未帶 resume id → 會開新 session（新 UUID），舊 subprocess 仍背景執行（使用者需自行 clean，Q-impl-9 未解，寫入 CHANGELOG caveat）。**可恢復**。
8. **`orrery_spec_status` 對不存在 session_id** → `SpecRunStateStore.load` throw `sessionNotFound` → CLI errorShell → MCP `toolError`。**不可恢復**。
9. **Delegate 違反「禁止 git commit / push / reset」約束**（DI6 + D16）→ MVP 無法強制攔截（delegate 有自己的 Bash 權限）；靠 prompt 約束 + state 收尾時 `git diff --stat` 觀察到非預期變動可由使用者在 review 階段察覺；**不自動 rollback**（D11）；若未來需要可考慮用 git hook 作旁路，非本 MVP 範疇。**可恢復（人工）**。
10. **Transport-retry 後 state 檔已部分寫入**（DI2 明文的「尚未寫入任何檔案」判定失敗）→ 為安全起見保守不 retry，直接 throw `delegateLaunchFailed`；使用者以 `--resume-session-id` 手動接續（state 檔已存在則 update，不 overwrite 初始）。**可恢復（手動）**。

## 不改動的部分

- `Sources/OrreryCore/Spec/SpecCommand.swift`、`SpecGenerator.swift`、`SpecPromptBuilder.swift`、`SpecProfileResolver.swift`、`SpecTemplate.swift` — `orrery_spec` 的「discussion → spec」契約不變（繼承自 2026-04-18 discussion 的範圍約束）。
- `Sources/OrreryCore/Spec/SpecVerifyRunner.swift` / `SpecSandboxPolicy.swift` — verify MVP 行為完全保留；implement 與 verify 為獨立 runner（D4 phase 邊界）。
- `Sources/OrreryCore/Magi/*` — 不改（本 MVP 不觸發 Magi review）。
- `Sources/OrreryCore/Helpers/DelegateProcessBuilder.swift` — 不改（既有 public API 直接使用）。
- `Sources/OrreryCore/Helpers/SessionResolver.swift` — 不改（MVP 沿用，plan session diff 判定保留給後續）。
- `Sources/OrreryCore/Commands/DelegateCommand.swift` / `Commands/SessionsCommand.swift` — 不改。
- `Sources/OrreryCore/Commands/OrreryCommand.swift` — 不改（`SpecRunCommand` 在 verify MVP 已註冊）[inferred]。
- `Package.swift` — 不改（Phase 1 新檔案集中於 `OrreryCore/Spec/`，D17 批次搬遷延至 Magi extraction 時機；**禁止**散落 `OrreryCore` 其他子目錄）。
- `Sources/OrreryCore/Version.swift`、`docs/index.html`、`docs/zh_TW.html` — 版本字串本案不動，留待 release 階段統一 bump（CLAUDE.md 約束）。
- `pickup` skill 程式碼 — 不改；只在 CHANGELOG 公告 D13 第二階段並行指引，行為不分叉。
- 既有 `orrery_spec` / `orrery_spec_verify` MCP tool 的 input/output schema — 不修改。
- **隱性行為注意**：
  - `SpecRunResult` 新增欄位後，既有 verify phase 輸出 JSON 會**多出** `status` / `started_at` / `completed_at` / `touched_files` / `blocked_reason` / `failed_step` / `child_session_ids` / `execution_graph` 等欄位（填合理預設）；既有 MCP client 若以嚴格 schema decoding 可能 warn — 建議 CHANGELOG 註記 verify JSON 形狀擴充但不破壞向下相容（既有欄位仍存在）。
  - `~/.orrery/spec-runs/` 為**新目錄**，不與 `~/.orrery/magi/` 共用；MVP 不提供自動 GC — 狀態檔會永久累積（未來 release 需加 retention policy）。
  - 同目錄下的 `{id}.stdout.log` / `{id}.stderr.log`（G7）**同樣無 retention** — 長跑 delegate 可能累積 MB 級 log、而且 MVP 也**無 log size cap**（wrapper 的 `>>` append 不截斷）。未來 release 需一併加 log size cap（例如單檔 10MB 環狀）與 age-based GC。使用者目前可手動 `tail -c 1M` / `rm ~/.orrery/spec-runs/*.log`。
  - Detached subprocess 的 PID 持久化與孤兒清理（Q-impl-9）本 MVP 不處理；OS 重啟後使用者需自行清理殘留 process。

## 驗收標準

### Functional contract checklist

- [ ] `orrery spec-run --mode implement <spec>` 對含四 mandatory heading（介面合約 / 改動檔案 / 實作步驟 / 驗收標準）的 spec，**立即 early-return**（5s 內）印完整 schema JSON：`status=="running"`、`session_id != null`、`started_at` 為 ISO8601、`completed_steps==[]`、`touched_files==[]`、`child_session_ids==[]`、`execution_graph==null`、`error==null`；exit 0。
- [ ] `orrery spec-run --mode implement <spec>` 對缺「## 介面合約」段的 spec，立即 throw、stdout 印 `errorShell` schema JSON（`error` 填 `missingInterfaceContractSection` 訊息）、exit 非零、**未**啟動任何 subprocess、未寫入 `~/.orrery/spec-runs/` 任何檔案。
- [ ] 同上，分別對缺「## 改動檔案」/「## 實作步驟」/「## 驗收標準」三份 fixture spec 驗證 throw 對應 L10n key。
- [ ] `orrery spec-run --mode implement <spec> --watch` 能 block 至 delegate subprocess 結束，最終 `status ∈ {"done","failed","aborted"}`、`completed_at != null`、`diff_summary != null`（可能為空字串）、`touched_files` 為 `git diff --name-only` 結果陣列。
- [ ] `orrery spec-run --mode status --session-id <id>` 對已啟動 session 讀 `~/.orrery/spec-runs/{id}.json`，回 `SpecStatusResult` JSON；`status=="running"` 時 `result==null`；`status != "running"` 時 `result` 為完整 `SpecRunResult`。
- [ ] `orrery spec-run --mode status` 不帶 `--session-id` → throw `sessionIdRequired`、印 errorShell JSON、exit 非零。
- [ ] `orrery spec-run --mode status --session-id <不存在 id>` → throw `sessionNotFound`、印 errorShell JSON、exit 非零。
- [ ] `orrery spec-run --mode status --session-id <id> --include-log` 回 `log_tail` 為 progress jsonl 最後 ≤ 50 行原始字串；`--since-timestamp` 過濾出之後事件。
- [ ] Progress log 為空 / 壞行時，`SpecStatusResult.progress` 的 `current_step` / `total_steps` 皆為 `null`、`failed_step == null` + stderr 含「progress log empty/corrupted」警告；**tool 本身不 fail**。
- [ ] `orrery spec-run --mode implement --resume-session-id <existing id>` 讓 delegate 以 resume session 跑（claude-code `--resume` / codex `resume` / gemini `--resume`）；state 檔以 update 而非 overwrite 方式寫入（`started_at` 保留舊值）。
- [ ] Transport-launch fail auto-retry：mock/fake Process 第一次 run 拋 launch error → 第二次成功 → 整體完成（DI2 唯一例外）；第二次仍失敗 → throw `delegateLaunchFailed`。
- [ ] Semantic failure 情境（delegate subprocess 非零 exit）→ **不 auto-retry**、`status == "failed"`、`failed_step` 由 progress jsonl 最後 `start` 無 `done` 對應推斷、`last_error` 填 subprocess stderr tail。
- [ ] Overall timeout 觸發時 `process.terminate()` → `status == "aborted"`、`blocked_reason == "overall timeout"`。
- [ ] Prompt 內容包含「# 介面合約」與「# 驗收標準」兩段**完整原文**（以 fixture spec 驗證 substring contains）；包含 `$ORRERY_SPEC_PROGRESS_LOG` 引用；包含禁止 git commit / swift build / swift test 三條約束字串。
- [ ] `SpecImplementRunner` **不**在任何路徑執行 `swift build` / `swift test` / 其他驗證 shell（DI6）；僅在收尾執行 `git diff --stat` / `git diff --name-only` 兩個 passive 指令填 state。
- [ ] `SpecImplementRunner` **不**執行 `git commit` / `git push` / `git reset` / `git stash` / `git checkout` 任何破壞性 git 指令（D11 + D16）。
- [ ] JSON 所有欄位以 **snake_case** 序列化（`session_id`、`started_at`、`completed_at`、`completed_steps`、`touched_files`、`blocked_reason`、`failed_step`、`child_session_ids`、`execution_graph`、`last_error`、`log_tail`、`current_step`、`total_steps` 等）。
- [ ] `SpecRunResult.encode(to:)` / `SpecStatusResult.encode(to:)` 對所有 Optional 欄位顯式 encode → null 欄位以 JSON `null` 顯式出現、**非省略**（schema stability）。
- [ ] `orrery_spec_implement` 與 `orrery_spec_status` 出現在 MCP `tools/list` 結果中、input schema 與 §2 / §3 一致；tool description 含 polling cadence 建議。
- [ ] 透過 MCP client 呼叫 `orrery_spec_implement` 並傳 `spec_path` 即可啟動 delegate、回 `{session_id, status:"running", ...}`；隨後呼 `orrery_spec_status` 取狀態即可（CLI stdout 與 MCP response 同形）。
- [ ] `MCPSetupCommand.installSlashCommands(projectDir:)` 寫入 `orrery:spec-implement.md` 與 `orrery:spec-status.md` 兩個 slash command 檔到 `.claude/commands/`；`orrery mcp setup` 後 `test -f .claude/commands/orrery:spec-implement.md` 成立，內容提及 polling cadence。
- [ ] `Tests/OrreryTests` 六個新／擴充 test 檔皆通過（`SpecAcceptanceParserTests` / `SpecProgressLogTests` / `SpecRunStateStoreTests` / `SpecPromptExtractorTests` / `SpecImplementRunnerTests` / `SpecRunStatusTests` / `SpecImplementCommandTests`）；既有 verify 測試仍通過。
- [ ] L10n 三語檔 `specRun.*` 新鍵齊全（含 `missingInterfaceContractSection` / `missingChangedFilesSection` / `missingImplementationStepsSection` / `sessionIdRequired` / `sessionNotFound` / `delegateLaunchFailed` / `modeImplementRunning`），`swift build` 後 `l10n-signatures.json` 自動更新且無 warning。
- [ ] `CHANGELOG.md` 含 `orrery spec-run --mode implement|status`、`orrery_spec_implement`、`orrery_spec_status` 三條 Added 條目；Notes 段含 DI3 預留欄位、DI9 lightweight plan 不實作、D13 pickup 第二階段並行公告；版本字串未變動。
- [ ] `Sources/OrreryCore/Spec/` 下新增的 5 個 .swift 檔（`SpecPromptExtractor` / `SpecProgressLog` / `SpecRunStateStore` / `SpecImplementRunner`、並擴充 `SpecAcceptanceParser` / `SpecRunCommand` / `SpecRunResult`）皆位於 `OrreryCore` target 內、未動 `Package.swift`、未新增 library target（D17 Phase 1 約束）。
- [ ] DI3 預留欄位 `child_session_ids` / `execution_graph` round-trip 正常（encode/decode test）：MVP 永遠填 `[]` / `null`，但 JSON shape 穩定保留。
- [ ] **C1 — Detached lifecycle**：`orrery spec-run --mode implement <fixture>` 在 Swift 端立刻 return、orrery parent 程序可直接 exit；手動殺 orrery parent（`kill $$` after spawn）後，wrapper bash 仍繼續跑、delegate 結束時 `_spec-finalize` 仍被執行（驗證：subprocess 結束後 state `status` 變 `"done"` / `"failed"` 而非留在 `"running"`）。
- [ ] **C1 — Hidden subcommand**：`orrery _spec-finalize <session_id> 0` 直接手動呼叫，對已存在的 `{id}.json` state 能寫入 `status="done"` + `completedAt` + `touchedFiles`；對不存在的 session_id 靜默 exit 0（防呆 no-op）；不出現在 `orrery --help` 清單。
- [ ] **C2 — Session ID identity**：透過 MCP 傳 `resume_session_id = <orrery UUID>` 給 `orrery_spec_implement` 時，delegate 真正收到的是 `state.delegateSessionId`（可驗證：fixture 先 `SpecRunStateStore.write` 一個 `delegateSessionId = "abc123"` 的 state；再以 `resume_session_id = <uuid>` 呼叫；檢查 wrapper shell 組出的 delegate command 含 `--resume abc123` 而非 UUID）。首次 launch 時 `state.delegateSessionId == nil` 直到 `_spec-finalize` 透過 `SessionResolver` diff 填入。
- [ ] **C3 — Detached stdout routing**：`watch == false` 時 wrapper 將 delegate stdout/stderr 寫入 `~/.orrery/spec-runs/{id}.stdout.log` / `{id}.stderr.log`（大型輸出不 deadlock）；`watch == true` 時 passthrough 到 CLI stdout/stderr。檔案末尾可讀最新字節（`tail -f` 可行）。
- [ ] Fixture 管理：`Tests/OrreryTests/Fixtures/` 下新增 `minimal-implement-spec.md`（含四 mandatory heading + 最小 acceptance 段），供 Runner / Finalize tests 使用；acceptance test `/tmp/tiny-fixture-spec.md` 於 test commands bash 區段改用此 fixture path（修 H5）。
- [ ] **G1 — Detached timeout 被兌現**：對一份會永不結束的 fixture（e.g. delegate 命令改成 `sleep 9999`）以 `timeout: 2` 呼叫 `orrery_spec_implement`，2 秒後 wrapper 的 watchdog 發 SIGTERM、delegate 被終止、`_spec-finalize` 收尾寫 `state.status == "aborted"`、`state.blockedReason == "overall timeout"`。驗證：主呼叫立即 return（early-return），polling status 3 秒內看到 aborted。
- [ ] **G2 — `ORRERY_SPEC_TOOL` 正確注入**：spawn wrapper 前，process.environment 含 `ORRERY_SPEC_TOOL=<claude|codex|gemini>`；`_spec-finalize` 能讀到此 env 並以該 tool 做 `SessionResolver.findScopedSessions` diff；若 env 缺失則 fallback 嘗試從 `ORRERY_SPEC_PATH` 旁路推斷或把 `delegate_session_id` 留 `null`。
- [ ] **G3 — `orreryBin` 路徑絕對化**：test 以 `.build/debug/orrery`（相對路徑）啟動 Runner，驗證 wrapper 字串內的 `_spec-finalize` 呼叫是絕對路徑（`hasPrefix("/")`）或 `"orrery"`（靠 PATH），**不**是 `".build/debug/orrery"` 字面；wrapper 實際執行時能正確呼到 finalize。
- [ ] **G5 — Finalize idempotency**：對同一 session_id 連續呼叫兩次 `orrery _spec-finalize <id> 0`，第二次應 stderr 標註 `already <status>, skipping` 且 state 檔的 `updatedAt` **不變**（第一次寫入後未再被覆寫）。
- [ ] **G8 — Resume silent-fallback warning**：先手動建一個 state 檔 with `delegateSessionId == nil`、`status == "failed"`；以 `--resume-session-id <uuid>` 再次呼叫 Runner，確認 stderr 含「resume_session_id=... provided but delegate_session_id was never captured」訊息，且新 subprocess 不帶 `--resume` flag 給 delegate CLI。

### Test commands

```bash
# Build
swift build

# Unit tests
swift test --filter SpecAcceptanceParserTests
swift test --filter SpecProgressLogTests
swift test --filter SpecRunStateStoreTests
swift test --filter SpecPromptExtractorTests
swift test --filter SpecImplementRunnerTests
swift test --filter SpecRunStatusTests
swift test --filter SpecImplementCommandTests
swift test  # full suite must remain green

# CLI smoke — implement early-return (using this spec itself as a fixture)
.build/debug/orrery spec-run --mode implement docs/tasks/2026-04-20-orrery-spec-implement-mvp.md \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["status"]=="running"; assert d["session_id"]; print("ok session=", d["session_id"])'

# CLI smoke — status poll (use session_id from previous)
SESSION_ID=$(.build/debug/orrery spec-run --mode implement docs/tasks/2026-04-20-orrery-spec-implement-mvp.md | python3 -c 'import sys,json; print(json.load(sys.stdin)["session_id"])')
sleep 2
.build/debug/orrery spec-run --mode status --session-id "$SESSION_ID" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["session_id"]==\"$SESSION_ID\"; print(d["status"])'

# CLI smoke — four-heading fail-fast (use a discussion file as negative fixture)
.build/debug/orrery spec-run --mode implement docs/discussions/2026-04-20-orrery-spec-implement-mvp.md ; echo "exit=$?"

# CLI smoke — invalid mode
.build/debug/orrery spec-run --mode plan docs/tasks/2026-04-20-orrery-spec-implement-mvp.md ; echo "exit=$?"

# CLI smoke — status requires session-id
.build/debug/orrery spec-run --mode status ; echo "exit=$?"

# CLI smoke — status for non-existent session
.build/debug/orrery spec-run --mode status --session-id 00000000-0000-0000-0000-000000000000 ; echo "exit=$?"

# State file created under ~/.orrery/spec-runs/
test -d ~/.orrery/spec-runs
ls ~/.orrery/spec-runs/*.json | head -1

# Verify no destructive git commands run during implement (run against the
# fixture in a clean worktree — the fixture lives in the repo, not /tmp)
FIXTURE=Tests/OrreryTests/Fixtures/minimal-implement-spec.md
test -f "$FIXTURE"  # ensure fixture exists before the destructive-check
git status > /tmp/before.txt
.build/debug/orrery spec-run --mode implement "$FIXTURE" --watch --timeout 60
git status > /tmp/after.txt
# no commits, no stash, no reset — working tree differences are only delegate's edits
git log --oneline -1 > /tmp/headafter.txt
[ "$(git rev-parse HEAD)" = "$(git rev-parse HEAD@{1})" ] && echo "head unchanged ok"

# MCP tools/list shows both new tools
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' > /tmp/mcp.in
echo '{"jsonrpc":"2.0","method":"notifications/initialized"}' >> /tmp/mcp.in
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' >> /tmp/mcp.in
.build/debug/orrery mcp-server < /tmp/mcp.in | grep -E 'orrery_spec_implement|orrery_spec_status'

# MCP tools/call — implement (early-return)
cat <<'EOF' | .build/debug/orrery mcp-server | tail -1 \
  | python3 -c 'import sys,json; d=json.loads(sys.stdin.read())["result"]; body=json.loads(d["content"][0]["text"]); assert body["status"]=="running"; print("ok session=", body["session_id"])'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"orrery_spec_implement","arguments":{"spec_path":"docs/tasks/2026-04-20-orrery-spec-implement-mvp.md"}}}
EOF

# MCP tools/call — status (requires valid session_id from above)
cat <<EOF | .build/debug/orrery mcp-server | tail -1 \
  | python3 -c 'import sys,json; d=json.loads(sys.stdin.read())["result"]; body=json.loads(d["content"][0]["text"]); assert "status" in body; print(body["status"])'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"orrery_spec_status","arguments":{"session_id":"$SESSION_ID"}}}
EOF

# JSON shape sanity — all required top-level keys present (implement)
.build/debug/orrery spec-run --mode implement docs/tasks/2026-04-20-orrery-spec-implement-mvp.md \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); req={"session_id","phase","status","started_at","completed_at","completed_steps","touched_files","diff_summary","blocked_reason","failed_step","child_session_ids","execution_graph","error"}; assert req <= set(d.keys()), req - set(d.keys()); print("ok")'

# Status JSON shape sanity
.build/debug/orrery spec-run --mode status --session-id "$SESSION_ID" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); req={"session_id","phase","status","started_at","updated_at","progress","last_error","result","log_tail"}; assert req <= set(d.keys()), req - set(d.keys()); print("ok")'

# Null surfaces explicitly — not omitted
.build/debug/orrery spec-run --mode implement docs/tasks/2026-04-20-orrery-spec-implement-mvp.md \
  | python3 -c 'import sys,json; raw=sys.stdin.read(); assert "\"completed_at\": null" in raw or "\"completed_at\":null" in raw; print("ok")'

# Slash command file installed
.build/debug/orrery mcp setup --project-dir /tmp/test-proj
test -f /tmp/test-proj/.claude/commands/orrery:spec-implement.md
test -f /tmp/test-proj/.claude/commands/orrery:spec-status.md
grep -E "polling cadence|2s.*30s" /tmp/test-proj/.claude/commands/orrery:spec-status.md

# CHANGELOG and version untouched
grep -E "^- .*orrery_spec_implement" CHANGELOG.md
grep -E "^- .*orrery_spec_status" CHANGELOG.md
grep -E "currentVersion" Sources/OrreryCore/MCP/MCPServer.swift  # unchanged version string
```