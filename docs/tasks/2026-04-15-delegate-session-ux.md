# delegate --session UX 改善（含舊版 cleanup）

## 來源

討論：`docs/discussions/2026-04-15-delegate-session-ux.md`

## 目標

`orrery delegate` 的 session 功能有三個 UX 痛點：(1) 需手動查詢 UUID session ID，(2) 看到 ID 不知道是什麼對話，(3) 每次都要指定 `--claude`/`--codex`/`--gemini`。

此外，舊版程式碼中 Codex 的 resume+prompt 被錯誤地標記為不支援，導致存在一整套不必要的 fallback 架構（TeeCapture、SessionContextBuilder、SessionTurn）。經驗證，三個 tool 都原生支援 resume+prompt。

本任務一次完成：
1. **修正 Codex resume+prompt command**（bug fix）
2. **刪除不需要的 fallback 程式碼**（cleanup）
3. **統一三個 tool 的 managed session path**（簡化）
4. **互動式 session picker**（`--session` 無名稱 → picker，選擇後自動推斷 tool）
5. **session metadata 擴展**（加 summary，支援 `allMappings` 列出）

---

## 舊版程式碼現狀（Legacy Inventory）

> **以下列出目前 branch 上存在的舊版程式碼及處理方式。實作者必須按此清單操作，避免遺漏或衝突。**

### 需刪除的檔案

| 檔案 | 原因 | 行數 |
|------|------|------|
| `Sources/OrreryCore/Helpers/TeeCapture.swift` | Codex fallback 專用，三個 tool 都支援 native resume+prompt 後不需要 | 36 行 |
| `Sources/OrreryCore/Helpers/SessionContextBuilder.swift` | Codex fallback 專用，組合歷史 prompt 不再需要 | 34 行 |

### 需刪除的程式碼段落

| 檔案 | 位置 | 內容 | 原因 |
|------|------|------|------|
| `SessionMapping.swift` | 第 15-31 行 | `SessionTurn` struct | Codex fallback 專用 |
| `SessionMapping.swift` | 第 48-53 行 | `codexHistoryFile(name:cwd:)` | Codex fallback 專用 |
| `SessionMapping.swift` | 第 70-96 行 | `loadCodexTurns` + `appendCodexTurn` | Codex fallback 專用 |
| `DelegateCommand.swift` | 第 58-64 行 | `if tool == .codex` → `runCodexFallbackPath` 分支 | Codex 改走統一 native mapping path |
| `DelegateCommand.swift` | 第 137-187 行 | `runCodexFallbackPath` 整個 method | 不再需要 |
| `DelegateProcessBuilder.swift` | 第 16 行 | `captureStdout` 欄位 | 無 consumer |
| `DelegateProcessBuilder.swift` | 第 20, 26 行 | `init` 中的 `captureStdout` 參數 | 無 consumer |
| `DelegateProcessBuilder.swift` | 第 31-33 行 | Codex resume+prompt guard（`throw codexResumePromptUnsupported`） | **Bug：Codex 實際上支援** |
| `DelegateProcessBuilder.swift` | 第 121-130 行 | `teeCapture` 相關 stdout 邏輯 | 無 consumer |

### 需修正的程式碼

| 檔案 | 位置 | 現狀 | 正確值 |
|------|------|------|-------|
| `DelegateProcessBuilder.swift` | 第 38-39 行 | `["claude", "--resume", id, "-p", p, ...]` | `["claude", "-p", "--resume", id, p, ...]`（`-p` 要在 `--resume` 之前） |
| `DelegateProcessBuilder.swift` | 第 44-45 行 | `["codex", "resume", id]`（resume 無 prompt） | `["codex", "exec", "resume", id]` |
| `DelegateProcessBuilder.swift` | — | 缺少 `(.codex, let id?, let p?)` case | 新增 `["codex", "exec", "resume", id, p]` |
| `DelegateProcessBuilder.swift` | 第 29 行 | `build()` 回傳 `(Process, StdinMode, TeeCapture?)` | 簡化為 `(Process, StdinMode)` |

### 需刪除的 L10n key

| Key | 原因 |
|-----|------|
| `delegate.codexResumePromptUnsupported` | Codex 實際上支援 resume+prompt |

### 需修改的 L10n key

| Key | 現狀 | 改為 |
|-----|------|------|
| `delegate.sessionRequiresPrompt` | 保留 | 保留，但驗證邏輯改變（picker mode 不需 prompt guard） |
| `delegate.noPromptNoResume` | 保留 | 保留 |

