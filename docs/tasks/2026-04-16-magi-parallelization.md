# Orrery Magi 並行化與 Session 續接

## 來源

討論：`docs/discussions/2026-04-16-magi-parallelization.md`

## 目標

目前 `MagiOrchestrator` 依序呼叫三個模型（Claude → Codex → Gemini），總等待時間為三者之和。每次討論都是全新 session，無法延續先前脈絡，且共識報告格式不足以作為下游自動化（如 write-spec）的結構化輸入。本任務將三個模型的呼叫改為並行執行（縮短至 max 時間）、新增 session 續接機制、強化共識報告為結構化 FinalVerdict，並在每次討論結束後自動呼叫 facilitator 產出高品質 verdict。

---

## 介面合約（Interface Contract）

### `MagiAgentRunner`（新增，`Sources/OrreryCore/Magi/MagiAgentRunner.swift`）

```swift
public struct MagiAgentRunner {
    public let tool: Tool

    public struct Result {
        public let tool: Tool
        public let rawOutput: String
        public let stderrOutput: String
        public let exitCode: Int32
        public let timedOut: Bool
        public let sessionId: String?
        public let duration: TimeInterval
    }

    public init(tool: Tool, prompt: String, resumeSessionId: String?,
                environment: String?, store: EnvironmentStore)

    /// 啟動 subprocess 並等待完成或 timeout。
    /// 內部在 background thread 讀取 stdout/stderr（避免 pipe buffer deadlock），
    /// 用 DispatchWorkItem 在 timeout 後呼叫 process.terminate()。
    /// 呼叫完成後用 SessionResolver snapshot diff 取得 sessionId。
    public func run(timeout: TimeInterval) -> Result

    /// 強制終止 subprocess。
    public func terminate()
}
```

**不變量**：
- Runner **自建** stdout Pipe 和 stderr Pipe，覆寫 `DelegateProcessBuilder.build()` 回傳的 process 的 `standardError`（builder 預設將 stderr 導到 `FileHandle.standardError`）
- `DelegateProcessBuilder` 本身**不改動**，Runner 在 `build()` 之後、`process.run()` 之前覆寫 `process.standardError`
- stdout/stderr 讀取在 **background thread**（`DispatchQueue.global().async`）啟動 `readDataToEndOfFile()`，先於 `waitUntilExit()` 開始讀取
- Timeout 使用 `DispatchWorkItem` 排程在指定秒數後呼叫 `process.terminate()`；若 process 正常結束則 cancel 該 work item
- `sessionId` 透過 filesystem snapshot diff 取得：`run()` 開始前呼叫 `SessionResolver.findScopedSessions()` 記錄已知 session ID 集合，process 結束後再呼叫一次取差集。若差集為空或多於一個，回傳 `nil`

**所有權明示**：
- Process 的 `standardInput` 和 `environment`：由 `DelegateProcessBuilder.build()` 負責設定，Runner 不覆寫
- Process 的 `standardOutput`：由 `DelegateProcessBuilder.build(outputMode: .capture)` 設定為 Pipe，Runner 直接使用
- Process 的 `standardError`：由 Runner 覆寫為自建的 stderr Pipe

**Framework 備註**：
- `SessionResolver.findScopedSessions()` 目前是 `private static`，需改為 `internal static` 以供 Runner 呼叫（同 module `OrreryCore`）

---

### `MagiOrchestrator.run()`（修改，`Sources/OrreryCore/Magi/MagiOrchestrator.swift`）

```swift
public static func run(
    topic: String,
    subtopics: [String],
    tools: [Tool],
    maxRounds: Int,
    environment: String?,
    store: EnvironmentStore,
    outputPath: String?,
    previousRunId: String?,      // 新增：續接先前的 run
    noSummarize: Bool = false    // 新增：跳過 FinalVerdict summarization
) throws -> MagiRun
```

**行為變更**：
- 每輪的 tool 呼叫從 sequential for loop 改為 **parallel**：使用 `DispatchGroup` + `DispatchQueue.global().async` 同時啟動所有 `MagiAgentRunner`，`group.wait()` 等待全部完成
- 結果收集使用 **serial DispatchQueue** 保護 `responses` array 的 thread safety
- `previousRunId` 非 nil 時，從 `store` 載入先前的 `MagiRun`，讀取其 `sessionMap` 傳入各 runner 的 `resumeSessionId`
- 每輪結束後，從各 runner 的 `Result.sessionId` 更新 `MagiRun.sessionMap`
- 所有輪次結束後：
  - 預設（`noSummarize == false`）：呼叫 facilitator 模型（`tools[0]`）執行 summarization pass，產出 `FinalVerdict`
  - `noSummarize == true`：用程式碼從 final positions merge 產出 `FinalVerdict`
