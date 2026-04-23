現在我有足夠的上下文來產出 spec。

# Magi 功能從 Orrery 拆分為獨立專案（Phase 1：repo 內模組化）

## 來源

`docs/discussions/2026-04-17-magi-extraction.md`

## 目標

將目前內嵌於 `OrreryCore` 的 Magi 多模型辯論功能抽離為獨立的 `OrreryMagi` Swift library target（同 repo、依賴 `OrreryCore`），以驗證 Magi 的邊界可基於 Public API 運作、為未來拆 repo 鋪路，同時保留最大 optionality。本輪**不**拆 repo、**不**搬 L10n 字串、**不**改變使用者面的 `orrery magi` / MCP / slash command 體驗；改動以 (1) 清理 `OrreryCore` 對 Magi 的 public surface、(2) 引入 `AgentExecutor` protocol 作為 Magi 對宿主的唯一執行介面、(3) 重構 package graph 避免 `OrreryCore ↔ OrreryMagi` cycle 為重點。落地後需附 `docs/CONTRACT-OrreryMagi.md` 作為未來 public API 變動的單一真實來源，並於 2026-07-01 做一次 Go/No-Go review 決定是否進 Phase 3（獨立 binary）。

## 介面合約（Interface Contract）

### 1. `public struct SessionEntry`（新抽出，top-level）

**所在位置**：`Sources/OrreryCore/Models/SessionEntry.swift`（新檔）[inferred]

```swift
public struct SessionEntry {
    public let id: String
    public let firstMessage: String
    public let lastTime: Date?
    public let userCount: Int
    public init(id: String, firstMessage: String, lastTime: Date?, userCount: Int)
}
```

- **觀察不變式**：欄位與原 `SessionsCommand.SessionEntry` 完全一致；無 presentation-only 欄位（如 `"(empty)"` fallback 屬於 parser 內部行為，不進型別定義）。
- **Source compatibility**：`SessionsCommand` 內保留 `public typealias SessionEntry = OrreryCore.SessionEntry`，既有 call sites 零修改。
- **擁有權**：由 `OrreryCore` 擁有；`OrreryMagi` 以讀者身分消費。
- **可選擴充**：`Codable` conformance（Gemini 建議）— 本輪**不加**，留待 Phase 3 出現序列化需求再加 [inferred]。

### 2. `SessionResolver.findScopedSessions`（access level 變更）

```swift
public static func findScopedSessions(
    tool: Tool,
    cwd: String,
    store: EnvironmentStore,
    activeEnvironment: String?
) -> [SessionEntry]
```

- **變更**：`internal static` → `public static`；回傳型別隨 `SessionEntry` 抽出後為 top-level `[SessionEntry]`。
- **觀察不變式**：行為與現況一致（shared + active env scope，跳過 symlinked dirs）。
- **Throws**：不 throw；findScopedSessions 內部只讀檔案系統，失敗 silently 回空陣列（維持現況）。

### 3. `public protocol AgentExecutor`（新介面，Magi 的唯一執行通道）

**所在位置**：`Sources/OrreryCore/AgentExecutor/AgentExecutor.swift`（新檔）[inferred]

```swift
public protocol AgentExecutor {
    func execute(request: AgentExecutionRequest) throws -> AgentExecutionResult
    func cancel()
}

public struct AgentExecutionRequest {
    public let tool: Tool
    public let prompt: String
    public let resumeSessionId: String?
    public let timeout: TimeInterval
    public init(tool: Tool, prompt: String, resumeSessionId: String?, timeout: TimeInterval)
}

public struct AgentExecutionResult {
    public let tool: Tool
    public let rawOutput: String
    public let stderrOutput: String
    public let exitCode: Int32
    public let timedOut: Bool
    public let sessionId: String?
    public let duration: TimeInterval
    public let metadata: [String: String]  // forward-compat，Phase 1 回傳空 dict
    public init(tool: Tool, rawOutput: String, stderrOutput: String, exitCode: Int32,
                timedOut: Bool, sessionId: String?, duration: TimeInterval,
                metadata: [String: String])
}
```

- **協定責任**（實作必須吃掉的事情）：
  - timeout 排程與終止
  - stderr drain（避免 pipe blocking）
  - stdout drain
  - session-id 前後 snapshot diff
  - cancellation（`cancel()` 對應目前 `MagiAgentRunner.terminate()`）
