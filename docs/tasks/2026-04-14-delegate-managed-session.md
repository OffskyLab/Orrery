# Orrery 自建 delegate session（Hybrid 架構）

## 來源

討論：`docs/discussions/2026-04-14-delegate-managed-session.md`

## 目標

`orrery delegate --resume` 依賴各 tool 原生的 session resume 機制，但有兩個痛點：(1) 需要先查 session ID，(2) Codex 的 `resume` 和 `exec` 互斥，無法 resume + prompt。

本任務新增 `--session <name>` 選項，採 **Hybrid 架構**：
- **Claude / Gemini**：首次走 fresh delegate，之後走 **native `--resume`**——完整保留 tool call 記錄和中間思考過程
- **Codex**：fallback 到 **文字注入**（捕捉 stdout、注入歷史 prompt）——因 Codex CLI 的 resume + prompt 互斥限制

使用者不需查 session ID，只用名稱。此功能與原生 `--resume` 並存，不取代。

---

## 介面合約（Interface Contract）

### `SessionMapping`

```swift
// Sources/OrreryCore/Helpers/SessionMapping.swift
public struct SessionMappingEntry: Codable {
    public let tool: String            // "claude" | "codex" | "gemini"
    public let nativeSessionId: String? // Claude/Gemini 有值；Codex 為 nil
    public let lastUsed: String        // ISO 8601
}

public struct SessionMapping {
    public let baseDir: URL   // ~/.orrery/sessions/

    public init(store: EnvironmentStore)
    // baseDir = store.homeURL.appendingPathComponent("sessions")

    /// mapping 檔案路徑：<baseDir>/<projectKey>/<name>.json
    public func mappingFile(name: String, cwd: String) -> URL

    /// 讀取 mapping（不存在回傳 nil）
    public func load(name: String, cwd: String) -> SessionMappingEntry?

    /// 儲存/更新 mapping（自動建立目錄）
    public func save(_ entry: SessionMappingEntry, name: String, cwd: String) throws

    /// Codex fallback: 對話歷史 JSONL 路徑
    /// <baseDir>/<projectKey>/<name>.codex.jsonl
    public func codexHistoryFile(name: String, cwd: String) -> URL
}
```

> **路徑結構**：
> - `~/.orrery/sessions/<projectKey>/<name>.json` — mapping 檔（所有 tool）
> - `~/.orrery/sessions/<projectKey>/<name>.codex.jsonl` — Codex 專用對話歷史
>
> `projectKey = cwd.replacingOccurrences(of: "/", with: "-")`

---

### `SessionTurn`（Codex fallback 用）

```swift
// Sources/OrreryCore/Helpers/SessionMapping.swift（同檔）
public struct SessionTurn: Codable {
    public let role: String            // "user" | "assistant"
    public let content: String         // ANSI-stripped cleaned text
    public let timestamp: String       // ISO 8601
    public let tokenEstimate: Int      // chars / 4

    enum CodingKeys: String, CodingKey {
        case role, content, timestamp
        case tokenEstimate = "token_estimate"
    }
}
```

---

### `TeeCapture`（Codex fallback 用）

```swift
// Sources/OrreryCore/Helpers/TeeCapture.swift
public class TeeCapture {
    public let pipe: Pipe

    public init()

    /// 開始捕捉：raw bytes 轉發到 realStdout，同時累積到 buffer
    public func start(forwardTo realStdout: FileHandle)

    /// 結束捕捉：回傳 ANSI-stripped cleaned text
    public func finish() -> String
}
```

> **所有權**：`DelegateProcessBuilder` 建立 `TeeCapture` 並設定 `process.standardOutput = teeCapture.pipe`。`DelegateCommand` 在 process exit 後呼叫 `finish()`。
>
> **ANSI stripping**：regex `\u{1B}\[[0-9;]*[a-zA-Z]` + strip `\r`。[inferred] Codebase 目前無 ANSI stripping，全新實作。
>
> **僅 Codex 使用**：Claude/Gemini 走 native resume，不需捕捉 stdout。

