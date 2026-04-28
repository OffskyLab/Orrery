# Delegate Session 功能設計

## 來源

討論：`docs/discussions/2026-04-13-delegate-session.md`

## 目標

`orrery delegate` 目前以 one-shot 模式運作，每次呼叫都建立全新對話，使用者在 AI 間討論或委派實作任務時，需要每次重新提供完整上下文，效率低落。

本任務為 `orrery delegate` 加入 `--resume` 選項，讓使用者可以指定既有 session（by index、ID 或 `last` 關鍵字）繼續對話，三種 tool（Claude、Codex、Gemini）均支援。同時新增共用輔助層（`SessionSpecifier`、`SessionResolver`、`DelegateProcessBuilder`），讓 `delegate` 與 `resume` 命令共用解析和啟動邏輯，並透過 `StdinMode` enum 預留未來 Codex stdin pipe 擴展空間。

---

## 介面合約（Interface Contract）

### `SessionSpecifier`

```swift
// Sources/OrreryCore/Helpers/SessionSpecifier.swift
public enum SessionSpecifier {
    case last
    case index(Int)   // 1-based
    case id(String)

    /// 解析規則：
    ///   "last"         → .last
    ///   純正整數字串    → .index(n)，n 必須 > 0
    ///   其他字串       → .id(raw)
    /// 拋出：
    ///   ValidationError("session index must be > 0") — raw 為純整數但值 <= 0
    public init(_ raw: String) throws
}
```

不變量：Claude/Gemini session ID 為 UUID（含 `-`），Codex session ID 為去掉 `rollout-` 前綴後的 hex hash（例如 `abc123def456`）。兩者均非純整數，解析零歧義。

---

### `SessionResolver`

```swift
// Sources/OrreryCore/Helpers/SessionResolver.swift
public struct SessionResolver {
    /// 將 specifier 解析為具體的 SessionEntry
    /// 搜尋範圍：shared session dir + activeEnvironment 的 config dir（不搜尋其他 env）
    /// 按 lastTime 降序排列後套用 specifier
    ///
    /// 拋出：
    ///   ValidationError — 找不到任何 session（附 tool 名稱）
    ///   ValidationError — index 超出範圍（附 count，使用 L10n.Resume.indexOutOfRange）
    ///   ValidationError — ID 不存在（附 id 字串）
    public static func resolve(
        _ specifier: SessionSpecifier,
        tool: Tool,
        cwd: String,
        store: EnvironmentStore,
        activeEnvironment: String?
    ) throws -> SessionsCommand.SessionEntry
}
```

**重要：`SessionResolver` 不能呼叫 `SessionsCommand.findSessions`**（它掃描全部 env）。應直接呼叫同一 module 內的 internal static helpers：

| Tool | 呼叫方式 |
|------|---------|
| Claude | `SessionsCommand.findClaudeSessions(cwd:store:)` 回傳 shared + 所有 env，但此 helper 本身已只掃 shared + per-env dirs；`SessionResolver` 需改為直接掃特定目錄，見下方實作說明 |
| Codex | `SessionsCommand.findCodexSessions(store:)` 同理 |
| Gemini | `SessionsCommand.findGeminiSessions(cwd:store:)` 同理 |

由於現有 per-tool helpers 本身也掃描所有 env，`SessionResolver` 需採用**直接目錄掃描**方式（不呼叫任何 `findXxxSessions`），步驟如下（見 Step 2 詳細說明）：
1. 取 `store.sharedSessionDir(tool:)` 下的 session 目錄
2. 若 `activeEnvironment != nil && activeEnvironment != ReservedEnvironment.defaultName`，用 `store.toolConfigDir(tool:environment:activeEnvironment)` 取得該 env 的 tool config dir，加入掃描
3. 複用 `SessionsCommand` 的個別 parse helper（`parseClaudeSession`、`parseCodexSession`、`parseGeminiSession`）和 `jsonlFiles`、`findRecursiveJsonl`、`findGeminiCheckpoints`、`dedup` 等 utility（皆為 `internal static`，同 module 可用）

---

### `StdinMode`

```swift
// Sources/OrreryCore/Helpers/DelegateProcessBuilder.swift（與 builder 同檔）
public enum StdinMode {
    case nullDevice                          // one-shot：不需要 stdin
    case interactive                         // resume 無 prompt：直通 real stdin
    case injectedThenInteractive(String)     // Phase 2 佔位：Phase 1 throw ValidationError
}
```