- **`Tool` 維持現狀**：短期不抽成 `agentIdentifier: String`（D12）。Magi 的預設 participants 仍仰賴 `Tool.allCases`。
- **`sessionId` 一級欄位保留**：Magi 持久化 run 時明確需要（`MagiOrchestrator.swift:33-48,124-127`）。
- **streaming 延後**：本輪不加 async stream / event API；`metadata` 作為未來擴充的 forward-compat 欄位。

### 4. `public struct ProcessAgentExecutor: AgentExecutor`（預設實作）

**所在位置**：`Sources/OrreryCore/AgentExecutor/ProcessAgentExecutor.swift`（新檔）[inferred]

```swift
public struct ProcessAgentExecutor: AgentExecutor {
    public let environment: String?
    public let store: EnvironmentStore
    public init(environment: String?, store: EnvironmentStore)
    public func execute(request: AgentExecutionRequest) throws -> AgentExecutionResult
    public func cancel()
}
```

- **內部實作**：包裝 `DelegateProcessBuilder` + `SessionResolver.findScopedSessions`，把目前 `MagiAgentRunner.run(timeout:)` 的邏輯整段搬進來（I/O drain、timeout、session diff、退出判斷）。
- **不對外暴露** `DelegateProcessBuilder.build()` 的 `(Process, StdinMode, Pipe?)` triple — 由 executor 內部吸收。
- **Throws**：Process launch failure → rethrow；其餘（timeout、non-zero exit）不 throw，以 `AgentExecutionResult.timedOut` / `exitCode` 表達。
- **Cancellation**：`cancel()` 呼叫內部持有的 `Process.terminate()`；若未啟動則 no-op [inferred]。

### 5. `public func MagiMCPTools.register(on:)`（MCP 組裝掛載點）

**所在位置**：`Sources/OrreryMagi/MagiMCPTools.swift`（新檔）[inferred]

```swift
public enum MagiMCPTools {
    public static func register(on server: MCPServer)
}
```

- **呼叫者**：`orrery` executable target 的啟動流程（**非** `OrreryCore.MCPServer` 內部），以避免 `OrreryCore → OrreryMagi` 反向依賴。
- **行為不變**：註冊後對 MCP client 暴露的 `orrery_magi` tool 名稱、參數、回傳格式與現況完全一致（不改變使用者面）。

### 6. `MagiOrchestrator.generateReport`（access level 變更）

- **變更**：`internal static` → `public static`（供 `MagiCommand --spec` 路徑在 executable target 呼叫）[inferred]。
- **替代方案**：若暴露 `generateReport` 不妥，`OrreryMagi` 內提供 `MagiRunFacade.generateReport(_:)` facade。選擇在實作時決定。

### 7. `OrreryMagi` Library Product

**`Package.swift`** 新增：

```swift
.library(name: "OrreryMagi", targets: ["OrreryMagi"])
```

- **公開宣告**：即使 Phase 1 無外部消費者，仍聲明「可被外部依賴」（D10）。
- **依賴**：`OrreryMagi` → `OrreryCore`（單向）；`orrery` executable → `OrreryCore` + `OrreryMagi`。

### Error / L10n keys（維持現狀）

- `L10n.Magi.*` 字串**不搬**；`OrreryMagi` source 直接 `import OrreryCore` 使用 `L10n.Magi.*`（D9）。
- 既有錯誤訊息：`L10n.Magi.sessionIdNotFound(tool.rawValue)` 等 key 不變。

## 改動檔案