---

### `SessionContextBuilder`（Codex fallback 用）

```swift
// Sources/OrreryCore/Helpers/SessionContextBuilder.swift
public struct SessionContextBuilder {
    /// 從 Codex 歷史 turns + 新 prompt 組合成含上下文的完整 prompt
    /// budget = 76_000 tokens (Codex 128k * 0.6)
    /// 格式：<session_history name="..."> ... </session_history>
    public static func buildPrompt(
        turns: [SessionTurn],
        newPrompt: String,
        sessionName: String,
        maxTokenBudget: Int = 76_000
    ) -> String
}
```

> 僅 Codex 使用。Claude/Gemini 不需要——它們走 native resume，tool 自己管理 context。

---

### `DelegateProcessBuilder`（修改）

```swift
// 新增欄位：
public let captureStdout: Bool   // true = TeeCapture；false = passthrough

// build() 回傳型別擴展：
public func build() throws -> (process: Process, stdinMode: StdinMode, teeCapture: TeeCapture?)
```

> **所有權**：`captureStdout == true` 時 builder 建立 `TeeCapture`，設定 `process.standardOutput = capture.pipe`，呼叫 `capture.start()`。caller 不再設定 stdout。
>
> **只有 Codex `--session` 時 `captureStdout = true`**。Claude/Gemini `--session` 不需要——它們走 native resume，stdout 直接 passthrough。

---

### `DelegateCommand`（修改）

```swift
// 新增：
@Option(name: .long, help: ArgumentHelp(L10n.Delegate.sessionHelp))
public var session: String?
```

驗證規則：
- `--session` 與 `--resume` 互斥
- `--session` v1 要求 prompt
- 至少有 session / resume / prompt 其一

**Hybrid 執行邏輯**（`run()` 內）：

```
if --session:
    let mapping = SessionMapping(store)
    if tool == .codex:
        → Codex fallback path（文字注入）
    else (Claude / Gemini):
        → Native mapping path（ID mapping + native resume）
else if --resume:
    → 現有 native resume path（不動）
else:
    → 現有 one-shot path（不動）
```

> **Native mapping path（Claude/Gemini）**：
> 1. `mapping.load(name, cwd)` 取 mapping
> 2. 若有 mapping 且有 `nativeSessionId` → `builder(resumeSessionId: id, prompt: prompt)`（native resume + prompt）
> 3. 若無 mapping → `builder(resumeSessionId: nil, prompt: prompt)`（fresh）
> 4. process 結束後，用 `SessionResolver` 找最近的 session → `mapping.save(entry, name, cwd)` 記錄 native ID
>
> **Codex fallback path**：
> 1. 讀 `codexHistoryFile` 的 turns
> 2. `SessionContextBuilder.buildPrompt(turns, prompt, name)` 組合
> 3. `builder(resumeSessionId: nil, prompt: combinedPrompt, captureStdout: true)`
> 4. process 結束後，`teeCapture.finish()` 取回應
> 5. append user turn + assistant turn 到 `codexHistoryFile`

---

## 改動檔案

| 檔案路徑 | 改動描述 |
|---------|---------|
| `Sources/OrreryCore/Helpers/SessionMapping.swift` | **新建**：`SessionMapping` + `SessionMappingEntry` + `SessionTurn`，session name ↔ native ID 對映 |
| `Sources/OrreryCore/Helpers/TeeCapture.swift` | **新建**：Pipe + streaming tee + ANSI strip（Codex fallback 用） |
| `Sources/OrreryCore/Helpers/SessionContextBuilder.swift` | **新建**：Codex 歷史 → prompt 組合（Codex fallback 用） |
| `Sources/OrreryCore/Helpers/DelegateProcessBuilder.swift` | **修改**：新增 `captureStdout` 欄位，build() 回傳 optional `TeeCapture` |
| `Sources/OrreryCore/Commands/DelegateCommand.swift` | **修改**：新增 `--session`，Hybrid 執行邏輯（native mapping + Codex fallback） |
| `Sources/OrreryCore/Localization/L10n.swift` | **修改**：新增 4 個 L10n key |
| `Sources/OrreryCore/Helpers/SessionResolver.swift` | **受影響，不改動**：native mapping path 用來找 delegate 後的最新 session ID |
| `Sources/OrreryCore/Helpers/SessionSpecifier.swift` | **不改動** |
| `Sources/OrreryCore/Commands/SessionsCommand.swift` | **不改動** |