- `try? magiRun.save()` 改為 `try magiRun.save()`，不吞錯
- Progress 訊息（`L10n.Magi.roundStart`、`L10n.Magi.toolStart`、`L10n.Magi.toolDone`）改為寫入 `FileHandle.standardError`，stdout 只輸出最終 report

---

### `MagiRun`（修改，`Sources/OrreryCore/Magi/MagiRun.swift`）

```swift
public struct MagiRun: Codable {
    // 既有欄位不變...
    public var sessionMap: [String: String]?       // 新增：Tool.rawValue → native session ID
    public var finalVerdict: FinalVerdict?          // 新增
}

public struct FinalVerdict: Codable {
    public let decisions: [VerdictDecision]
    public let openQuestions: [String]
    public let constraints: [String]
}

public struct VerdictDecision: Codable {
    public let subtopic: String
    public let status: ConsensusStatus
    public let summary: String          // 去重合併後的一段話
    public let reasoning: String        // 決策依據
    public let dissent: String?         // 少數方意見（若有）
}
```

**向後相容**：`sessionMap` 和 `finalVerdict` 都是 `Optional`，synthesized `Codable` 在 decode 舊 JSON 時自動為 `nil`。

---

### `MagiAgentResponse`（修改，`Sources/OrreryCore/Magi/MagiRun.swift`）

```swift
public struct MagiAgentResponse: Codable {
    // 既有欄位不變...
    public let exitCode: Int32?           // 新增
    public let stderrOutput: String?      // 新增
    public let timedOut: Bool?            // 新增
    public let duration: TimeInterval?    // 新增
    public let sessionId: String?         // 新增
}
```

**向後相容**：所有新增欄位為 `Optional`。

---

### `MagiPromptBuilder.buildPrompt()`（修改，`Sources/OrreryCore/Magi/MagiPromptBuilder.swift`）

```swift
public static func buildPrompt(
    topic: String,
    subtopics: [String],
    previousRounds: [MagiRound],
    currentRound: Int,
    targetTool: Tool,
    includeOwnHistory: Bool = true   // 新增
) -> String
```

**行為變更**：
- `includeOwnHistory == false` 時，跳過 `### Your Previous Reasoning` 段落（不呼叫 `collectOwnOutputs`）
- `includeOwnHistory == false` 時，`### Other Participants' Positions` 只注入 **最新一輪** 的 cross-model positions，不注入所有歷史輪次
- Orchestrator 在有 `resumeSessionId` 時傳 `includeOwnHistory: false`

---

### `MagiCommand`（修改，`Sources/OrreryCore/Commands/MagiCommand.swift`）

```swift
// 新增 options
@Option(name: .long, help: "Resume from a previous Magi run ID")
public var resume: String?

@Flag(name: .long, help: "Skip FinalVerdict summarization, use code-merge only")
public var noSummarize: Bool = false
```

---

### `SessionResolver.findScopedSessions()`（修改，`Sources/OrreryCore/Helpers/SessionResolver.swift`）

```swift
// 從 private static 改為 internal static
internal static func findScopedSessions(
    tool: Tool, cwd: String, store: EnvironmentStore, activeEnvironment: String?
) -> [SessionsCommand.SessionEntry]
```

**注意**：此函式內部按 tool 分派到 `findScopedClaudeSessions`/`findScopedCodexSessions`/`findScopedGeminiSessions`。Codex 的掃描是 **global**（不過濾 cwd），Claude 和 Gemini 是 project-scoped。這意味著 Codex 的 snapshot diff 在併發場景下可能比 Claude/Gemini 更容易出現多個新增 session 的情況（Runner 此時回傳 `sessionId: nil`）。

---

## 改動檔案