| File Path | Change Description |
|---|---|
| `Package.swift` | 新增 `OrreryMagi` target 與 `.library(name: "OrreryMagi")` product；`orrery` executable 依賴增加 `OrreryMagi` |
| `Sources/OrreryCore/Models/SessionEntry.swift` | 新檔：抽出 top-level `public struct SessionEntry` |
| `Sources/OrreryCore/Commands/SessionsCommand.swift` | 移除巢狀 `SessionEntry` 定義，改 `public typealias SessionEntry = OrreryCore.SessionEntry`；parser fallback `"(empty)"` 維持不動 |
| `Sources/OrreryCore/Helpers/SessionResolver.swift` | `findScopedSessions` 改 `public static`；回傳型別隨 typealias 維持 `[SessionEntry]` |
| `Sources/OrreryCore/AgentExecutor/AgentExecutor.swift` | 新檔：定義 `public protocol AgentExecutor` + `AgentExecutionRequest` + `AgentExecutionResult` |
| `Sources/OrreryCore/AgentExecutor/ProcessAgentExecutor.swift` | 新檔：`public struct ProcessAgentExecutor`；把 `MagiAgentRunner.run` 的 I/O drain / timeout / session diff 邏輯搬入 |
| `Sources/OrreryMagi/MagiOrchestrator.swift` | 從 `Sources/OrreryCore/Magi/` 搬過來；`generateSummarizedVerdict` 內 `DelegateProcessBuilder` 直用改走注入的 `AgentExecutor`；`generateReport` 改 `public`（或提供 facade） |
| `Sources/OrreryMagi/MagiAgentRunner.swift` | 從 `Sources/OrreryCore/Magi/` 搬過來；改為 thin wrapper over `AgentExecutor`，移除直接 `Process` / `DelegateProcessBuilder` 使用；`terminate()` 委派給 executor.cancel() |
| `Sources/OrreryMagi/MagiRun.swift` | 從 `Sources/OrreryCore/Magi/` 搬過來；無邏輯變動 |
| `Sources/OrreryMagi/MagiPromptBuilder.swift` | 從 `Sources/OrreryCore/Magi/` 搬過來；無邏輯變動 |
| `Sources/OrreryMagi/MagiResponseParser.swift` | 從 `Sources/OrreryCore/Magi/` 搬過來；無邏輯變動 [inferred] |
| `Sources/OrreryMagi/MagiMCPTools.swift` | 新檔：把 `MCPServer.swift` 內 `orrery_magi` 的 register / handler 邏輯搬來，公開 `MagiMCPTools.register(on:)` |
| `Sources/OrreryCore/MCP/MCPServer.swift` | 移除 `orrery_magi` tool 的直接註冊與 handler；保留 `MCPServer` 公開 API 讓外部 target 可 register tools（若尚不 public 則最小化改為 public）|
| `Sources/orrery/main.swift` | 啟動流程中呼叫 `MagiMCPTools.register(on: server)`（適用 `mcp-server` 子命令路徑）[inferred] |
| `Sources/OrreryCore/Commands/OrreryCommand.swift` | `MagiCommand` 子命令註冊點保持，但改為從 `OrreryMagi` 匯入（若 `MagiCommand` 需搬到 executable target 以避免 cycle，則此處只保留 `OrreryCommand` 的 subcommand array 宣告）|
| `Sources/OrreryCore/Commands/MagiCommand.swift` | **搬到** `Sources/orrery/MagiCommand.swift`（executable target）以打破 `OrreryCore → OrreryMagi` 反向依賴；internal 邏輯改 `import OrreryMagi` |
| `Sources/OrreryCore/Commands/MCPSetupCommand.swift` | **不動**（Phase 1 仍寫入 `/orrery:magi` slash command；與 `MCPServer.swift:128-162` 的 `orrery_magi` tool 名稱對齊）|
| `Sources/OrreryCore/Resources/Localization/*.json` | **不動**（D9：L10n Phase 1 不分檔） |
| `Tests/OrreryTests/...` | 新增 `AgentExecutor` / `ProcessAgentExecutor` regression tests；新增 mock executor 測試 Magi 路徑；既有測試不變 |
| `docs/CONTRACT-OrreryMagi.md` | 新檔：明列 public surface 契約、間接監控項、2026-07-01 Go/No-Go review 錨點 |
| `CHANGELOG.md` | 記錄本次 internal refactor；註明「使用者面無變化」 |

## 實作步驟

### Step 1 — `Sources/OrreryCore/Models/SessionEntry.swift`（新）+ `Sources/OrreryCore/Commands/SessionsCommand.swift`（typealias）

1. 建立 `Models/` 目錄（若尚無）[inferred]。
2. 新增 `SessionEntry.swift`，定義 `public struct SessionEntry` 含 `id / firstMessage / lastTime / userCount` 四欄位 + `public init(...)`。
3. 刪除 `SessionsCommand.SessionEntry` 巢狀定義；替換為 `public typealias SessionEntry = OrreryCore.SessionEntry`。
4. 驗證 `parseClaudeSession` / `parseCodexSession` / `parseGeminiSession` 內部 `SessionEntry(...)` 初始化呼叫與新 init 相容（欄位順序一致）。
5. parser 內 `firstMessage ?? "(empty)"` fallback 維持現況 — 屬 parser 職責，不納入型別定義。

### Step 2 — `Sources/OrreryCore/Helpers/SessionResolver.swift`