---

## 介面合約（Interface Contract）

### `SessionMappingEntry`（修改）

```swift
// Sources/OrreryCore/Helpers/SessionMapping.swift
public struct SessionMappingEntry: Codable {
    public let tool: String            // "claude" | "codex" | "gemini"
    public let nativeSessionId: String?
    public let lastUsed: String        // ISO 8601
    public let summary: String?        // 新增：native session 的 firstMessage 摘要
}
```

---

### `SessionMapping`（修改）

```swift
// 刪除：SessionTurn、codexHistoryFile、loadCodexTurns、appendCodexTurn
// 新增：
public func allMappings(cwd: String) -> [(name: String, entry: SessionMappingEntry)]
// 掃描 baseDir/<projectKey>/*.json，回傳所有命名 session
```

> 路徑不變：`~/.orrery/sessions/<projectKey>/<name>.json`

---

### `DelegateProcessBuilder`（修改）

```swift
// 刪除：captureStdout 欄位、TeeCapture 回傳
// 修正：init 恢復為 5 參數（tool, prompt, resumeSessionId, environment, store）
// 修正：build() 回傳 (process: Process, stdinMode: StdinMode)
// 修正：command array（見下方）
// 刪除：Codex resume+prompt guard
```

修正後的 command array：

```swift
switch (tool, resumeSessionId, prompt) {
case (.claude, let id?, let p?): ["claude", "-p", "--resume", id, p, "--allowedTools", "Bash"]
case (.claude, let id?, nil):    ["claude", "--resume", id]
case (.claude, nil, let p?):     ["claude", "-p", p, "--allowedTools", "Bash"]
case (.codex, let id?, let p?):  ["codex", "exec", "resume", id, p]
case (.codex, let id?, nil):     ["codex", "exec", "resume", id]
case (.codex, nil, let p?):      ["codex", "exec", p]
case (.gemini, let id?, let p?): ["gemini", "--resume", id, "-p", p]
case (.gemini, let id?, nil):    ["gemini", "--resume", id]
case (.gemini, nil, let p?):     ["gemini", "-p", p]
default: fatalError("unreachable")
}
```

> **所有權不變**：builder 負責 stdin/stdout/stderr 設定。stdout 恢復為永遠 `FileHandle.standardOutput`（不再有 tee 分支）。

---

### `DelegateCommand`（重寫 managed session 邏輯）

```swift
// 刪除：runCodexFallbackPath 整個 method
// 修改：runNativeMappingPath 移除 tool != .codex guard，三個 tool 共用
// 新增：picker mode（--session 無值時）
// 修改：resolvedTool() 在 picker mode 從 mapping 推斷 tool
```

**`--session` 的兩種模式**：

1. `orrery delegate --session work "prompt"` → **命名模式**：create-or-continue named session，tool 從 mapping 推斷（若新建則從 flag 取）
2. `orrery delegate --session` → **picker 模式**：SingleSelect 列出所有 named sessions，選擇後讀取 prompt

> **Framework 備註**：ArgumentParser 的 `@Option var session: String?` 支援 `--session`（無值）的語法是用 `@Option(name: .long) var session: String?` 配合 `transform`，或改用 `@Flag(name: .long) var sessionPicker: Bool` + `@Option(name: .long) var sessionName: String?`。建議用後者以避免 ArgumentParser 的 optional value 解析歧義。

---

### `SessionPicker`（新建）

```swift
// Sources/OrreryCore/Helpers/SessionPicker.swift
public struct SessionPicker {
    /// 顯示 interactive session 選擇器
    /// 拋出：ValidationError — 非 TTY 環境
    /// 回傳：(sessionName, entry) tuple
    public static func pick(
        mappings: [(name: String, entry: SessionMappingEntry)],
        store: EnvironmentStore,
        cwd: String
    ) throws -> (name: String, entry: SessionMappingEntry)
}
```

> 使用 `SingleSelect`（`Sources/OrreryCore/UI/SingleSelect.swift`）。
> 每行格式：`name · tool · "firstMessage..." · 3 msgs · 2026-04-15 14:20`
> TTY guard：`isatty(STDIN_FILENO) == 0` 時 throw `ValidationError`，不 silent fallback。
> Summary 來源：mapping 的 `summary` 欄位（cache），若為 nil 則用 `SessionsCommand.findSessions` 即時取得 `firstMessage`。

---

## 改動檔案