| 檔案路徑 | 改動描述 |
|---------|----------|
| `Sources/OrreryCore/Magi/MagiAgentRunner.swift` | **新增**：per-tool subprocess runner，封裝並行執行、pipe 管理、timeout、session ID 擷取 |
| `Sources/OrreryCore/Magi/MagiOrchestrator.swift` | 重構 `run()` 為並行執行，新增 `previousRunId`/`noSummarize` 參數，progress 改 stderr，save 不吞錯，新增 summarization pass |
| `Sources/OrreryCore/Magi/MagiRun.swift` | 新增 `FinalVerdict`/`VerdictDecision` struct，`MagiRun` 加 `sessionMap`/`finalVerdict`，`MagiAgentResponse` 加 execution metadata |
| `Sources/OrreryCore/Magi/MagiPromptBuilder.swift` | `buildPrompt()` 加 `includeOwnHistory` 參數，控制 resume 時的 prompt 內容 |
| `Sources/OrreryCore/Commands/MagiCommand.swift` | 新增 `--resume` 和 `--no-summarize` options，傳遞至 orchestrator |
| `Sources/OrreryCore/Helpers/SessionResolver.swift` | `findScopedSessions()` 從 `private` 改為 `internal` |
| `Sources/OrreryCore/MCP/MCPServer.swift` | `orrery_magi` handler 改為在成功回應中附加 `runId`；`execCommand()` 的 pipe-drain 順序修正（read before wait） |
| `Sources/OrreryCore/Resources/Localization/en.json` | 新增 L10n keys：`magi.summarizing`、`magi.resuming`、`magi.timeoutWarning`、`magi.sessionIdNotFound` |
| `Sources/OrreryCore/Resources/Localization/zh-Hant.json` | 同上中文翻譯 |
| `Sources/OrreryCore/Resources/Localization/ja.json` | 同上日文翻譯 |

**受影響但不需修改的呼叫端**：
- `DelegateProcessBuilder.swift` — Runner 使用其 `build()` 但不修改 builder 本身
- `MagiResponseParser.swift` — 解析邏輯不變

---

## 實作步驟

### Step 1：新增 `MagiAgentRunner.swift`

1. 建立 `Sources/OrreryCore/Magi/MagiAgentRunner.swift`
2. `init()` 接收 `tool`, `prompt`, `resumeSessionId`, `environment`, `store`，內部呼叫 `DelegateProcessBuilder(tool:prompt:resumeSessionId:environment:store:).build(outputMode: .capture)` 取得 `(process, stdinMode, outputPipe)`
3. 建立 `stderrPipe = Pipe()`，覆寫 `process.standardError = stderrPipe`
4. `run(timeout:)` 實作：
   ```
   a. snapshot = SessionResolver.findScopedSessions(tool, cwd, store, env)
                    .map { $0.id }  → Set<String>
   b. startTime = Date()
   c. 在 background queue 啟動 stdout 讀取：
      stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
   d. 在 background queue 啟動 stderr 讀取：
      stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
   e. 建立 timeoutWork = DispatchWorkItem { process.terminate() }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
   f. process.run()
   g. process.waitUntilExit()
   h. timeoutWork.cancel()
   i. timedOut = (process.terminationStatus == SIGTERM or 143)
   j. duration = Date().timeIntervalSince(startTime)
   k. newSnapshot = SessionResolver.findScopedSessions(...)
                      .map { $0.id } → Set<String>
      diff = newSnapshot.subtracting(snapshot)
      sessionId = diff.count == 1 ? diff.first : nil
   l. 回傳 Result(...)
   ```
5. `terminate()` 直接呼叫 `process.terminate()`

### Step 2：修改 `SessionResolver.swift`

1. 將 `findScopedSessions(tool:cwd:store:activeEnvironment:)` 的 access level 從 `private static` 改為 `internal static`
2. 內部三個 per-tool 函式保持 `private static` 不變

### Step 3：修改 `MagiRun.swift`

1. `MagiRun` 新增：
   - `public var sessionMap: [String: String]?`（放在 `updatedAt` 之後）
   - `public var finalVerdict: FinalVerdict?`（放在 `finalConsensus` 之後）
2. `MagiAgentResponse` 新增 optional 欄位：`exitCode: Int32?`, `stderrOutput: String?`, `timedOut: Bool?`, `duration: TimeInterval?`, `sessionId: String?`
3. 新增 `FinalVerdict` 和 `VerdictDecision` struct（見介面合約）
4. 所有新增欄位為 `Optional`，synthesized `Codable` 自動處理

### Step 4：修改 `MagiPromptBuilder.swift`

1. `buildPrompt()` 新增參數 `includeOwnHistory: Bool = true`
2. 當 `includeOwnHistory == false` 時：
   - 跳過 `### Your Previous Reasoning` 整個段落
   - `### Other Participants' Positions` 只取 `previousRounds.last`（最新一輪），不迭代所有輪次
3. 當 `includeOwnHistory == true` 時，行為與現在完全相同（default path 不變）

### Step 5：重構 `MagiOrchestrator.swift`