1. `findScopedSessions(tool:cwd:store:activeEnvironment:)` 的 `internal static` 改為 `public static`。
2. 回傳型別宣告由 `[SessionsCommand.SessionEntry]` 改為 `[SessionEntry]`（top-level，透過 Step 1 typealias 保 source compatibility）。
3. 內部呼叫的 `findScopedClaudeSessions` 等 private helpers access level 不變。
4. `resolve(_:tool:cwd:store:activeEnvironment:)` 已 public，無需調整。

### Step 3 — `Sources/OrreryCore/AgentExecutor/AgentExecutor.swift`（新）

1. 建立 `AgentExecutor/` 目錄 [inferred]。
2. 定義 `public protocol AgentExecutor { func execute(request:) throws -> AgentExecutionResult; func cancel() }`。
3. 定義 `public struct AgentExecutionRequest`（tool / prompt / resumeSessionId / timeout）+ public init。
4. 定義 `public struct AgentExecutionResult`（所有欄位同 `MagiAgentRunner.Result` + `metadata: [String: String]`）+ public init。
5. 不實作 async / streaming；不抽 `agentIdentifier` 字串；不加 `Codable` conformance。

### Step 4 — `Sources/OrreryCore/AgentExecutor/ProcessAgentExecutor.swift`（新）

1. `public struct ProcessAgentExecutor: AgentExecutor`，持有 `environment: String?` + `store: EnvironmentStore` + 私有 `process: Process?`（可變，供 cancel 使用）[inferred]。
2. `execute(request:)` 內實作邏輯完整複製自 `MagiAgentRunner.run(timeout:)`：
   - 前置：以 `SessionResolver.findScopedSessions(...)` 取得 `preSnapshot`。
   - 建 `DelegateProcessBuilder(tool:prompt:resumeSessionId:environment:store:)`；呼叫 `.build(outputMode: .capture)` 拿 triple；**保留在 executor 內部**，不外流。
   - 覆寫 `process.standardError = stderrPipe`；若 builder 未給 outputPipe 則指派自建 stdoutPipe。
   - 前 drain：在 `process.run()` 之前啟動 stdout / stderr 背景 drain。
   - 排程 timeout work item：`DispatchQueue.global().asyncAfter(deadline: .now() + request.timeout)` → `process.terminate()`。
   - 啟動 process → `try process.run()`（失敗 return `AgentExecutionResult` with `exitCode: -1`, `stderrOutput: "Failed to launch: ..."`）。
   - `waitUntilExit` → cancel timeoutWork → 等 drain groups。
   - 計算 `timedOut = (terminationReason == .uncaughtSignal && exitCode == 15)`。
   - 後置：`SessionResolver.findScopedSessions` 取 `postSnapshot`，diff = post − pre；`sessionId = diff.count == 1 ? diff.first : nil`。
   - 若 `sessionId == nil && !timedOut && exitCode == 0`：stderr 印 `L10n.Magi.sessionIdNotFound(tool.rawValue)`（行為與現況一致）。
   - 回傳 `AgentExecutionResult(..., metadata: [:])`。
3. `cancel()`：呼叫當前 `process?.terminate()`；若 process 尚未建立或已結束，no-op。
4. **不變式**：`ProcessAgentExecutor` 必須吃掉所有 I/O drain 與 timeout 責任；`DelegateProcessBuilder` 的 `(Process, StdinMode, Pipe?)` triple 不出現在 public API 上。

### Step 5 — 建立 `Sources/OrreryMagi/` target 與 `Package.swift` 重構

1. `Package.swift`：
   - `products` 陣列加 `.library(name: "OrreryMagi", targets: ["OrreryMagi"])`。
   - `targets` 陣列新增 `.target(name: "OrreryMagi", dependencies: ["OrreryCore"], path: "Sources/OrreryMagi")`。
   - `orrery` executableTarget 的 `dependencies` 加 `"OrreryMagi"`。
   - test target 同時依賴兩者：`dependencies: ["OrreryCore", "OrreryMagi"]`。
2. 建立 `Sources/OrreryMagi/` 目錄；搬 `Sources/OrreryCore/Magi/*`（`MagiOrchestrator.swift` / `MagiAgentRunner.swift` / `MagiRun.swift` / `MagiPromptBuilder.swift` / `MagiResponseParser.swift`）過去。
3. 每個被搬的檔案加 `import OrreryCore`。
4. **驗證 cycle 不存在**：`OrreryCore` 內不得 `import OrreryMagi`。