---

### `DelegateProcessBuilder`

```swift
// Sources/OrreryCore/Helpers/DelegateProcessBuilder.swift
public struct DelegateProcessBuilder {
    public let tool: Tool
    public let prompt: String?
    public let resumeSessionId: String?
    public let environment: String?   // nil = use ORRERY_ACTIVE_ENV
    public let store: EnvironmentStore

    /// 建構 Process 及對應的 StdinMode
    ///
    /// 拋出：
    ///   ValidationError(L10n.Delegate.codexResumePromptUnsupported)
    ///     — tool == .codex && resumeSessionId != nil && prompt != nil
    ///   ValidationError(.injectedThenInteractive)
    ///     — 不應抵達此 case，保護性 throw
    ///   EnvironmentStore.Error — environment 不存在
    ///
    /// build() 回傳的 Process 尚未啟動。
    /// standardInput 由 build() 負責設定（呼叫端不需再設定）。
    public func build() throws -> (process: Process, stdinMode: StdinMode)
}
```

---

### `DelegateCommand`（修改）

```swift
// Sources/OrreryCore/Commands/DelegateCommand.swift
// 新增：
@Option(name: .long, help: ArgumentHelp(L10n.Delegate.resumeHelp))
public var resume: String?

// 修改：prompt 從必填 @Argument 改為 optional
// ArgumentParser 在有 --resume 時允許省略 prompt
@Argument(help: ArgumentHelp(L10n.Delegate.promptHelp, isOptional: true))
public var prompt: String?
```

驗證不變量（於 `run()` 開頭，在 resolvedTool() 之後）：
- `guard resume != nil || prompt != nil else { throw ValidationError(L10n.Delegate.noPromptNoResume) }`
- 無 `--resume` 時行為與修改前完全相同（one-shot，`--allowedTools Bash` 等 flag 保留）
- `stdinMode` switch 中必須處理 `.injectedThenInteractive` case（`throw ValidationError` 或 `fatalError`，不可省略）

---

### `ResumeCommand`（重構）

重構後 `ResumeCommand` 實際上也會獲得 `last` 和 raw ID 的解析能力（透過 `SessionSpecifier`）。這是可接受的副作用——`last` 對使用者有用，ID 支援自動化腳本。

需同時更新：
- `L10n.Resume.abstract`：改為 `"Resume an AI tool session by index, ID, or 'last'"`
- 保留現有 `guard let indexStr = remaining.first(where: { !$0.hasPrefix("-") }) else { throw ValidationError(L10n.Resume.noIndex) }`，再接 `let specifier = try SessionSpecifier(indexStr)`
- `L10n.Resume.noIndex` 仍保留（用於「無任何引數」的情況）；`SessionSpecifier.init` 的 `<= 0` 錯誤則用自己的訊息

---

## 改動檔案

| 檔案路徑 | 改動描述 |
|---------|---------|
| `Sources/OrreryCore/Helpers/SessionSpecifier.swift` | **新建**：`SessionSpecifier` enum，解析 `last`/index/id |
| `Sources/OrreryCore/Helpers/SessionResolver.swift` | **新建**：`SessionResolver`，限縮搜尋範圍至當前 env + shared |
| `Sources/OrreryCore/Helpers/DelegateProcessBuilder.swift` | **新建**：`StdinMode` enum + `DelegateProcessBuilder`，統一 process 建構邏輯 |
| `Sources/OrreryCore/Commands/DelegateCommand.swift` | **修改**：加 `--resume` option；`prompt` 改 optional；使用新 builder |
| `Sources/OrreryCore/Commands/ResumeCommand.swift` | **重構**：session 查詢改用 `SessionResolver`；更新 help text |
| `Sources/OrreryCore/Localization/L10n.swift` | **修改**：新增 5 個 L10n key（見 Step 6） |
| `Sources/OrreryCore/Commands/SessionsCommand.swift` | **受影響，不改動**：`parseClaudeSession` 等 parse helpers 供 `SessionResolver` 呼叫 |
| `Sources/OrreryCore/Models/Tool.swift` | **受影響，不改動**：`Tool` enum 維持純 metadata |
| `Package.swift` | **不改動**：`OrreryCore` 以 `path:` 方式 glob 所有 `.swift`，`Helpers/` 目錄下的新檔案自動包含 |

