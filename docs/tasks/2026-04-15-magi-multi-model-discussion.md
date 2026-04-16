# Magi：多模型互相對話討論並達成共識

## 來源

討論：`docs/discussions/2026-04-15-magi-multi-model-discussion.md`

## 目標

Orrery 目前的 `delegate` 是單向委派——使用者對單一模型下達指令。本任務實作 `orrery magi` 指令，讓使用者提出一個議題後，已登入的 Claude/Codex/Gemini 三個模型能像真實人類一樣互相對話、反駁，經過多輪討論後產出結構化的共識報告。共識結果以 markdown 輸出，可被後續工作流程（spec 撰寫、實作）直接引用。

---

## 介面合約（Interface Contract）

### `OutputMode`（新增，DelegateProcessBuilder 同檔）

```swift
// Sources/OrreryCore/Helpers/DelegateProcessBuilder.swift
public enum OutputMode {
    case passthrough  // stdout → FileHandle.standardOutput（現有行為）
    case capture      // stdout → Pipe，caller 可讀取內容
}
```

### `DelegateProcessBuilder.build()`（修改）

```swift
public func build(outputMode: OutputMode = .passthrough)
    throws -> (process: Process, stdinMode: StdinMode, outputPipe: Pipe?)
```

- `outputMode` 預設 `.passthrough`，確保所有既有 call site 行為不變
- `.capture` 時回傳非 nil 的 `outputPipe`，caller 負責在 `process.waitUntilExit()` 後讀取 `outputPipe!.fileHandleForReading.readDataToEndOfFile()`
- **所有權**：stdout 設定由 builder 負責。caller 不需再設定 `process.standardOutput`

> **Framework 備註**：`DelegateCommand` 和 `RunCommand`（不使用 Builder）的呼叫不受影響。`DelegateCommand` 的兩個 call site 均不傳 `outputMode`，自動走 `.passthrough`。

---

### `MagiPosition`（新增）

```swift
// Sources/OrreryCore/Magi/MagiRun.swift
public enum MagiPosition: String, Codable {
    case agree
    case disagree
    case conditional
}
```

### `MagiPositionEntry`（新增）

```swift
public struct MagiPositionEntry: Codable {
    public let subtopic: String
    public let position: MagiPosition
    public let reasoning: String
}
```

### `MagiVote`（新增，v2 預留）

```swift
public struct MagiVote: Codable {
    public let claimId: String
    public let vote: MagiPosition
    public let counterpoint: String?
}
```

### `MagiAgentResponse`（新增）

```swift
public struct MagiAgentResponse: Codable {
    public let tool: Tool
    public let rawOutput: String
    public let positions: [MagiPositionEntry]?  // nil = JSON 解析失敗
    public let votes: [MagiVote]?               // v2 預留，v1 始終為 nil
    public let parseSuccess: Bool
}
```

### `ConsensusStatus`（新增）

```swift
public enum ConsensusStatus: String, Codable {
    case agreed    // 所有參與者 agree
    case majority  // ≥2 agree，有 1 disagree/conditional
    case disputed  // ≥1 disagree 且無多數
    case pending   // 資訊不足或解析失敗
}
```

### `ConsensusItem`（新增）

```swift
public struct ConsensusItem: Codable {
    public let subtopic: String
    public var status: ConsensusStatus
    public var positions: [String: MagiPosition]  // key = tool.rawValue
}
```

### `MagiRound`（新增）

```swift
public struct MagiRound: Codable {
    public let roundNumber: Int
    public let responses: [MagiAgentResponse]
    public let consensusSnapshot: [ConsensusItem]
    public let votes: [MagiAgentResponse]?  // v2 預留，v1 始終為 nil
}
```

### `MagiRunStatus`（新增）

```swift
public enum MagiRunStatus: String, Codable {
    case inProgress
    case maxRoundsReached
    case converged
}
```

### `MagiRun`（新增）

```swift
public struct MagiRun: Codable {
    public let runId: String              // UUID
    public let topic: String
    public let participants: [Tool]
    public let environment: String?
    public var rounds: [MagiRound]
    public var finalConsensus: [ConsensusItem]?
    public var status: MagiRunStatus
    public let createdAt: String          // ISO 8601
    public var updatedAt: String          // ISO 8601
}
```

> 儲存路徑：`~/.orrery/magi/<runId>.json`（由 `EnvironmentStore.homeURL` 推導）

---

### `MagiPromptBuilder`（新增）