| 檔案路徑 | 動作 |
|---------|------|
| `Sources/OrreryCore/Helpers/TeeCapture.swift` | **刪除** |
| `Sources/OrreryCore/Helpers/SessionContextBuilder.swift` | **刪除** |
| `Sources/OrreryCore/Helpers/SessionMapping.swift` | **修改**：刪 SessionTurn + Codex 方法；加 `summary` 欄位 + `allMappings` |
| `Sources/OrreryCore/Helpers/DelegateProcessBuilder.swift` | **修改**：刪 captureStdout/TeeCapture/Codex guard；修正 command array；簡化 build() 回傳 |
| `Sources/OrreryCore/Commands/DelegateCommand.swift` | **重寫**：刪 Codex fallback；統一 native mapping path；新增 picker mode + auto tool inference |
| `Sources/OrreryCore/Helpers/SessionPicker.swift` | **新建**：interactive session 選擇器 |
| `Sources/OrreryCore/Resources/Localization/en.json` | **修改**：刪 `codexResumePromptUnsupported`；新增 picker 相關 key |
| `Sources/OrreryCore/Resources/Localization/zh-Hant.json` | **修改**：同上 |
| `Sources/OrreryCore/Resources/Localization/ja.json` | **修改**：同上 |
| `Sources/OrreryCore/Resources/Localization/l10n-signatures.json` | **修改**：刪/加對應 signature |
| `Sources/OrreryCore/Helpers/SessionSpecifier.swift` | **不改動** |
| `Sources/OrreryCore/Helpers/SessionResolver.swift` | **不改動** |
| `Sources/OrreryCore/Commands/SessionsCommand.swift` | **不改動**（`findSessions` 被 picker 呼叫，介面不變） |

---

## 實作步驟

### Step 1：刪除 TeeCapture.swift 和 SessionContextBuilder.swift

1. `rm Sources/OrreryCore/Helpers/TeeCapture.swift`
2. `rm Sources/OrreryCore/Helpers/SessionContextBuilder.swift`
3. **此時編譯會失敗**——因為 DelegateCommand 和 DelegateProcessBuilder 仍引用它們。這是預期的，Step 2-4 會修正。

---

### Step 2：修改 SessionMapping.swift

1. **刪除** `SessionTurn` struct（第 15-31 行）
2. **刪除** `codexHistoryFile` 方法（第 48-53 行）
3. **刪除** `loadCodexTurns` 方法（第 70-78 行）
4. **刪除** `appendCodexTurn` 方法（第 80-96 行）
5. `SessionMappingEntry` 新增 `summary: String?` 欄位：
   ```swift
   public struct SessionMappingEntry: Codable {
       public let tool: String
       public let nativeSessionId: String?
       public let lastUsed: String
       public let summary: String?   // 新增

       public init(tool: String, nativeSessionId: String?, lastUsed: String, summary: String? = nil) {
           // ...
       }
   }
   ```
6. 新增 `allMappings(cwd:)` 方法：
   ```swift
   public func allMappings(cwd: String) -> [(name: String, entry: SessionMappingEntry)] {
       let projectKey = cwd.replacingOccurrences(of: "/", with: "-")
       let dir = baseDir.appendingPathComponent(projectKey)
       guard let files = try? FileManager.default.contentsOfDirectory(
           at: dir, includingPropertiesForKeys: nil
       ) else { return [] }
       return files
           .filter { $0.pathExtension == "json" }
           .compactMap { file -> (String, SessionMappingEntry)? in
               guard let data = try? Data(contentsOf: file),
                     let entry = try? JSONDecoder().decode(SessionMappingEntry.self, from: data)
               else { return nil }
               let name = file.deletingPathExtension().lastPathComponent
               return (name, entry)
           }
           .sorted { $0.1.lastUsed > $1.1.lastUsed }
   }
   ```

---

### Step 3：修改 DelegateProcessBuilder.swift

1. **刪除** `captureStdout` 欄位（第 16 行）
2. **恢復** `init` 為 5 參數（刪除 `captureStdout` 參數，第 18-27 行改回）：
   ```swift
   public init(tool: Tool, prompt: String?, resumeSessionId: String?,
               environment: String?, store: EnvironmentStore) {
       // 5 個欄位 assign
   }
   ```
3. **修正** `build()` 回傳型別為 `(process: Process, stdinMode: StdinMode)`
4. **刪除** Codex resume+prompt guard（第 31-33 行）
5. **修正** command array switch：
   ```swift
   case (.claude, let id?, let p?):
       command = ["claude", "-p", "--resume", id, p, "--allowedTools", "Bash"]
   case (.codex, let id?, let p?):
       command = ["codex", "exec", "resume", id, p]
   case (.codex, let id?, nil):
       command = ["codex", "exec", "resume", id]
   case (.codex, nil, let p?):
       command = ["codex", "exec", p]
   // Claude nil/nil 和 Gemini 的三個 case 不變
   ```