---

## 實作步驟

### Step 1：新建 `SessionSpecifier`

1. 建立 `Sources/OrreryCore/Helpers/` 目錄
   > **Package.swift 不需修改**：`OrreryCore` target 使用 `path: "Sources/OrreryCore"`，會自動遞迴包含此目錄下所有 `.swift` 檔案
2. 定義 `public enum SessionSpecifier`（三個 case）
3. 實作 `init(_ raw: String) throws`：
   - `raw == "last"` → `.last`
   - `let n = Int(raw), n > 0` → `.index(n)`
   - `Int(raw) != nil` 但 `<= 0` → `throw ValidationError("session index must be > 0")`
   - 其餘 → `.id(raw)`

---

### Step 2：新建 `SessionResolver`

1. 定義 `public static func resolve(_:tool:cwd:store:activeEnvironment:) throws -> SessionsCommand.SessionEntry`

2. **建構受限 session 目錄列表**（依 tool 不同，路徑結構不同）：

   **Claude**（project-scoped，sessions 在 `projects/<project-key>/*.jsonl`）：
   ```
   projectKey = cwd.replacingOccurrences(of: "/", with: "-")
   dirs = [
     store.sharedSessionDir(tool: .claude).appendingPathComponent("projects").appendingPathComponent(projectKey),
   ]
   if let env = activeEnvironment, env != ReservedEnvironment.defaultName {
     dirs += [store.toolConfigDir(tool: .claude, environment: env)
               .appendingPathComponent("projects")
               .appendingPathComponent(projectKey)]
   }
   files = dirs.flatMap { SessionsCommand.jsonlFiles(in: $0) }
   entries = SessionsCommand.dedup(files, seen: &seen).compactMap { SessionsCommand.parseClaudeSession(file: $0) }
   ```

   **Codex**（全域，sessions 在 `sessions/YYYY/MM/DD/rollout-*.jsonl`）：
   > Codex session ID = filename stem 去掉 `rollout-` 前綴（例如檔名 `rollout-abc123.jsonl` → ID 為 `abc123`）
   ```
   dirs = [
     store.sharedSessionDir(tool: .codex).appendingPathComponent("sessions"),
   ]
   if let env = activeEnvironment, env != ReservedEnvironment.defaultName {
     dirs += [store.toolConfigDir(tool: .codex, environment: env).appendingPathComponent("sessions")]
   }
   files = dirs.flatMap { SessionsCommand.findRecursiveJsonl(in: $0, prefix: "rollout-") }
   entries = SessionsCommand.dedup(files, seen: &seen).compactMap { SessionsCommand.parseCodexSession(file: $0) }
   ```

   **Gemini**（project-scoped via hash，sessions 在 `tmp/<hash>/chats/checkpoint-*.json`）：
   > Gemini session ID = filename stem 去掉 `checkpoint-` 前綴
   ```
   baseDirs = [store.sharedSessionDir(tool: .gemini).appendingPathComponent("tmp")]
   if let env = activeEnvironment, env != ReservedEnvironment.defaultName {
     baseDirs += [store.toolConfigDir(tool: .gemini, environment: env).appendingPathComponent("tmp")]
   }
   files = baseDirs.flatMap { SessionsCommand.findGeminiCheckpoints(in: $0) }
   entries = SessionsCommand.dedup(files, seen: &seen).compactMap { SessionsCommand.parseGeminiSession(file: $0) }
   ```

3. **Dedup + 排序**：`SessionsCommand.dedup` 以 session ID 去重（first-seen wins）；按 `lastTime` 降序排列

4. **套用 specifier**：
   - `.last` → `entries.first` 或 `throw ValidationError("no sessions found for \(tool.displayName)")`
   - `.index(n)` → 若 `n > entries.count`：`throw ValidationError(L10n.Resume.indexOutOfRange(n, entries.count))`；否則 `entries[n-1]`
   - `.id(s)` → `entries.first(where: { $0.id == s })` 或 `throw ValidationError("session '\(s)' not found")`

---

### Step 3：新建 `DelegateProcessBuilder` + `StdinMode`

1. 定義 `StdinMode` enum（三個 case）

2. 定義 `DelegateProcessBuilder` struct