---

## 實作步驟

### Step 1：新建 `SessionMapping` + `SessionTurn`

1. `SessionMappingEntry`：`Codable` struct，欄位 `tool`/`nativeSessionId`（optional）/`lastUsed`
2. `SessionTurn`：`Codable` struct，欄位 `role`/`content`/`timestamp`/`tokenEstimate`，`CodingKeys` 映射 `token_estimate`
3. `SessionMapping`：
   - `init(store:)`：`baseDir = store.homeURL.appendingPathComponent("sessions")`
   - `mappingFile(name:cwd:)`：
     ```
     let projectKey = cwd.replacingOccurrences(of: "/", with: "-")
     return baseDir.appendingPathComponent(projectKey).appendingPathComponent("\(name).json")
     ```
   - `codexHistoryFile(name:cwd:)`：同上但副檔名 `.codex.jsonl`
   - `load(name:cwd:) -> SessionMappingEntry?`：
     ```
     let file = mappingFile(name:cwd:)
     guard let data = try? Data(contentsOf: file) else { return nil }
     return try? JSONDecoder().decode(SessionMappingEntry.self, from: data)
     ```
   - `save(_:name:cwd:) throws`：
     ```
     let file = mappingFile(name:cwd:)
     try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
     let data = try JSONEncoder().encode(entry)
     try data.write(to: file)
     ```
   - Codex history 的 `loadTurns` / `appendTurn`：與前版 `ManagedSessionStore` 相同邏輯（讀 JSONL、逐行 decode、append via FileHandle）

---

### Step 2：新建 `TeeCapture`

（與前版 spec 相同，不重複）

1. `class TeeCapture`，持有 `pipe = Pipe()` 和 `buffer = Data()`
2. `start(forwardTo:)`：`pipe.fileHandleForReading.readabilityHandler` 轉發 raw bytes + 累積 buffer
3. `finish()`：移除 handler、drain remaining、strip ANSI、return cleaned text
4. `stripAnsi(_:)`：regex `\u{1B}\[[0-9;]*[a-zA-Z]` + strip `\r`

---

### Step 3：新建 `SessionContextBuilder`

（僅 Codex 使用，與前版 spec 相同但簡化——無需 per-tool budget）

1. `buildPrompt(turns:newPrompt:sessionName:maxTokenBudget:)` → `String`
2. 從最新到最舊累加 `tokenEstimate` 直到 budget（預設 76,000）
3. 格式：`<session_history name="...">` + `[User]`/`[Assistant]` + `</session_history>` + `Continue...` + new prompt
4. 若 turns 為空，直接回傳 newPrompt

---

### Step 4：修改 `DelegateProcessBuilder`

1. 新增欄位 `public let captureStdout: Bool`
2. `build()` 回傳改為 `(process: Process, stdinMode: StdinMode, teeCapture: TeeCapture?)`
3. stdout 設定邏輯（取代現有第 108 行 `process.standardOutput = FileHandle.standardOutput`）：
   ```swift
   let teeCapture: TeeCapture?
   if captureStdout {
       let capture = TeeCapture()
       capture.start(forwardTo: FileHandle.standardOutput)
       process.standardOutput = capture.pipe
       teeCapture = capture
   } else {
       process.standardOutput = FileHandle.standardOutput
       teeCapture = nil
   }
   ```