```swift
// Sources/OrreryCore/Magi/MagiPromptBuilder.swift
public struct MagiPromptBuilder {
    /// 產生第 N 輪給特定 tool 的 prompt
    public static func buildPrompt(
        topic: String,
        subtopics: [String],
        previousRounds: [MagiRound],
        currentRound: Int,
        targetTool: Tool
    ) -> String
}
```

Prompt 結構：
```
## Multi-Model Discussion — Round {N}

### Topic
{topic}

### Sub-topics
{numbered list}

### Your Previous Reasoning (你的思考脈絡)
{targetTool 在前輪的完整 raw output — 讓模型看到自己完整的思考過程}

### Other Participants' Positions (其他參與者的立場)
{其他 agent 的結構化立場摘要}

### Your Task
You are {tool.displayName}. Based on your previous reasoning above and other
participants' positions, analyze each sub-topic and provide your updated position.

You MUST end your response with a JSON block in this exact format:
```json
{"positions": [{"subtopic": "...", "position": "agree|disagree|conditional", "reasoning": "..."}]}
```

If you disagree with another model's position, explain why in reasoning.
Stay consistent with your reasoning chain unless you find a compelling counter-argument.
```

> **差異化摘要策略**：
> - **自己的前輪回應**：注入完整 raw output（讓模型看到自己的思考脈絡，能延續推理鏈、堅定有據的立場）
> - **其他 agent 的前輪回應**：只注入結構化的 `positions[]`（subtopic + position + reasoning），不含 raw output（節省 token、聚焦論點）
> - **解析失敗的回應**：用 raw output 的前 200 字元替代
> - **Round 1**（無前輪）：省略 "Your Previous Reasoning" 段落

---

### `MagiResponseParser`（新增）

```swift
// Sources/OrreryCore/Magi/MagiResponseParser.swift
public struct MagiResponseParser {
    /// 從 agent 的 raw output 中解析 JSON positions
    /// 策略：1) 找最後一個 ```json ... ``` block，嘗試 decode
    ///       2) fallback：regex 搜尋 "agree"/"disagree" 關鍵字，建構粗略 positions
    ///       3) 全部失敗 → positions = nil, parseSuccess = false
    public static func parse(rawOutput: String, subtopics: [String]) -> (positions: [MagiPositionEntry]?, parseSuccess: Bool)
}
```

---

### `MagiOrchestrator`（新增）

```swift
// Sources/OrreryCore/Magi/MagiOrchestrator.swift
public struct MagiOrchestrator {
    /// 執行完整的 magi 討論流程
    /// - 依序對每個 tool 呼叫 DelegateProcessBuilder（outputMode: .capture）
    /// - 每輪結束後解析 JSON、更新 consensus、存 MagiRun
    /// - 到達 maxRounds 後產出最終報告
    public static func run(
        topic: String,
        subtopics: [String],
        tools: [Tool],
        maxRounds: Int,
        environment: String?,
        store: EnvironmentStore,
        outputPath: String?
    ) throws -> MagiRun
}
```

**所有權**：
- process 建構由 `DelegateProcessBuilder` 負責
- stdout capture 由 `MagiOrchestrator` 透過 `outputMode: .capture` 發起
- consensus 判定由 `MagiOrchestrator` 使用 deterministic 規則執行
- 報告輸出由 `MagiOrchestrator` 負責（markdown to stdout + JSON to `~/.orrery/magi/`）

**Consensus 判定規則**（deterministic，不依賴 AI judge）：
- `agreed`：所有成功解析的 agent 都 `agree`，且無 `disagree`
- `majority`：≥2 個 agent `agree`（或 `conditional`），≤1 個 `disagree`
- `disputed`：≥2 個 agent `disagree`，或無 majority
- `pending`：<2 個 agent 成功解析（解析失敗太多）

---

### `MagiCommand`（新增）

```swift
// Sources/OrreryCore/Commands/MagiCommand.swift
public struct MagiCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "magi",
        abstract: L10n.Magi.abstract
    )

    @Flag(help: ArgumentHelp(L10n.ToolFlag.claude))
    public var claude: Bool = false

    @Flag(help: ArgumentHelp(L10n.ToolFlag.codex))
    public var codex: Bool = false

    @Flag(help: ArgumentHelp(L10n.ToolFlag.gemini))
    public var gemini: Bool = false

    @Option(name: .shortAndLong, help: ArgumentHelp(L10n.Magi.envHelp))
    public var environment: String?

    @Option(name: .long, help: ArgumentHelp(L10n.Magi.roundsHelp))
    public var rounds: Int = 3

    @Option(name: .long, help: ArgumentHelp(L10n.Magi.outputHelp))
    public var output: String?

    @Argument(help: ArgumentHelp(L10n.Magi.topicHelp))
    public var topic: String

    public func run() throws { ... }
}
```