1. `run()` 新增參數 `previousRunId: String?` 和 `noSummarize: Bool = false`
2. 若 `previousRunId` 非 nil：
   ```
   a. 從 store.homeURL/magi/<previousRunId>.json 讀取先前的 MagiRun
   b. 提取 sessionMap → [String: String]
   c. 將先前 run 的 rounds 附加到新 run 的 previousRounds context
   ```
3. 每輪的 tool 呼叫重構為並行：
   ```
   let group = DispatchGroup()
   let resultQueue = DispatchQueue(label: "magi.results")
   var runnerResults: [MagiAgentRunner.Result] = []

   for tool in tools {
       group.enter()
       DispatchQueue.global().async {
           let resumeId = sessionMap?[tool.rawValue]
           let includeOwn = (resumeId == nil)
           let prompt = MagiPromptBuilder.buildPrompt(
               ..., includeOwnHistory: includeOwn)
           let runner = MagiAgentRunner(
               tool: tool, prompt: prompt,
               resumeSessionId: resumeId, ...)
           let result = runner.run(timeout: 120)
           resultQueue.sync { runnerResults.append(result) }
           group.leave()
       }
   }
   group.wait()
   ```
4. 將 `runnerResults` 轉為 `[MagiAgentResponse]`（含新增的 execution metadata）
5. 每輪結束後更新 `magiRun.sessionMap`（從各 result.sessionId 合併）
6. Progress 訊息全部改為 `FileHandle.standardError.write()`
7. `try? magiRun.save(store:)` 改為 `try magiRun.save(store:)`
8. 所有輪次結束後，產出 FinalVerdict：
   - **預設路徑**（`noSummarize == false`）：
     ```
     a. 組裝 summarization prompt：包含完整 MagiRun 的 topic、subtopics、
        每個 subtopic 的 consensusStatus、所有模型的 positions + reasoning
     b. 呼叫 facilitator 模型（tools[0]），使用 DelegateProcessBuilder
        要求輸出 FinalVerdict JSON
     c. 解析回應為 FinalVerdict
     d. 若解析失敗，fallback 到純程式碼 merge
     ```
   - **降級路徑**（`noSummarize == true` 或 summarization 失敗）：
     ```
     a. 對每個 subtopic，取 finalConsensus 的 status
     b. summary = agreed/majority 方第一個模型的 reasoning
     c. dissent = disagreeing 方的 reasoning（若有）
     d. openQuestions = status == .disputed 的 subtopics
     e. constraints = position == .conditional 的 reasoning
     ```
9. 設定 `magiRun.finalVerdict = verdict`
10. MCP stdout 輸出：最終 report + 一行 `Run ID: <runId>`

### Step 6：修改 `MagiCommand.swift`

1. 新增 `@Option(name: .long) var resume: String?`
2. 新增 `@Flag(name: .long) var noSummarize: Bool = false`
3. 將 `resume` 和 `noSummarize` 傳入 `MagiOrchestrator.run()`

### Step 7：修改 `MCPServer.swift`

1. `execCommand()` 的 pipe-drain 順序修正：
   ```
   // 現在（有 deadlock 風險）：
   process.run() → waitUntilExit() → readDataToEndOfFile()

   // 改為：
   process.run()
   let outputData = pipe.fileHandleForReading.readDataToEndOfFile()  // 先讀
   let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
   process.waitUntilExit()                                           // 再等
   ```
2. `orrery_magi` handler：成功回應時在 text 尾端附加 `\n\nRun ID: <runId>`（需從 stdout 末行解析 `Run ID:` 前綴）

### Step 8：新增 L10n keys

在 `en.json`、`zh-Hant.json`、`ja.json` 新增：
- `magi.summarizing`：`"Generating FinalVerdict..."`
- `magi.resuming`：`"Resuming from run {runId}..."`
- `magi.timeoutWarning`：`"{tool} timed out after {seconds}s"`
- `magi.sessionIdNotFound`：`"Could not determine session ID for {tool}"`

---

## 失敗路徑

### Runner 層

| 條件 | 行為 | 可恢復 |
|------|------|--------|
| `DelegateProcessBuilder.build()` throws | Runner.run() 回傳 Result(rawOutput: "", exitCode: -1, ...) | 是，orchestrator 視為空回應 |
| Process timeout（超過 120s） | `process.terminate()` 被呼叫，Result.timedOut = true | 是，stderr 記錄 warning |
| Process non-zero exit | Result.exitCode 記錄實際值，rawOutput 可能為部分輸出 | 是，parse 嘗試處理部分輸出 |
| SessionResolver snapshot diff 找到 0 或 >1 新 session | Result.sessionId = nil，stderr 記錄 warning | 是，該 tool 下次無法 resume |