4. `process.standardError` 不變
5. return `(process, stdinMode, teeCapture)`
6. 所有現有 call site 需更新解構：`let (process, _, teeCapture) = try builder.build()`

---

### Step 5：修改 `DelegateCommand`

1. 新增 `@Option(name: .long, help: ArgumentHelp(L10n.Delegate.sessionHelp)) var session: String?`

2. 更新 validation guards：
   ```swift
   if session != nil, resume != nil {
       throw ValidationError(L10n.Delegate.sessionResumeExclusive)
   }
   guard session != nil || resume != nil || prompt != nil else {
       throw ValidationError(L10n.Delegate.noPromptNoResume)
   }
   if session != nil, prompt == nil {
       throw ValidationError(L10n.Delegate.sessionRequiresPrompt)
   }
   ```

3. **Native mapping path（Claude/Gemini + `--session`）**：
   ```swift
   if let sessionName = session, tool != .codex, let userPrompt = prompt {
       let mapping = SessionMapping(store: store)
       let cwd = FileManager.default.currentDirectoryPath
       let existing = mapping.load(name: sessionName, cwd: cwd)

       // 若有既存 mapping 且 tool 匹配 → native resume
       let resumeId: String?
       if let entry = existing, entry.tool == tool.rawValue {
           resumeId = entry.nativeSessionId
       } else {
           resumeId = nil
       }

       let builder = DelegateProcessBuilder(
           tool: tool, prompt: userPrompt,
           resumeSessionId: resumeId,
           environment: envName, store: store,
           captureStdout: false   // native resume 不需 tee
       )
       let (process, _, _) = try builder.build()
       try process.run()
       process.waitUntilExit()

       // delegate 結束後，找到最新 native session ID 並存入 mapping
       let sessions = SessionResolver.findScopedSessions(...)  // [見下方說明]
       if let latest = sessions.sorted(by: { ($0.lastTime ?? .distantPast) > ($1.lastTime ?? .distantPast) }).first {
           let entry = SessionMappingEntry(
               tool: tool.rawValue,
               nativeSessionId: latest.id,
               lastUsed: ISO8601DateFormatter().string(from: Date()))
           try? mapping.save(entry, name: sessionName, cwd: cwd)
       }

       throw ExitCode(process.terminationStatus)
   }
   ```

   > **找最新 session 的方法**：使用 `SessionResolver` 的 scoped session discovery 邏輯。但 `SessionResolver.findScopedSessions` 目前是 `private`。有兩個選項：
   > - **選項 A**：將 `findScopedSessions(tool:cwd:store:activeEnvironment:)` 改為 `internal`（同 module 可見）
   > - **選項 B**：直接呼叫 `SessionsCommand.findSessions(tool:cwd:store:)`（`public static`，掃描全部 env，但用 `.first` 取最新即可）
   >
   > **建議選項 B**——不改動 `SessionResolver`，用現有 `public` API。

4. **Codex fallback path**：
   ```swift
   if let sessionName = session, tool == .codex, let userPrompt = prompt {
       let mapping = SessionMapping(store: store)
       let cwd = FileManager.default.currentDirectoryPath

       // 讀歷史、組合 prompt
       let turns = mapping.loadCodexTurns(name: sessionName, cwd: cwd)
       let combinedPrompt = SessionContextBuilder.buildPrompt(
           turns: turns, newPrompt: userPrompt, sessionName: sessionName)

       let builder = DelegateProcessBuilder(
           tool: .codex, prompt: combinedPrompt,
           resumeSessionId: nil,
           environment: envName, store: store,
           captureStdout: true   // 需要捕捉回應
       )
       let (process, _, teeCapture) = try builder.build()
       try process.run()
       process.waitUntilExit()

       // 存 turns
       let now = ISO8601DateFormatter().string(from: Date())
       let userTurn = SessionTurn(role: "user", content: userPrompt,
           timestamp: now, tokenEstimate: userPrompt.count / 4)
       try? mapping.appendCodexTurn(userTurn, name: sessionName, cwd: cwd)

       if let capture = teeCapture {
           let response = capture.finish()
           if !response.isEmpty {
               let assistantTurn = SessionTurn(role: "assistant", content: response,
                   timestamp: ISO8601DateFormatter().string(from: Date()),
                   tokenEstimate: response.count / 4)
               try? mapping.appendCodexTurn(assistantTurn, name: sessionName, cwd: cwd)
           }
       }

       // 也存 mapping（無 nativeSessionId）
       let entry = SessionMappingEntry(tool: "codex", nativeSessionId: nil, lastUsed: now)
       try? mapping.save(entry, name: sessionName, cwd: cwd)

       throw ExitCode(process.terminationStatus)
   }
   ```