> **Framework 備註**：`topic` 是必填 `@Argument`（非 optional），ArgumentParser 會自動驗證。`--rounds` 有預設值 3，不需額外 validation。tool flags 無 flag = 全部已登入工具。

**tool 可用性檢查**：
- 若使用者未指定 tool flag，用 `Tool.allCases`
- 對每個 tool，用 `Process` 呼叫 `which <tool-binary>` 檢查是否安裝
- 過濾掉未安裝的 tool。若過濾後 <2 個 tool，throw `ValidationError(L10n.Magi.insufficientTools)`

---

### L10n 新增 keys

| Key | en | zh-Hant |
|-----|-----|---------|
| `magi.abstract` | `"Start a multi-model discussion and reach consensus"` | `"啟動多模型討論並達成共識"` |
| `magi.envHelp` | `"Environment name"` | `"環境名稱"` |
| `magi.roundsHelp` | `"Maximum discussion rounds (default: 3)"` | `"最大討論輪數（預設：3）"` |
| `magi.outputHelp` | `"Output markdown report to file"` | `"將 markdown 報告輸出至檔案"` |
| `magi.topicHelp` | `"Discussion topic"` | `"討論議題"` |
| `magi.insufficientTools` | `"At least 2 tools must be available for a discussion."` | `"至少需要 2 個可用工具才能進行討論。"` |
| `magi.roundStart` | `"Round {n}/{total}"` | `"第 {n}/{total} 輪"` |
| `magi.toolStart` | `"Waiting for {tool}..."` | `"等待 {tool} 回應..."` |
| `magi.toolDone` | `"{tool} responded ({parseStatus})"` | `"{tool} 已回應（{parseStatus}）"` |
| `magi.consensusReport` | `"Consensus Report"` | `"共識報告"` |
| `magi.runSaved` | `"Run saved to {path}"` | `"討論紀錄已儲存至 {path}"` |

---

## 改動檔案

| 檔案路徑 | 動作 |
|---------|------|
| `Sources/OrreryCore/Helpers/DelegateProcessBuilder.swift` | **修改**：新增 `OutputMode` enum；`build()` 加 `outputMode` 參數和 `outputPipe` 回傳 |
| `Sources/OrreryCore/Commands/DelegateCommand.swift` | **修改**：更新 `builder.build()` 呼叫以適配新回傳型別（加 `_` 忽略 outputPipe） |
| `Sources/OrreryCore/Commands/OrreryCommand.swift` | **修改**：在 `subcommands` 陣列加入 `MagiCommand.self` |
| `Sources/OrreryCore/Magi/MagiRun.swift` | **新建**：所有資料模型（MagiRun, MagiRound, ConsensusItem, MagiPosition, MagiVote 等） |
| `Sources/OrreryCore/Magi/MagiOrchestrator.swift` | **新建**：核心編排邏輯 |
| `Sources/OrreryCore/Magi/MagiPromptBuilder.swift` | **新建**：Prompt template 組裝 |
| `Sources/OrreryCore/Magi/MagiResponseParser.swift` | **新建**：JSON 解析 + regex fallback |
| `Sources/OrreryCore/Commands/MagiCommand.swift` | **新建**：CLI 指令定義 |
| `Sources/OrreryCore/Resources/Localization/en.json` | **修改**：新增 `magi.*` keys |
| `Sources/OrreryCore/Resources/Localization/zh-Hant.json` | **修改**：新增 `magi.*` keys |
| `Sources/OrreryCore/Resources/Localization/ja.json` | **修改**：新增 `magi.*` keys |
| `Sources/OrreryCore/Resources/Localization/l10n-signatures.json` | **修改**：新增 `Magi.*` signatures |

---

## 實作步驟

### Step 1：修改 DelegateProcessBuilder.swift

1. 在 `StdinMode` enum 之後新增 `OutputMode` enum（`.passthrough` / `.capture`）
2. 修改 `build()` 簽名：加入 `outputMode: OutputMode = .passthrough` 參數，回傳型別改為 `(process: Process, stdinMode: StdinMode, outputPipe: Pipe?)`
3. 在 `// Build process` 段落中，替換第 114 行：
   ```
   若 outputMode == .capture：
     let pipe = Pipe()
     process.standardOutput = pipe
     outputPipe = pipe
   否則：
     process.standardOutput = FileHandle.standardOutput
     outputPipe = nil
   ```