6. **刪除** teeCapture 相關邏輯（第 121-130 行），恢復為：
   ```swift
   process.standardOutput = FileHandle.standardOutput
   ```
7. **修正** return：`return (process, stdinMode)`

---

### Step 4：新建 SessionPicker.swift

```swift
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct SessionPicker {
    public static func pick(
        mappings: [(name: String, entry: SessionMappingEntry)],
        store: EnvironmentStore,
        cwd: String
    ) throws -> (name: String, entry: SessionMappingEntry) {
        guard isatty(STDIN_FILENO) != 0 else {
            throw ValidationError(L10n.Delegate.sessionPickerRequiresTTY)
        }
        guard !mappings.isEmpty else {
            throw ValidationError(L10n.Delegate.noManagedSessions)
        }

        // Build display rows with native session metadata
        let rows = mappings.map { name, entry in
            let toolBadge = Tool(rawValue: entry.tool)?.displayName ?? entry.tool
            let summary = entry.summary.map { String($0.prefix(50)) } ?? "(no summary)"
            let time = entry.lastUsed.prefix(10)  // date portion
            return "\(name) · \(toolBadge) · \(summary) · \(time)"
        }

        let selector = SingleSelect(title: "Select session:", options: rows)
        let index = selector.run()

        return mappings[index]
    }
}
```

> 使用 `SingleSelect`（`public struct`，同 module 可用）。`isatty` guard 確保非 TTY 不會 silent fallback。

---

### Step 5：重寫 DelegateCommand.swift

**完整結構**：

```swift
public struct DelegateCommand: ParsableCommand {
    // ... 現有 flags + @Option environment + @Option resume

    @Flag(name: .long, help: ArgumentHelp(L10n.Delegate.sessionPickerHelp))
    public var session: Bool = false

    @Option(name: .long, help: ArgumentHelp(L10n.Delegate.sessionNameHelp))
    public var sessionName: String?

    @Argument(help: ArgumentHelp(L10n.Delegate.promptHelp))
    public var prompt: String?

    public func run() throws {
        let store = EnvironmentStore.default
        let envName = environment ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
        let cwd = FileManager.default.currentDirectoryPath

        // Validation: --session / --session-name / --resume 互斥
        let sessionModes = [session, sessionName != nil, resume != nil].filter { $0 }.count
        if sessionModes > 1 {
            throw ValidationError(L10n.Delegate.sessionResumeExclusive)
        }

        // --- Picker mode: --session ---
        if session {
            let mapping = SessionMapping(store: store)
            let all = mapping.allMappings(cwd: cwd)
            let (name, entry) = try SessionPicker.pick(mappings: all, store: store, cwd: cwd)
            let tool = Tool(rawValue: entry.tool) ?? .claude

            // 讀 prompt（picker mode 允許之後輸入）
            let userPrompt: String
            if let p = prompt {
                userPrompt = p
            } else {
                print("Prompt: ", terminator: "")
                guard let line = readLine(), !line.isEmpty else {
                    throw ValidationError(L10n.Delegate.sessionRequiresPrompt)
                }
                userPrompt = line
            }

            try runNativeMappingPath(
                sessionName: name, userPrompt: userPrompt,
                tool: tool, envName: envName, store: store, cwd: cwd)
            return
        }

        // --- Named session mode: --session-name <name> ---
        if let sessionName = sessionName {
            guard let userPrompt = prompt else {
                throw ValidationError(L10n.Delegate.sessionRequiresPrompt)
            }
            let mapping = SessionMapping(store: store)
            let existing = mapping.load(name: sessionName, cwd: cwd)

            // auto tool inference：mapping 有 tool 就用 mapping 的；沒有就用 flag
            let tool: Tool
            if let entry = existing, let t = Tool(rawValue: entry.tool) {
                tool = t
            } else {
                tool = resolvedTool()
            }

            try runNativeMappingPath(
                sessionName: sessionName, userPrompt: userPrompt,
                tool: tool, envName: envName, store: store, cwd: cwd)
            return
        }

        // --- Native resume path (不動) ---
        let tool = resolvedTool()
        guard resume != nil || prompt != nil else {
            throw ValidationError(L10n.Delegate.noPromptNoResume)
        }

        var sessionId: String?
        if let resumeValue = resume {
            let specifier = try SessionSpecifier(resumeValue)
            let session = try SessionResolver.resolve(
                specifier, tool: tool, cwd: cwd, store: store, activeEnvironment: envName)
            sessionId = session.id
        }

        let builder = DelegateProcessBuilder(
            tool: tool, prompt: prompt,
            resumeSessionId: sessionId,
            environment: envName, store: store)
        let (process, _) = try builder.build()
        try process.run()
        process.waitUntilExit()
        throw ExitCode(process.terminationStatus)
    }

    // MARK: - Unified native mapping path (all tools)

    private func runNativeMappingPath(
        sessionName: String, userPrompt: String,
        tool: Tool, envName: String?, store: EnvironmentStore, cwd: String
    ) throws {
        let mapping = SessionMapping(store: store)
        let existing = mapping.load(name: sessionName, cwd: cwd)

        let resumeId: String?
        if let entry = existing, entry.tool == tool.rawValue {
            resumeId = entry.nativeSessionId
        } else {
            resumeId = nil
        }

        let builder = DelegateProcessBuilder(
            tool: tool, prompt: userPrompt,
            resumeSessionId: resumeId,
            environment: envName, store: store)
        let (process, _) = try builder.build()

        try process.run()
        process.waitUntilExit()

        // Save/update mapping
        let sessions = SessionsCommand.findSessions(tool: tool, cwd: cwd, store: store)
            .sorted { ($0.lastTime ?? .distantPast) > ($1.lastTime ?? .distantPast) }
        if let latest = sessions.first {
            let entry = SessionMappingEntry(
                tool: tool.rawValue,
                nativeSessionId: latest.id,
                lastUsed: ISO8601DateFormatter().string(from: Date()),
                summary: String(latest.firstMessage.prefix(80)))
            try? mapping.save(entry, name: sessionName, cwd: cwd)
        }

        throw ExitCode(process.terminationStatus)
    }

    private func resolvedTool() -> Tool {
        if codex { return .codex }
        if gemini { return .gemini }
        return .claude
    }
}
```