### Step 6 — `Sources/OrreryMagi/MagiAgentRunner.swift`（改為 AgentExecutor consumer）

1. `struct MagiAgentRunner` 改為持有 `executor: any AgentExecutor`。
2. `init(tool:prompt:resumeSessionId:environment:store:)` 內部 `self.executor = ProcessAgentExecutor(environment: environment, store: store)`（預設）；或改為外部注入（供測試 mock）[inferred]。
3. `run(timeout:) -> Result`：
   - 建 `AgentExecutionRequest(tool:prompt:resumeSessionId:timeout:)`。
   - 呼叫 `try? executor.execute(request:)`。
   - 把 `AgentExecutionResult` 欄位 1:1 對應到 `MagiAgentRunner.Result`（舊型別），保 source compatibility。
   - 若 `execute` throw → 回 `Result(..., exitCode: -1, stderrOutput: "Failed to launch: ...")`。
4. `terminate()` → `executor.cancel()`。
5. 刪除舊的 `stdoutPipe / stderrPipe / process / cwd` 欄位與 `run` 內 drain 邏輯（全移到 `ProcessAgentExecutor`）。

### Step 7 — `Sources/OrreryMagi/MagiOrchestrator.swift`（generateSummarizedVerdict 走 executor）

1. `generateSummarizedVerdict(run:tools:environment:store:)` 不再直接 `new DelegateProcessBuilder`。
2. 建 `let executor = ProcessAgentExecutor(environment: environment, store: store)`。
3. 建 `AgentExecutionRequest(tool: facilitator, prompt: prompt, resumeSessionId: nil, timeout: <既有值>)` [inferred：保留現況 timeout 值]。
4. 呼叫 `executor.execute(request:)` 取得 `AgentExecutionResult`。
5. JSON 解析邏輯（`output.range(of: "{\"decisions\"")`...`JSONDecoder().decode(FinalVerdict.self)`）不變；來源由 `result.rawOutput` 取得。
6. 失敗路徑維持：找不到 JSON → `throw NSError(domain: "MagiOrchestrator", code: 1, userInfo: ["NSLocalizedDescriptionKey": "No valid FinalVerdict JSON found"])`。
7. `generateReport` 改 `public static`（或在 `OrreryMagi` 暴露 facade），供 executable target 的 `MagiCommand --spec` 路徑呼叫。

### Step 8 — 搬 `MagiCommand` 到 executable target（打破 cycle）

1. 建 `Sources/orrery/MagiCommand.swift`；把 `Sources/OrreryCore/Commands/MagiCommand.swift` 內容搬過去。
2. 新 `MagiCommand.swift` `import OrreryCore` + `import OrreryMagi`。
3. `Sources/OrreryCore/Commands/MagiCommand.swift` 刪除（確認 `OrreryCommand.subcommands` 宣告不再引用舊位置的型別）。
4. `Sources/OrreryCore/Commands/OrreryCommand.swift`：
   - 若 `subcommands` 陣列內寫死 `MagiCommand.self`，改為：由 executable target 啟動時注入（例如改 `OrreryCommand` 為 open class，於 `Sources/orrery/main.swift` 內做 late-binding）[inferred — 實作時以最小改動為準]。
   - 替代方案：若 `ArgumentParser` 不支援 runtime 注入 subcommand，把整個 `OrreryCommand` 定義也搬到 executable target（Q12 實作時定）。
5. 驗證 `orrery magi`、`orrery magi --help`、`orrery magi --spec`、`orrery magi resume` 所有既有參數與輸出行為一致。

### Step 9 — `Sources/OrreryMagi/MagiMCPTools.swift` + MCP 組裝點上移

1. 新檔 `MagiMCPTools.swift`：
   - `public enum MagiMCPTools`
   - `public static func register(on server: MCPServer)` — 把 `Sources/OrreryCore/MCP/MCPServer.swift:128-162` 的 `orrery_magi` tool schema 宣告與 `:247-267` 的 handler 邏輯搬過來。
2. `Sources/OrreryCore/MCP/MCPServer.swift`：
   - 移除 `orrery_magi` tool 的註冊與 handler。
   - 確認 `MCPServer.registerTool(...)` / `MCPServer.registerHandler(...)` 等 API 為 `public`（若目前 internal 需改 public）[inferred]。
   - 其他 tools（非 Magi）原地保留。