5. 現有 native resume path 和 one-shot path 不動

---

### Step 6：新增 L10n keys

在 `L10n.swift` 的 `enum Delegate` 段落新增：

```swift
public static var sessionHelp: String {
    isChinese
        ? "用自訂名稱建立或接續 Orrery 管理的 session"
        : "Create or continue an Orrery-managed session by name"
}
public static var sessionResumeExclusive: String {
    isChinese
        ? "--session 與 --resume 不可同時使用。"
        : "--session and --resume cannot be used together."
}
public static var sessionRequiresPrompt: String {
    isChinese
        ? "--session 必須搭配 prompt 使用。"
        : "--session requires a prompt."
}
```

更新 `noPromptNoResume`：
```swift
public static var noPromptNoResume: String {
    isChinese
        ? "請提供任務描述，或使用 --resume / --session 接續既有 session。"
        : "Provide a prompt, or use --resume / --session to continue an existing session."
}
```

---

## 失敗路徑

### `--session` + `--resume` 互斥（不可恢復）
- 條件：兩者同時有值
- throw `ValidationError(L10n.Delegate.sessionResumeExclusive)` → exit 1

### `--session` 無 prompt（不可恢復）
- 條件：`session != nil && prompt == nil`
- throw `ValidationError(L10n.Delegate.sessionRequiresPrompt)` → exit 1

### native session ID 找不到（native mapping path）[inferred]
- 條件：delegate 後 `SessionsCommand.findSessions` 回傳空（tool 未產生 session）
- 行為：mapping 不更新，下次 `--session` 走 fresh path。**不 throw**。

### mapping 目錄寫入失敗 [inferred]
- 條件：`~/.orrery/sessions/` 無寫入權限
- 行為：被 `try?` 吞掉。process 結果正常回傳，但 mapping 不存。下次同名 session 走 fresh path。

### Codex prompt 過長超過 ARG_MAX [inferred]
- 條件：歷史 + prompt > ~262144 bytes
- `process.run()` throw `NSPOSIXError(.E2BIG)` → exit 1
- v1 不防禦，列入已知限制

### native resume session 過期/被刪（native mapping path）[inferred]
- 條件：mapping 存在但 native session 已被 tool 清除
- 行為：tool 自己報錯（如 `claude --resume <stale-id>` → Claude 報 session not found）
- Orrery 不攔截，passthrough tool 的 exit code

---

## 不改動的部分

- `Sources/OrreryCore/Helpers/SessionSpecifier.swift`：native session 概念
- `Sources/OrreryCore/Helpers/SessionResolver.swift`：不改動，但 `DelegateCommand` 會呼叫 `SessionsCommand.findSessions`（`public static`）來找最新 session
- `Sources/OrreryCore/Commands/ResumeCommand.swift`：不涉及
- `Sources/OrreryCore/Commands/SessionsCommand.swift`：不改動，v1 不顯示 managed sessions
- `Sources/OrreryCore/Models/Tool.swift`：不改動
- native `--resume` 機制：完全不動

---

## 驗收標準

### 功能合約