3. 實作 `build() throws -> (Process, StdinMode)`：

   **a. Codex guard**：
   ```swift
   if tool == .codex, resumeSessionId != nil, prompt != nil {
       throw ValidationError(L10n.Delegate.codexResumePromptUnsupported)
   }
   ```

   **b. 建構 command array**（per-tool）：
   ```swift
   switch (tool, resumeSessionId, prompt) {
   case (.claude, let id?, let p?): ["claude", "--resume", id, "-p", p, "--allowedTools", "Bash"]
   case (.claude, let id?, nil):    ["claude", "--resume", id]
   case (.claude, nil, let p?):     ["claude", "-p", p, "--allowedTools", "Bash"]
   case (.codex,  let id?, nil):    ["codex", "resume", id]
   case (.codex,  nil, let p?):     ["codex", "exec", p]
   case (.gemini, let id?, let p?): ["gemini", "--resume", id, "-p", p]
   case (.gemini, let id?, nil):    ["gemini", "--resume", id]
   case (.gemini, nil, let p?):     ["gemini", "-p", p]
   default: fatalError("unreachable: guard in DelegateCommand prevents both nil")
   }
   ```

   **c. 決定 StdinMode**：
   - `resumeSessionId != nil && prompt == nil` → `.interactive`
   - 其他情況（one-shot 或 resume+prompt）→ `.nullDevice`
   - `.injectedThenInteractive` 不在 Phase 1 建構，若呼叫 `build()` 時出現此 case → `throw ValidationError("not implemented")`

   **d. 建構 process environment**（完整移植 `DelegateCommand.swift:34-62` 邏輯，含以下四個子步驟）：
   ```
   var processEnv = ProcessInfo.processInfo.environment

   // 1. 若有指定非 default environment，注入 tool config dir env vars 並 strip ANTHROPIC_API_KEY
   if let envName = environment, envName != ReservedEnvironment.defaultName {
       let env = try store.load(named: envName)
       for t in env.tools {
           processEnv[t.envVarName] = store.toolConfigDir(tool: t, environment: envName).path
       }
       for (key, value) in env.env { processEnv[key] = value }
       processEnv.removeValue(forKey: "ANTHROPIC_API_KEY")
   }

   // 2. Strip IPC vars（避免 child claude hang）
   processEnv.removeValue(forKey: "CLAUDECODE")
   processEnv.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
   processEnv.removeValue(forKey: "CLAUDE_CODE_EXECPATH")

   // 3. 若 environment == ReservedEnvironment.defaultName，strip 所有 tool config dir vars
   if environment == ReservedEnvironment.defaultName {
       for t in Tool.allCases { processEnv.removeValue(forKey: t.envVarName) }
   }
   ```

   **e. 設定 `process.standardInput`（builder 負責，呼叫端不需再設定）**：
   - `.nullDevice` → `FileHandle.nullDevice`（現有 one-shot 行為）
   - `.interactive` → `FileHandle.standardInput`

4. `process.standardOutput = FileHandle.standardOutput`、`process.standardError = FileHandle.standardError`（與現有相同）

---

### Step 4：修改 `DelegateCommand`

1. 新增 `@Option(name: .long, help: ArgumentHelp(L10n.Delegate.resumeHelp)) var resume: String?`
2. `prompt` 改為 `@Argument(help: ArgumentHelp(L10n.Delegate.promptHelp, isOptional: true)) var prompt: String?`
3. `run()` 開頭（在 `resolvedTool()` 之後）加：
   ```swift
   guard resume != nil || prompt != nil else {
       throw ValidationError(L10n.Delegate.noPromptNoResume)
   }
   ```
4. 若有 `--resume`：
   ```swift
   let specifier = try SessionSpecifier(resume!)
   let envName = environment ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
   let session = try SessionResolver.resolve(specifier, tool: tool, cwd: FileManager.default.currentDirectoryPath, store: store, activeEnvironment: envName)
   ```
5. 建構 builder：
   ```swift
   let builder = DelegateProcessBuilder(
       tool: tool,
       prompt: prompt,
       resumeSessionId: session?.id,   // nil if no --resume
       environment: environment ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"],
       store: store
   )
   let (process, stdinMode) = try builder.build()
   ```
6. **不需另外設定 `process.standardInput`**（builder 已設定）
7. 處理 `stdinMode` switch 中的 `.injectedThenInteractive` case（即使 Phase 1 不會到達，編譯要求覆蓋所有 case）：
   ```swift
   case .injectedThenInteractive:
       throw ValidationError("stdin injection not yet implemented")
   ```