3. `Sources/orrery/main.swift`（或 `MCPServerCommand.swift` 對應的執行路徑）：啟動 MCP server 後呼叫 `MagiMCPTools.register(on: server)`。
4. `orrery_magi` tool 名稱、arguments schema、回傳格式**完全不變**（兼容現有 client）。

### Step 10 — Tests + CHANGELOG + `CONTRACT-OrreryMagi.md`

1. 新增 `Tests/OrreryTests/AgentExecutorTests.swift`：
   - Mock executor（回傳固定 `AgentExecutionResult`）驗證 `MagiAgentRunner` 邏輯。
   - Regression test：`ProcessAgentExecutor` timeout / stderr drain / session-id diff 路徑（可用最小 shell script 當 fake tool）[inferred]。
2. 既有 Magi 相關測試若有 → 改 import `OrreryMagi`，其餘不動。
3. 新增 `docs/CONTRACT-OrreryMagi.md`，至少含：
   - **Direct public surface**：`SessionEntry`、`SessionResolver.findScopedSessions`、`AgentExecutor` / `AgentExecutionRequest` / `AgentExecutionResult`、`ProcessAgentExecutor`、`EnvironmentStore.homeURL`、`Tool` enum、`MCPServer.registerTool/registerHandler`（若改 public）。
   - **Indirect monitored surface**：`DelegateProcessBuilder`（Magi 透過 `ProcessAgentExecutor` 間接依賴）。
   - **Breaking change 定義**：移除 public 型別 / rename / 語義變更算 breaking；`Tool` enum **加 case 不算 breaking**（D14）。
   - **Go/No-Go review date**：`2026-07-01`（D15），review 時依 D13 三條觸發條件評估是否進 Phase 3。
4. `CHANGELOG.md` 加一節：「Internal: extracted Magi to `OrreryMagi` library target; no user-facing changes to `orrery magi` / MCP tool / slash command.」

## 失敗路徑

1. **`ProcessAgentExecutor.execute` — Process launch failure**
   - `try process.run()` throws → executor **不** rethrow；回傳 `AgentExecutionResult(exitCode: -1, stderrOutput: "Failed to launch: \(error)", timedOut: false, sessionId: nil, metadata: [:])`。
   - `MagiAgentRunner.run` 收到後對應為 `Result(exitCode: -1)`；`MagiOrchestrator` 把該輪視為 agent 失敗，繼續其他 agents（維持現況語意）。
   - **可恢復**：是（單一 agent 失敗不中止整個 Magi run）。

2. **`ProcessAgentExecutor.execute` — Timeout**
   - DispatchWorkItem 觸發 `process.terminate()` → process 收 SIGTERM → `terminationReason == .uncaughtSignal && exitCode == 15` → `timedOut = true`。
   - 回傳 `AgentExecutionResult(timedOut: true, ...)`，不 throw。
   - `MagiOrchestrator` 依現況把 timed-out 輪次標記為 no-response [inferred]。

3. **`ProcessAgentExecutor.execute` — session-id diff 找不到**
   - `diff.count != 1` → `sessionId = nil` → executor 對 stderr 印 `L10n.Magi.sessionIdNotFound(tool.rawValue)`。
   - 不 throw；不影響該輪 agent 的輸出判讀；但該輪 session **無法 resume**。
   - **可恢復**：是（使用者後續可手動提供 session id）。

4. **`MagiOrchestrator.generateSummarizedVerdict` — executor 無 `{"decisions"` JSON**
   - `output.range(of: "{\"decisions\"")` == nil → `throw NSError(domain: "MagiOrchestrator", code: 1, userInfo: [NSLocalizedDescriptionKey: "No valid FinalVerdict JSON found"])`。
   - 呼叫端（`MagiOrchestrator.run` 或 `MagiCommand`）rethrow 到 `MagiCommand.run()`；命令以 non-zero exit 結束；stderr 印錯誤訊息。
   - **可恢復**：否（final verdict 必要）；使用者需重跑或改用其他 facilitator model。

5. **`SessionResolver.resolve` — 找不到指定 session**
   - `.last` 空集合 → `throw ValidationError(L10n.Delegate.resumeNotFound)`。
   - `.index(n)` 越界 → `throw ValidationError(L10n.Resume.indexOutOfRange(n, entries.count))`。
   - `.id(s)` 未命中 → `throw ValidationError("session '\(s)' not found")`。
   - 行為完全不變（僅 access level 改 public）。