### Orchestrator 層

| 條件 | 行為 | 可恢復 |
|------|------|--------|
| `previousRunId` 指定但 JSON 不存在 | throw ValidationError | 不可恢復 |
| `magiRun.save()` 失敗 | throw（不再吞錯） | 不可恢復（磁碟/權限問題） |
| FinalVerdict summarization call 失敗 | fallback 到純程式碼 merge，stderr 記錄 warning | 是 |
| 所有 tool 都 timeout | 輪次仍完成（全空回應），consensus 全部 pending | 是，但結果無用 |

---

## 不改動的部分

- `DelegateProcessBuilder.swift` — Runner 使用 builder 但不修改 builder 本身
- `MagiResponseParser.swift` — 解析邏輯不變
- `MCP server 協議` — 不新增 MCP tool，只修改 `orrery_magi` 的回應內容
- `write-spec skill` — 本任務不實作 write-spec 功能
- CLI 的 `orrery delegate` / `orrery resume` 指令 — 不受影響

---

## 驗收標準

### 功能合約

- [ ] `orrery magi "topic A; topic B"` 三個模型**並行**呼叫，總耗時接近最慢模型而非三者之和
- [ ] 同一輪內三個模型的 stdout/stderr 互不干擾，各自正確收集
- [ ] Runner timeout 120s 後 process 被 terminate，Result.timedOut == true
- [ ] `orrery magi "topic" --resume <runId>` 成功載入先前 run 的 sessionMap，各模型帶 `--resume` 啟動
- [ ] Resume 時 prompt 不包含 `### Your Previous Reasoning` 段落
- [ ] Resume 時 `### Other Participants' Positions` 只含最新一輪
- [ ] `MagiRun` JSON 的 `sessionMap` 正確記錄各 tool 的 session ID
- [ ] 舊格式 `MagiRun` JSON 仍可正常 decode（新欄位為 nil）
- [ ] 討論完成後自動產出 `FinalVerdict`，`decisions` 陣列非空
- [ ] `FinalVerdict.decisions` 的 summary 不含重複/冗餘的相同觀點
- [ ] `--no-summarize` flag 跳過 summarization call，改用程式碼 merge
- [ ] Progress 訊息只出現在 stderr，stdout 只有最終 report
- [ ] `MagiRun` JSON 存檔不再用 `try?`，磁碟錯誤正確拋出
- [ ] MCP `orrery_magi` 回應包含 `Run ID`
- [ ] `MCPServer.execCommand()` 的 read/wait 順序正確（read before wait）

### 測試指令

```bash
# 建置確認
swift build 2>&1 | tail -5

# 並行化確認（觀察 stderr 的 tool start/done 訊息時間戳）
time orrery magi "test topic A; test topic B" --rounds 1 2>stderr.log
cat stderr.log  # 確認三個 toolStart 幾乎同時出現

# Session 續接確認
RUN_ID=$(grep "Run ID:" stderr.log | awk '{print $NF}')
orrery magi "test topic A; test topic B" --rounds 1 --resume "$RUN_ID" 2>stderr2.log
cat stderr2.log  # 確認出現 "Resuming from run"

# FinalVerdict 確認
cat ~/.orrery/magi/$RUN_ID.json | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get('finalVerdict','MISSING'), indent=2))"

# 向後相容確認
# 手動建立一個不含 sessionMap/finalVerdict 的舊格式 JSON，確認可 decode

# --no-summarize 確認
orrery magi "test" --rounds 1 --no-summarize 2>stderr3.log
grep -L "Generating FinalVerdict" stderr3.log  # 不應出現 summarizing 訊息
```

---

## 已知限制

1. **Codex session ID 精度**：`SessionResolver` 對 Codex 的掃描是 global（不過濾 cwd），併發場景下 snapshot diff 可能找到多個新增 session → `sessionId: nil`，該 tool 無法 resume。Claude 和 Gemini 是 project-scoped，精度較高
2. **Summarization call 成本**：預設每次 Magi 結束後額外呼叫一次 facilitator 模型。若成本敏感可用 `--no-summarize` 降級
3. **不包含 async/await 遷移**：本任務刻意保持同步 API，未來可作為獨立重構任務
4. **FinalVerdict 降級品質**：`--no-summarize` 或 summarization 失敗時，fallback 的純程式碼 merge 品質有限（取第一個模型的 reasoning，不做去重）
5. **Timeout 預設值固定**：120 秒硬編碼，未來可考慮暴露為 `--timeout` option