- [ ] `orrery delegate --claude --session work "fix auth"` 成功，`~/.orrery/sessions/<projectKey>/work.json` 產生 mapping，含 `nativeSessionId`
- [ ] 再次 `orrery delegate --claude --session work "add tests"` 使用 native `--resume`（完整保留 tool calls/thinking）
- [ ] `orrery delegate --codex --session work "fix auth"` 成功，`work.codex.jsonl` 產生對話歷史
- [ ] 再次 `orrery delegate --codex --session work "add tests"` 注入歷史（prompt 含 `<session_history>`）
- [ ] `orrery delegate --claude --session x --resume last` exit 1，stderr 含 "cannot be used together"
- [ ] `orrery delegate --claude --session x`（無 prompt）exit 1，stderr 含 "requires a prompt"
- [ ] `orrery delegate --claude "task"` 行為不變（one-shot regression）
- [ ] `orrery delegate --claude --resume last "follow up"` 行為不變（native resume regression）
- [ ] Codex session JSONL 中 assistant content 不含 ANSI escape
- [ ] Claude/Gemini `--session` 不捕捉 stdout（passthrough，無效能影響）

### 測試指令

```bash
# 1. Build
swift build

# 2. One-shot regression
orrery delegate --claude "echo hello"

# 3. Claude: create managed session (native mapping)
orrery delegate --claude --session test-work "say hello"

# 4. Verify mapping created
cat ~/.orrery/sessions/*/test-work.json
# Should contain nativeSessionId

# 5. Claude: continue session (native resume, full state)
orrery delegate --claude --session test-work "what did you just say?"

# 6. Verify mapping updated (lastUsed changed)
cat ~/.orrery/sessions/*/test-work.json

# 7. Codex: create managed session (fallback)
orrery delegate --codex --session codex-test "echo hello"

# 8. Verify Codex history JSONL
cat ~/.orrery/sessions/*/codex-test.codex.jsonl

# 9. Codex: continue session (history injection)
orrery delegate --codex --session codex-test "what did you just say?"

# 10. Verify 4 lines in Codex JSONL
wc -l ~/.orrery/sessions/*/codex-test.codex.jsonl

# 11. Error: --session + --resume
orrery delegate --claude --session x --resume last 2>&1 | grep "cannot be used together"
echo "exit: $?"   # 1

# 12. Error: --session without prompt
orrery delegate --claude --session x 2>&1 | grep "requires a prompt"
echo "exit: $?"   # 1

# 13. Native resume regression
orrery delegate --claude --resume last "continue"

# 14. No ANSI in Codex stored content
grep -P '\x1B\[' ~/.orrery/sessions/*/codex-test.codex.jsonl
echo "exit: $?"   # 1 (no matches)

# 15. Cleanup
rm -rf ~/.orrery/sessions/*/test-work.*
rm -rf ~/.orrery/sessions/*/codex-test.*
```

---

## 已知限制

1. **Codex ARG_MAX**：Codex fallback 的歷史 + prompt 作為 CLI argument，macOS ARG_MAX ~262144 bytes。v2 可改用 stdin 或 temp file。
2. **Codex token 估算不精確**：`chars / 4` 是粗略估算。v2 可引入 tokenizer。
3. **Codex v1 不做 summary**：超出 budget 只 drop oldest turns。
4. **Native session 過期**：mapping 指向的 native session 可能被 tool 清除。Orrery 不攔截——passthrough tool 的錯誤。使用者需手動重建 session。
5. **Codex session 寫入 silent failure**：`try?` 吞掉寫入錯誤。
6. **ANSI stripping 可能不完整**：只處理 SGR + `\r`。
7. **`orrery sessions` 不顯示 managed sessions**：v1 不擴展。使用者用 `ls ~/.orrery/sessions/` 查看。
8. **依賴前置 task**：`docs/tasks/2026-04-13-delegate-session.md`（native `--resume`）必須已完成。
9. **Claude/Gemini `--resume -p` 行為假設**：native mapping path 依賴 `claude --resume <id> -p <prompt>` 正常運作，需先手動驗證。