8. 現有 env 組裝程式碼（`DelegateCommand.swift:34-62`）**整體刪除**，由 `DelegateProcessBuilder` 接管
9. `try process.run()` + `process.waitUntilExit()` + `throw ExitCode(process.terminationStatus)`

---

### Step 5：重構 `ResumeCommand`

1. 現有 index 解析邏輯（`ResumeCommand.swift:29-46`）改為：
   ```swift
   guard let raw = remaining.first(where: { !$0.hasPrefix("-") }) else {
       throw ValidationError(L10n.Resume.noIndex)   // 保留：無任何引數時的錯誤
   }
   let passthrough = remaining.filter { $0 != raw }
   let specifier = try SessionSpecifier(raw)   // 可 throw "session index must be > 0"
   let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
   let session = try SessionResolver.resolve(specifier, tool: tool,
       cwd: FileManager.default.currentDirectoryPath, store: store,
       activeEnvironment: envName)
   ```
2. 其餘啟動邏輯不變（組 resume command + passthrough + Process 啟動）
3. 更新 `L10n.Resume.abstract`（見 Step 6）

---

### Step 6：新增 L10n keys

在 `L10n.swift` 的 `enum Delegate` 段落（第 591 行之後）新增：

```swift
public static var resumeHelp: String {
    isChinese
        ? "以 index、ID 或 'last' 接續既有 session"
        : "Resume a session by index, ID, or 'last'"
}
public static var noPromptNoResume: String {
    isChinese
        ? "請提供任務描述，或使用 --resume 接續既有 session。"
        : "Provide a prompt or use --resume to continue an existing session."
}
public static var resumeNotFound: String {
    isChinese
        ? "找不到符合的 session。請執行 orrery sessions 查看清單。"
        : "No matching session found. Run orrery sessions to see the list."
}
public static var codexResumePromptUnsupported: String {
    isChinese
        ? "Codex 不支援同時 resume + 新 prompt。請省略 prompt 以進入互動模式，或移除 --resume 使用 one-shot 模式。"
        : "Codex does not support resume + prompt. Use --resume without a prompt for interactive mode, or remove --resume for one-shot mode."
}
```

在 `enum Resume` 段落更新：
```swift
public static var abstract: String {
    isChinese
        ? "用 index、ID 或 'last' 接續 AI tool session"
        : "Resume an AI tool session by index, ID, or 'last'"
}
```

---

## 失敗路徑

### `SessionSpecifier.init` 失敗
- 條件：raw 為純整數且 <= 0
- throw `ValidationError("session index must be > 0")` → ArgumentParser 捕捉 → exit 1

### `SessionResolver.resolve` 失敗（三種）
- **無 session**：`ValidationError(L10n.Delegate.resumeNotFound)` → 傳播 → exit 1
- **index 超出範圍**：`ValidationError(L10n.Resume.indexOutOfRange(n, count))` → 傳播 → exit 1
- **ID 不存在**：`ValidationError("session '\(s)' not found")` → 傳播 → exit 1

### Codex + resume + prompt（不可恢復）
- 條件：`tool == .codex && resumeSessionId != nil && prompt != nil`
- `DelegateProcessBuilder.build()` throw `ValidationError(L10n.Delegate.codexResumePromptUnsupported)` → exit 1

### prompt 和 resume 均缺（不可恢復）
- 條件：`resume == nil && prompt == nil`
- `DelegateCommand.run()` guard throw `ValidationError(L10n.Delegate.noPromptNoResume)` → exit 1

### Process 啟動失敗（不可恢復）
- 條件：底層 CLI binary 找不到
- `try process.run()` throw → 傳播 → exit 1（現有行為）

### EnvironmentStore 讀取失敗（不可恢復）
- 條件：`-e <name>` 指定的 environment 不存在
- `store.load(named:)` throw `EnvironmentStore.Error.environmentNotFound` → 傳播 → exit 1（現有行為）

---

## 不改動的部分