6. **`Package.swift` — cycle 形成**
   - 若 Step 8 漏搬 `MagiCommand` → `OrreryCore.OrreryCommand` 仍參考 `MagiCommand` → 需 `import OrreryMagi` → `OrreryMagi → OrreryCore` cycle → SwiftPM build 失敗（error: cyclic dependency declaration found）。
   - **非可恢復**（必須完成 Step 8 搬家才能通過 build）。

7. **`MCPServer.registerTool` 未 public**
   - `MagiMCPTools.register(on:)` 無法從 `OrreryMagi` 呼叫 → 編譯失敗。
   - 修復：Step 9.2 把必要 registration API 改 `public`；或把 `MagiMCPTools` 搬到 `orrery` executable target（備案）[inferred]。

## 不改動的部分

**明確不得修改的檔案 / 行為**：

- `Sources/OrreryCore/Resources/Localization/en.json` / `zh-Hant.json` / `ja.json` 中的 `magi.*` keys — **字串、key、槽位完全不動**（D9）。
- `Sources/OrreryCore/Resources/Localization/l10n-signatures.json` — 不動。
- `Plugins/L10nCodegenTool/main.swift`、`Plugins/L10nCodegen/plugin.swift` — **不動**（D9：shard-aware 重構另開 follow-up，不進本輪 critical path）。
- `Sources/OrreryCore/Commands/MCPSetupCommand.swift:133-155` — 寫入 `/orrery:magi` slash command 的邏輯不動（Phase 1 slash command 命名保持）。
- `Sources/OrreryCore/Delegate/DelegateProcessBuilder.swift` — 不動（D14：標為穩定 + 間接監控 surface；本輪僅被 `ProcessAgentExecutor` 內部使用）。
- `Sources/OrreryCore/Commands/OrreryCommand.swift` 中 `version:` 欄位 — 不動（非 release commit）。
- `Sources/OrreryCore/MCP/MCPServer.swift` 中 `currentVersion()` — 不動。
- `CHANGELOG.md` 只加「internal refactor」條目，不 bump version。
- `docs/index.html` / `docs/zh_TW.html` badge — 不動。
- `homebrew-orrery/Formula/orrery.rb` — 不動（無 release）。

**隱含的行為不變保證**：

- `orrery magi <topic>` / `orrery magi resume <id>` / `orrery magi --spec` 的 CLI 參數、stdout / stderr 格式、persistence 路徑、exit code **全部不變**。
- MCP tool `orrery_magi` 的 arguments schema、回傳 JSON 結構不變。
- `/orrery:magi` slash command 內容不變。
- `MagiRun` JSON 檔格式（schema、欄位名、排序）不變 — 既有 run 檔可被新版讀取。
- L10n keys 的 signatures 維持，`LocalizationTests` 不需調整。

## 驗收標準

### 功能契約檢查清單

- [ ] `Package.swift` 含 `.library(name: "OrreryMagi", targets: ["OrreryMagi"])` product 宣告
- [ ] `Sources/OrreryMagi/` 存在，含 `MagiOrchestrator.swift` / `MagiAgentRunner.swift` / `MagiRun.swift` / `MagiPromptBuilder.swift` / `MagiResponseParser.swift`
- [ ] `Sources/OrreryCore/Magi/` 目錄已刪除（或為空）
- [ ] `Sources/OrreryCore/Models/SessionEntry.swift` 存在，定義 top-level `public struct SessionEntry`
- [ ] `SessionsCommand.SessionEntry` 以 `typealias` 保留，舊 call sites 不需修改
- [ ] `SessionResolver.findScopedSessions` 為 `public static`
- [ ] `Sources/OrreryCore/AgentExecutor/AgentExecutor.swift` 定義 `public protocol AgentExecutor` + `AgentExecutionRequest` + `AgentExecutionResult`（含 `metadata: [String: String]`）
- [ ] `ProcessAgentExecutor` 實作 protocol；完整吃掉 timeout / stderr drain / session diff / cancel 四項責任
- [ ] `DelegateProcessBuilder.build()` 的 triple 不出現在任何 `public` signature 中
- [ ] `MagiAgentRunner` 不再直接持有 `Process` / `Pipe` / `DelegateProcessBuilder`；改透過 `AgentExecutor`
- [ ] `MagiOrchestrator.generateSummarizedVerdict` 不再直接 `new DelegateProcessBuilder`；走 `AgentExecutor`
- [ ] `MagiMCPTools.register(on:)` 存在；`MCPServer.swift` 內無 `orrery_magi` 的直接註冊
- [ ] MCP tool `orrery_magi` 的組裝在 executable target（`orrery`）發生，不在 `OrreryCore`
- [ ] `MagiCommand` 搬到 executable target，`OrreryCore` 不 import `OrreryMagi`
- [ ] `OrreryCore` 與 `OrreryMagi` 間無 module cycle
- [ ] `docs/CONTRACT-OrreryMagi.md` 存在，列出 direct + indirect surface、breaking rule、`2026-07-01` Go/No-Go 錨點
- [ ] `CHANGELOG.md` 新增「internal refactor: extracted `OrreryMagi` library target」條目
- [ ] L10n JSON 檔（en / zh-Hant / ja）未變更
- [ ] `MCPSetupCommand.swift` 未變更；`/orrery:magi` slash command 寫入內容不變
- [ ] 既有 `MagiRun` JSON 檔可被新版讀取 / resume