4. 修改 return：`return (process, stdinMode, outputPipe)`

### Step 2：修改 DelegateCommand.swift call sites

1. `DelegateCommand.run()` 第 113 行：`let (process, _) = try builder.build()` → `let (process, _, _) = try builder.build()`
2. `runNativeMappingPath()` 第 139 行：同上

### Step 3：新建 Sources/OrreryCore/Magi/ 目錄

`mkdir -p Sources/OrreryCore/Magi`

### Step 4：新建 MagiRun.swift

依照介面合約段落，建立以下 Codable 型別：
- `MagiPosition` enum
- `MagiPositionEntry` struct
- `MagiVote` struct（v2 預留）
- `MagiAgentResponse` struct
- `ConsensusStatus` enum
- `ConsensusItem` struct
- `MagiRound` struct
- `MagiRunStatus` enum
- `MagiRun` struct

加入 `MagiRun` 的 persistence 方法：
```swift
public func save(store: EnvironmentStore) throws {
    let dir = store.homeURL.appendingPathComponent("magi")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("\(runId).json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: file)
}
```

### Step 5：新建 MagiPromptBuilder.swift

1. 實作 `buildPrompt()` 靜態方法
2. Prompt 結構（差異化摘要）：
   - 標題：`## Multi-Model Discussion — Round {N}`
   - Topic 段落
   - Sub-topics 編號列表
   - **Your Previous Reasoning**（僅 Round 2+ 才有）：
     ```
     for round in previousRounds:
       找到 targetTool 的 response
       注入完整 rawOutput（讓模型延續自己的思考脈絡）
     ```
   - **Other Participants' Positions**（其他 agent 的結構化摘要）：
     ```
     for round in previousRounds:
       for response in round.responses where response.tool != targetTool:
         if response.positions != nil:
           列出 "{tool}: {subtopic} → {position}: {reasoning}"
         else:
           列出 "{tool}: (parse failed) {rawOutput.prefix(200)}"
     ```
   - 指令段落：要求模型在回應末尾輸出 JSON block，並要求延續自己的推理鏈
3. 控制 prompt 長度策略：
   - 自己的前輪 raw output：完整保留（這是最有價值的上下文）
   - 其他 agent：只用 positions（結構化），大幅節省 token
   - 若自己的累積 raw output 過長（>8000 字元），只保留最近 2 輪的完整 output，更早的輪次降級為 positions 摘要

### Step 6：新建 MagiResponseParser.swift

1. 實作 `parse()` 靜態方法
2. 主要策略：用 regex 找最後一個 ` ```json\n...\n``` ` block
3. 嘗試 `JSONDecoder().decode`：目標結構為 `{"positions": [MagiPositionEntry]}`
4. Fallback 策略：
   - 對每個 subtopic，用 regex 搜尋 `"subtopic".*"agree"` / `"disagree"` / `"conditional"`
   - 若找到 ≥1 個匹配，建構粗略 `MagiPositionEntry`（reasoning = "extracted from unstructured output"）
5. 全部失敗 → `(nil, false)`

### Step 7：新建 MagiOrchestrator.swift

1. 實作 `run()` 靜態方法，核心邏輯：
   ```
   建立 MagiRun（status: .inProgress）
   for roundNumber in 1...maxRounds:
     print "Round {roundNumber}/{maxRounds}"
     var responses: [MagiAgentResponse] = []
     for tool in tools:  // serial 執行
       print "Waiting for {tool}..."
       let builder = DelegateProcessBuilder(
           tool: tool, prompt: prompt, resumeSessionId: nil,
           environment: environment, store: store)
       let (process, _, outputPipe) = try builder.build(outputMode: .capture)
       process.standardInput = FileHandle.nullDevice  // 已由 builder 設定，此行不需
       try process.run()
       process.waitUntilExit()
       let rawOutput = 讀取 outputPipe 內容
       let (positions, parseSuccess) = MagiResponseParser.parse(rawOutput, subtopics)
       responses.append(MagiAgentResponse(...))
       print "{tool} responded ({parseSuccess ? "parsed" : "fallback"})"
     end for

     let consensusSnapshot = 計算 consensus（deterministic 規則）
     magiRun.rounds.append(MagiRound(...))
     try magiRun.save(store: store)  // 每輪存一次，斷電不丟
   end for

   magiRun.status = .maxRoundsReached
   magiRun.finalConsensus = 最後一輪的 consensusSnapshot
   try magiRun.save(store: store)
   輸出 markdown 報告（to stdout 和 --output 檔案）
   return magiRun
   ```