- `Sources/OrreryCore/Models/Tool.swift`：維持純 metadata enum
- `Sources/OrreryCore/Commands/SessionsCommand.swift`：`findSessions`、parse helpers、utility functions 介面不變；`SessionResolver` 呼叫其 internal static members
- `Sources/OrreryCore/Commands/MCPSetupCommand.swift`：slash command 定義不變
- `Sources/OrreryCore/Commands/RunCommand.swift`：不涉及 session 功能
- `Package.swift`：不改動，`Helpers/` 目錄新檔案自動包含
- session 儲存格式（`.jsonl`/`.json`）：不修改
- session 命名/標籤系統：延後

---

## 驗收標準

### 功能合約

- [ ] `orrery delegate --claude --resume last "follow up"` 成功 resume Claude 最近的 session 並追加 prompt（需先有既有 session）
- [ ] `orrery delegate --claude --resume 2` 成功 resume Claude 第 2 個 session，進入互動模式（無 prompt）
- [ ] `orrery delegate --gemini --resume <checkpoint-id> "follow up"` 以 ID 精確 resume Gemini session（ID 格式：`checkpoint-` 後的部分）
- [ ] `orrery delegate --codex --resume last "follow up"` exit 1，stderr 含 "Codex does not support resume + prompt"
- [ ] `orrery delegate --codex --resume last`（無 prompt）成功進入 Codex 互動式 resume
- [ ] `orrery delegate --claude`（無 prompt 無 --resume）exit 1，stderr 含 "Provide a prompt"
- [ ] `orrery delegate --claude "task"` 行為與修改前完全相同（one-shot regression）
- [ ] `orrery delegate --claude -e work --resume last` 使用 `work` environment 的 session 列表和設定
- [ ] `orrery resume --claude 1` 行為與修改前相同（regression）
- [ ] `orrery resume --claude last` 成功（重構後新增支援）
- [ ] `orrery delegate --claude --resume 0` exit 1，stderr 含 "must be > 0"
- [ ] `orrery delegate --claude --resume 999` exit 1，stderr 含 "out of range"

### 測試指令

```bash
# 1. Build（clean build，無 error）
swift build

# 2. One-shot regression
orrery delegate --claude "echo hello"

# 3. 確認有既有 session 再測 resume
orrery sessions --claude

# 4. Resume last with prompt（Claude）
orrery delegate --claude --resume last "what was the last thing we discussed?"

# 5. Resume by index（interactive，Ctrl-C 中斷）
orrery delegate --claude --resume 1

# 6. Codex resume + prompt = error
orrery delegate --codex --resume last "new prompt" 2>&1 | grep "Codex"
echo "exit: $?"   # 應為 1

# 7. No-prompt no-resume = error
orrery delegate --claude 2>&1 | grep -i "prompt"
echo "exit: $?"   # 應為 1

# 8. Index 0 = error
orrery delegate --claude --resume 0 2>&1 | grep "must be"
echo "exit: $?"   # 應為 1

# 9. Out of range
orrery delegate --claude --resume 999 2>&1 | grep "range"
echo "exit: $?"   # 應為 1

# 10. ResumeCommand regression
orrery resume --claude 1

# 11. ResumeCommand: 'last' support（新增）
orrery resume --claude last

# 12. Environment-scoped resume（需有 'work' environment）
orrery delegate --claude -e work --resume last "continue"
```

---

## 已知限制

1. **Codex resume + prompt 不支援（Phase 1）**：Codex CLI 的 `resume` 和 `exec` 是不同 subcommand，無法組合。Phase 2 可在 `StdinMode.injectedThenInteractive` 實作 stdin pipe 注入，前提是實際測試驗證 Codex CLI 接受此模式。
2. **Claude/Gemini `--resume -p` 行為待驗證**：`claude --resume <id> -p <prompt>` 和 `gemini --resume <id> -p <prompt>` 的實際行為基於程式碼推斷，實作前需手動執行測試指令 4 以確認。
3. **Codex session 為全域（非 project-scoped）**：`SessionResolver` 以當前 env 過濾路徑，但 Codex sessions 本身不帶 project 資訊，同一 env 下所有 project 的 Codex sessions 均可見。
4. **`SessionEntry` 無 environment 來源欄位**：`orrery sessions` 輸出中無法顯示 session 屬於哪個 environment；此擴展延後。
5. **`ResumeCommand` 隱性新增 `last`/ID 支援**：重構後 `orrery resume --claude last` 可用，但原 help text 僅說明 index。本 spec 已要求更新 `L10n.Resume.abstract`。