**關鍵變更**：
- `--session`（`@Flag`）= picker mode
- `--session-name <name>`（`@Option`）= 命名 mode
- `runCodexFallbackPath` 整個方法刪除
- `runNativeMappingPath` 移除 `tool != .codex` guard，三個 tool 共用
- picker mode 從 mapping 推斷 tool，不需 `--claude` flag
- named mode 先查 mapping 的 tool，fallback 到 flag

---

### Step 6：修改 L10n（JSON + signatures）

**刪除**（三個 JSON + signatures）：
- `delegate.codexResumePromptUnsupported`

**新增**（三個 JSON + signatures）：
- `delegate.sessionPickerHelp`：en: `"Open interactive session picker"` / zh: `"開啟互動式 session 選擇器"`
- `delegate.sessionNameHelp`：en: `"Create or continue a named session"` / zh: `"用名稱建立或接續 session"`
- `delegate.sessionPickerRequiresTTY`：en: `"Interactive session picker requires a terminal. Use --session-name <name> instead."` / zh: `"互動式選擇器需要終端環境。請改用 --session-name <name>。"`
- `delegate.noManagedSessions`：en: `"No managed sessions found. Create one with --session-name <name> first."` / zh: `"找不到已管理的 session。請先用 --session-name <name> 建立。"`

**修改**：
- `delegate.sessionHelp` → 刪除（被 `sessionPickerHelp` + `sessionNameHelp` 取代）
- `delegate.sessionResumeExclusive` → 更新：`"--session, --session-name, and --resume cannot be used together."`

---

## 失敗路徑

### `--session` + `--resume` 互斥（不可恢復）
- 條件：多個 session mode 同時使用
- throw `ValidationError(L10n.Delegate.sessionResumeExclusive)` → exit 1

### picker 非 TTY（不可恢復）
- 條件：`--session` 在非 TTY 環境（MCP / pipe）
- `SessionPicker.pick` throw `ValidationError(L10n.Delegate.sessionPickerRequiresTTY)` → exit 1

### 無 managed sessions（不可恢復）
- 條件：`--session` 但沒有任何命名 session
- `SessionPicker.pick` throw `ValidationError(L10n.Delegate.noManagedSessions)` → exit 1

### named session 無 prompt（不可恢復）
- 條件：`--session-name work`（無 prompt）
- throw `ValidationError(L10n.Delegate.sessionRequiresPrompt)` → exit 1