2. Consensus 計算函數（private）：
   ```
   func computeConsensus(responses, subtopics) -> [ConsensusItem]:
     for subtopic in subtopics:
       收集各 tool 對此 subtopic 的 position（從 responses 的 positions 中找）
       若 <2 個 tool 有 position → pending
       若全部 agree → agreed
       若 ≥2 agree（含 conditional）→ majority
       否則 → disputed
   ```

3. Markdown 報告格式：
   ```markdown
   # Magi Consensus Report

   **Topic**: {topic}
   **Participants**: {tools}
   **Rounds**: {N}
   **Date**: {date}

   ## Consensus

   | Sub-topic | Status | Details |
   |-----------|--------|---------|
   | ... | agreed/disputed/... | Claude: agree, Codex: agree, Gemini: conditional |

   ## Round Details
   ### Round 1
   #### {Tool}
   {raw output excerpt}
   **Positions**: ...

   ---
   *This report reflects model consensus, not verified facts.*
   ```

### Step 8：新建 MagiCommand.swift

1. 定義 `MagiCommand: ParsableCommand`，如介面合約所述
2. `run()` 實作：
   ```
   let store = EnvironmentStore.default
   let envName = environment ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]

   // 決定參與 tools
   var tools: [Tool] = []
   if claude { tools.append(.claude) }
   if codex { tools.append(.codex) }
   if gemini { tools.append(.gemini) }
   if tools.isEmpty { tools = Tool.allCases }  // 全選但過濾不可用

   // 檢查 tool 可用性（which）
   tools = tools.filter { isToolAvailable($0) }
   guard tools.count >= 2 else {
       throw ValidationError(L10n.Magi.insufficientTools)
   }

   // 子議題拆分：第一版由 topic 本身作為唯一 subtopic
   // （使用者可在 topic 中用分號分隔多個子議題）
   let subtopics = topic.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }

   let result = try MagiOrchestrator.run(
       topic: topic, subtopics: subtopics, tools: tools,
       maxRounds: rounds, environment: envName, store: store,
       outputPath: output)
   ```

3. `isToolAvailable()` private helper：
   ```
   func isToolAvailable(_ tool: Tool) -> Bool {
       let process = Process()
       process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
       process.arguments = ["which", tool.rawValue]
       process.standardOutput = FileHandle.nullDevice
       process.standardError = FileHandle.nullDevice
       try? process.run()
       process.waitUntilExit()
       return process.terminationStatus == 0
   }
   ```

### Step 9：註冊 MagiCommand

在 `OrreryCommand.swift` 的 `subcommands` 陣列中，在 `DelegateCommand.self` 之後加入 `MagiCommand.self`。

### Step 10：新增 L10n

在 `en.json`、`zh-Hant.json`、`ja.json` 中新增 `magi.*` keys（如介面合約表格所列）。在 `l10n-signatures.json` 中新增對應的 `Magi.*` signatures。

---

## 失敗路徑

### 工具不足（不可恢復）
- 條件：過濾不可用 tool 後 <2 個
- `MagiCommand.run()` throw `ValidationError(L10n.Magi.insufficientTools)` → exit 1

### DelegateProcessBuilder.build() 失敗（不可恢復）
- 條件：environment 不存在或 Gemini HOME wrapper 建立失敗
- `builder.build()` throw `EnvironmentStore.Error` → `MagiOrchestrator` 向上拋 → exit 1

### 子進程執行失敗（可恢復）
- 條件：`process.run()` throw（binary 不存在等）
- `MagiOrchestrator` catch → 將該 tool 的 response 標記為 `rawOutput: "", positions: nil, parseSuccess: false` → 繼續其他 tool
- 不中斷整輪討論

### JSON 解析失敗（可恢復）
- 條件：agent 回應不包含有效 JSON
- `MagiResponseParser.parse()` → fallback regex → 若仍失敗 → `positions: nil, parseSuccess: false`
- 該 tool 對相關 subtopic 記為 `pending`
- 不中斷討論

### MagiRun 儲存失敗 [inferred]（可恢復）
- 條件：`~/.orrery/magi/` 無法建立或寫入
- `try magiRun.save()` → `MagiOrchestrator` 用 `try?` 吞掉，印 warning 到 stderr → 繼續
- 報告仍輸出到 stdout / `--output`