### 可執行測試指令

```bash
# 1. Build 無 cycle、無 warning-as-error
swift build --package-path /Users/abnertsai/JiaBao/grady/Orrery 2>&1 | tee /tmp/build.log
test $? -eq 0

# 2. Test suite 全綠
swift test --package-path /Users/abnertsai/JiaBao/grady/Orrery 2>&1 | tee /tmp/test.log
test $? -eq 0

# 3. OrreryMagi 為 library product（swift package dump-package 確認）
swift package --package-path /Users/abnertsai/JiaBao/grady/Orrery dump-package \
  | python3 -c "import json,sys; p=json.load(sys.stdin); \
     assert any(prod['name']=='OrreryMagi' and 'library' in prod['type'] for prod in p['products']), 'OrreryMagi library product missing'; \
     print('OK')"

# 4. OrreryCore 不 import OrreryMagi（cycle guard）
! grep -rn "import OrreryMagi" /Users/abnertsai/JiaBao/grady/Orrery/Sources/OrreryCore/

# 5. Sources/OrreryCore/Magi 已清空
test ! -d /Users/abnertsai/JiaBao/grady/Orrery/Sources/OrreryCore/Magi || \
  test -z "$(ls -A /Users/abnertsai/JiaBao/grady/Orrery/Sources/OrreryCore/Magi 2>/dev/null)"

# 6. MCPServer.swift 無 orrery_magi 直接註冊
! grep -n '"orrery_magi"' /Users/abnertsai/JiaBao/grady/Orrery/Sources/OrreryCore/MCP/MCPServer.swift

# 7. MagiMCPTools 存在
test -f /Users/abnertsai/JiaBao/grady/Orrery/Sources/OrreryMagi/MagiMCPTools.swift
grep -n "register(on server:" /Users/abnertsai/JiaBao/grady/Orrery/Sources/OrreryMagi/MagiMCPTools.swift

# 8. CONTRACT doc + Go/No-Go date
test -f /Users/abnertsai/JiaBao/grady/Orrery/docs/CONTRACT-OrreryMagi.md
grep -q "2026-07-01" /Users/abnertsai/JiaBao/grady/Orrery/docs/CONTRACT-OrreryMagi.md

# 9. L10n 檔未變更（相對 main）
cd /Users/abnertsai/JiaBao/grady/Orrery && \
  git diff --quiet main -- Sources/OrreryCore/Resources/Localization/en.json \
                             Sources/OrreryCore/Resources/Localization/zh-Hant.json \
                             Sources/OrreryCore/Resources/Localization/ja.json \
                             Sources/OrreryCore/Resources/Localization/l10n-signatures.json \
                             Plugins/L10nCodegenTool/main.swift \
                             Plugins/L10nCodegen/plugin.swift

# 10. MCPSetupCommand 未變更
cd /Users/abnertsai/JiaBao/grady/Orrery && \
  git diff --quiet main -- Sources/OrreryCore/Commands/MCPSetupCommand.swift

# 11. 使用者面 smoke test — orrery magi --help 行為不變
.build/debug/orrery magi --help > /tmp/magi-help.txt
test -s /tmp/magi-help.txt

# 12. MCP tool 名稱不變（orrery mcp-server 啟動後 list-tools 應含 orrery_magi）
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  | .build/debug/orrery mcp-server 2>/dev/null \
  | grep -q '"orrery_magi"'
```