### native session 過期 [inferred]
- 條件：mapping 指向的 native session 被 tool 清除
- 行為：tool 自己報錯（passthrough exit code）。下次會因為 resume 失敗而走 fresh path。

### mapping 寫入失敗 [inferred]
- 被 `try?` 吞掉。process 正常回傳，mapping 不更新。

---

## 不改動的部分

- `Sources/OrreryCore/Helpers/SessionSpecifier.swift`
- `Sources/OrreryCore/Helpers/SessionResolver.swift`
- `Sources/OrreryCore/Commands/SessionsCommand.swift`（`findSessions` 介面不變）
- `Sources/OrreryCore/Commands/ResumeCommand.swift`
- `Sources/OrreryCore/Models/Tool.swift`
- `Sources/OrreryCore/UI/SingleSelect.swift`（被 `SessionPicker` 呼叫，介面不變）
- native `--resume` 機制

---

## 驗收標準

### 功能合約

- [ ] `swift build` 成功，無 `TeeCapture`/`SessionContextBuilder` 相關符號
- [ ] `orrery delegate --codex --session-name test "echo hello"` 成功（Codex 走 native mapping，非 fallback）
- [ ] `orrery delegate --claude --session-name work "fix auth"` 建立 mapping，含 `nativeSessionId` + `summary`
- [ ] 再次 `orrery delegate --session-name work "add tests"` 不帶 tool flag → 自動推斷 tool 為 claude
- [ ] `orrery delegate --session`（picker mode，需 TTY）顯示 session 列表，選擇後要求輸入 prompt
- [ ] picker 選擇後自動推斷 tool，不需 `--claude` flag
- [ ] `orrery delegate --session --resume last` exit 1，stderr 含 "cannot be used together"
- [ ] `orrery delegate --claude "task"` 行為不變（one-shot regression）
- [ ] `orrery delegate --claude --resume last "follow up"` 行為不變（native resume regression）
- [ ] `grep -r TeeCapture Sources/` 無結果
- [ ] `grep -r SessionContextBuilder Sources/` 無結果
- [ ] `grep -r SessionTurn Sources/` 無結果
- [ ] `grep -r codexResumePromptUnsupported Sources/` 無結果

### 測試指令

```bash
# 1. Build
swift build

# 2. Verify cleanup
grep -r "TeeCapture" Sources/
echo "exit: $?"   # 1
grep -r "SessionContextBuilder" Sources/
echo "exit: $?"   # 1
grep -r "SessionTurn" Sources/
echo "exit: $?"   # 1

# 3. One-shot regression
swift run orrery delegate --claude "echo hello"

# 4. Native resume regression
swift run orrery delegate --claude --resume last "continue"

# 5. Codex named session (native mapping, not fallback)
swift run orrery delegate --codex --session-name codex-test "echo hello"

# 6. Verify mapping
cat ~/.orrery/sessions/*/codex-test.json

# 7. Claude named session
swift run orrery delegate --claude --session-name work "say hello"

# 8. Auto tool inference (no --claude flag)
swift run orrery delegate --session-name work "what did you say?"

# 9. Picker mode (interactive, needs TTY)
swift run orrery delegate --session

# 10. Error: --session + --resume
swift run orrery delegate --session --resume last 2>&1 | grep "cannot be used together"
echo "exit: $?"   # 1

# 11. Cleanup test sessions
rm -f ~/.orrery/sessions/*/codex-test.json
rm -f ~/.orrery/sessions/*/work.json
```

---

## 已知限制

1. **native session 過期**：mapping 指向的 native session 可能被 tool 清除。tool 會自行報錯，Orrery 不攔截。使用者需用 `--session-name <name>` 重新建立。
2. **mapping 寫入 silent failure**：`try?` 吞掉錯誤，使用者可能以為 session 有存但實際沒有。
3. **picker 不顯示 unnamed native sessions**：picker 只列出 Orrery 命名的 sessions。原生的 UUID sessions 需用 `orrery sessions` + `--resume` 存取。
4. **`--allowedTools Bash` 硬編碼**：Claude delegate 仍然只允許 Bash tool。此為已知限制，另開 issue 處理。
5. **summary 可能過時**：mapping 的 summary 是寫入時 snapshot 的 firstMessage，不會自動更新。
6. **依賴前置 task**：`docs/tasks/2026-04-13-delegate-session.md`（native `--resume`）必須已完成。
7. **auto-discuss 不在此 spec**：AI 自主討論模式為獨立 task，見討論決策 #6。