### --output 寫入失敗 [inferred]（可恢復）
- 條件：指定的 `--output` 路徑無法寫入
- 印 warning 到 stderr，report 仍輸出到 stdout

---

## 不改動的部分

- `Sources/OrreryCore/Helpers/SessionMapping.swift` — magi 不使用 SessionMapping
- `Sources/OrreryCore/Helpers/SessionPicker.swift`
- `Sources/OrreryCore/Helpers/SessionSpecifier.swift`
- `Sources/OrreryCore/Helpers/SessionResolver.swift`
- `Sources/OrreryCore/Commands/SessionsCommand.swift`
- `Sources/OrreryCore/Commands/ResumeCommand.swift`
- `Sources/OrreryCore/Commands/RunCommand.swift` — 不使用 DelegateProcessBuilder
- `Sources/OrreryCore/Models/Tool.swift`
- `Sources/OrreryCore/MCP/MCPServer.swift` — MCP 整合延至 v2
- `Sources/OrreryCore/UI/SingleSelect.swift`

---

## 驗收標準

### 功能合約

- [ ] `swift build` 成功
- [ ] `orrery magi --help` 顯示正確的 help text
- [ ] `orrery magi "test topic"` 啟動討論，依序呼叫 Claude → Codex → Gemini（或已登入的子集）
- [ ] 每輪結束後，console 顯示進度（`Round N/M`、`Waiting for {tool}...`、`{tool} responded`）
- [ ] 3 輪結束後輸出 markdown 共識報告到 stdout
- [ ] `--output report.md` 將報告寫入檔案
- [ ] `--rounds 1` 只跑 1 輪
- [ ] `--claude --codex` 只讓 Claude 和 Codex 參與
- [ ] 單一 tool flag（如 `--claude`）→ exit 1，stderr 顯示 "At least 2 tools"
- [ ] 討論紀錄 JSON 存在 `~/.orrery/magi/<uuid>.json`
- [ ] JSON 中 `rounds` 陣列長度 = 實際輪數
- [ ] JSON 中 v2 預留欄位（`votes`）存在且為 null
- [ ] `DelegateProcessBuilder` 既有 call site（`orrery delegate --claude "hello"`）行為不變
- [ ] markdown 報告結尾包含 "*This report reflects model consensus, not verified facts.*"

### 測試指令

```bash
# 1. Build
swift build

# 2. Help text
swift run orrery magi --help

# 3. Insufficient tools (only 1 tool)
swift run orrery magi --claude "test" 2>&1 | grep "At least 2"
echo "exit: $?"  # 0 (grep found match)

# 4. Full run (needs all tools logged in)
swift run orrery magi --rounds 1 "Should we use tabs or spaces?"

# 5. Output to file
swift run orrery magi --rounds 1 --output /tmp/magi-test.md "tabs vs spaces"
cat /tmp/magi-test.md | head -5

# 6. Verify run storage
ls ~/.orrery/magi/*.json | head -1

# 7. Verify v2 fields exist in JSON
cat $(ls -t ~/.orrery/magi/*.json | head -1) | grep '"votes"'

# 8. Regression: delegate still works
swift run orrery delegate --claude "echo hello"

# 9. Cleanup
rm -f /tmp/magi-test.md
```

---

## 已知限制

1. **第一版僅 Serial 執行**：每輪依序呼叫各 tool，不支援 parallel。`--parallel` 延至 v2。
2. **無 AI judge**：共識判定為 deterministic 多數決，不使用 AI judge。`--judge` 延至 v2。
3. **無自動收斂**：固定 `--rounds N` 輪，不自動偵測收斂。`--until-converged` 延至 v2。
4. **子議題拆分簡易**：第一版用分號分隔 topic 字串作為 subtopics。未來可改為 AI 自動拆分。
5. **JSON 解析不保證成功**：模型可能不遵守 JSON 格式要求。regex fallback 盡力提取但可能失敗。
6. **多模型共識 ≠ 事實正確**：報告應標明這是「模型間的共識判定」，非已驗證事實。
7. **MCP 整合延後**：`orrery_magi` MCP tool 不在此 task 範圍。
8. **兩階段投票延後**：v2 的 `--deep-consensus` 功能已在 schema 預留欄位（`MagiVote`、`MagiRound.votes`），但 v1 不實作。
9. **`--allowedTools Bash` 硬編碼**：Claude delegate 仍只允許 Bash tool，繼承自 `DelegateProcessBuilder`。
10. **依賴前置 task**：無前置 task 依賴（`delegate --session` task 已完成）。
