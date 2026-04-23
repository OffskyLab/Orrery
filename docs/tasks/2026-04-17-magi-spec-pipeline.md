# Magi Spec Pipeline：討論結果 → 結構化 Spec 自動產出

## 來源

討論：`docs/discussions/2026-04-17-magi-spec-pipeline.md`

## 目標

目前「討論 → spec」的轉換只能透過本地 skill（`/write-spec`），其他 Orrery 使用者無法使用。本任務將此能力產品化為 `orrery spec` 子命令，讓所有安裝 Orrery 的使用者都能從 Magi 共識報告（或任意 Markdown）自動產出結構化實作 spec。同時提供 `orrery magi --spec` 作為 convenience wrapper，一次完成討論 + spec 產出。Spec 格式採平台路線：內建 profiles 作為預設選項，同時支援使用者自訂 template。

---

## 介面合約（Interface Contract）

### `SpecCommand`（新增，`Commands/SpecCommand.swift`）

```swift
public struct SpecCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "spec",
        abstract: L10n.Spec.abstract
    )

    @Argument(help: ArgumentHelp(L10n.Spec.inputHelp))
    public var input: String

    @Option(name: .shortAndLong, help: ArgumentHelp(L10n.Spec.outputHelp))
    public var output: String?

    @Option(name: .long, help: ArgumentHelp(L10n.Spec.profileHelp))
    public var profile: String?  // "default", "minimal", 或自訂 template 名稱

    @Option(name: .long, help: ArgumentHelp(L10n.Spec.toolHelp))
    public var tool: String?  // 指定用哪個模型生成（claude/codex/gemini）

    @Flag(name: .long, help: ArgumentHelp(L10n.Spec.reviewHelp))
    public var review: Bool = false  // opt-in 雙模型 review

    @Option(name: .shortAndLong, help: ArgumentHelp(L10n.Spec.envHelp))
    public var environment: String?

    public init() {}
}
```

**行為**：

1. 讀取 `input` 指定的 Markdown 檔案
2. 選擇 spec profile/template（見 `SpecProfileResolver`）
3. 用單一 AI tool 生成 spec（透過 `DelegateProcessBuilder`，`-p` 模式）
4. 若 `--review` 啟用，用另一個 AI tool review 生成結果
5. 寫入 `output`（預設推導為 `input` 的 sibling path：`discussions/` → `tasks/`）
6. stdout 輸出 spec 路徑

**所有權**：`SpecCommand` 負責參數解析和流程編排。Spec 生成的 prompt 組裝由 `SpecPromptBuilder` 負責。AI tool 呼叫由 `DelegateProcessBuilder` 負責（與 magi 相同模式）。

**Framework 備註**：`@Argument` 的 `input` 為必填位置參數。ArgumentParser 中 `@Option` 的 `--profile` 若省略則為 nil，此時由 `SpecProfileResolver` 決定預設值。

### `SpecPromptBuilder`（新增，`Spec/SpecPromptBuilder.swift`）

```swift
public struct SpecPromptBuilder {
    public static func buildPrompt(
        inputContent: String,
        template: SpecTemplate,
        projectContext: String?  // 可選的專案上下文（如 CLAUDE.md 內容）
    ) -> String
}
```

**行為**：組裝給 AI 的 prompt，包含：
1. 角色指令：「你是一位 spec 撰寫者，將討論結果轉換為結構化實作 spec」
2. 輸入的 Markdown 全文
3. Template 的段落結構定義（從 `SpecTemplate` 取得）
4. 輸出格式要求：「輸出完整的 Markdown spec，依照 template 定義的段落結構」
5. 若有 `projectContext`，附加專案上下文以增強 spec 的準確性

**所有權**：`SpecPromptBuilder` 僅負責 prompt 組裝，不負責 AI 呼叫。

### `SpecReviewPromptBuilder`（新增，`Spec/SpecPromptBuilder.swift`）

```swift
public struct SpecReviewPromptBuilder {
    public static func buildReviewPrompt(
        specContent: String,
        originalInput: String,
        template: SpecTemplate
    ) -> String
}
```

**行為**：組裝 review prompt，要求 reviewer 檢查：
1. spec 是否完整覆蓋討論中的所有決策
2. 介面合約的函數簽名是否合理
3. 失敗路徑是否遺漏
4. 驗收標準是否可測試
5. 輸出格式：修正後的完整 spec（若有修改）或 `[LGTM]`（若無需修改）

### `SpecTemplate`（新增，`Spec/SpecTemplate.swift`）

```swift
public struct SpecTemplate: Codable {
    public let name: String
    public let description: String
    public let sections: [SpecSection]
}

public struct SpecSection: Codable {
    public let title: String
    public let instruction: String  // 填寫指引，注入 prompt
    public let required: Bool       // 是否必填
}
```

**行為**：定義 spec 的段落結構。每個 `SpecSection` 描述一個段落的標題和填寫規則。

### `SpecProfileResolver`（新增，`Spec/SpecProfileResolver.swift`）

```swift
public struct SpecProfileResolver {
    public static func resolve(
        profileName: String?,
        store: EnvironmentStore
    ) throws -> SpecTemplate
}
```

**行為**：

1. `profileName == nil` → 使用 `"default"` 內建 profile
2. `profileName` 匹配內建 profile 名稱 → 回傳內建 template
3. `profileName` 不匹配內建 → 搜尋自訂 template：
   - 路徑 1：`~/.orrery/templates/<profileName>.json`（全域）
   - 路徑 2：`.orrery/templates/<profileName>.json`（專案層級，優先）
4. 都找不到 → `throw` error: `L10n.Spec.profileNotFound(profileName)`

**內建 profiles**：

| Profile | 說明 |
|---------|------|
| `default` | 完整 8 段 contract-first 格式（來源、目標、介面合約、改動檔案、實作步驟、失敗路徑、不改動的部分、驗收標準） |
| `minimal` | 精簡 4 段（目標、介面合約、實作步驟、驗收標準） |
| `rfc` | RFC 風格（摘要、動機、詳細設計、替代方案、未解決問題） |

### `MagiCommand`（修改）

新增 `--spec` flag：

```swift
@Flag(name: .long, help: ArgumentHelp(L10n.Magi.specHelp))
public var spec: Bool = false
```

**行為**：當 `--spec` 啟用時，magi 討論結束後：
1. 將共識報告寫入暫存檔 `<outputPath ?? tempFile>`
2. 呼叫 `SpecCommand` 的核心邏輯（`SpecGenerator.generate()`），以共識報告作為輸入
3. stdout 輸出生成的 spec 路徑

> **所有權**：`MagiCommand` 負責串接 magi → spec 的流程。Spec 生成邏輯由 `SpecGenerator` 負責，`MagiCommand` 只是呼叫者。

### `SpecGenerator`（新增，`Spec/SpecGenerator.swift`）

```swift
public struct SpecGenerator {
    public static func generate(
        inputPath: String,
        outputPath: String?,
        profile: String?,
        tool: Tool?,
        review: Bool,
        environment: String?,
        store: EnvironmentStore
    ) throws -> String  // 回傳 output path
}
```

**行為**：核心 spec 生成流程，同時被 `SpecCommand.run()` 和 `MagiCommand` (with `--spec`) 呼叫。

1. 讀取 input Markdown
2. Resolve profile → `SpecTemplate`
3. 組裝 prompt（`SpecPromptBuilder`）
4. 選擇 AI tool（`--tool` 指定，或預設為第一個可用 tool）
5. 透過 `DelegateProcessBuilder` 呼叫 AI tool（`-p` 模式，capture output）
6. 若 `review == true`：
   - 選擇第二個可用 tool（不同於 writer）
   - 組裝 review prompt（`SpecReviewPromptBuilder`）
   - 透過 `DelegateProcessBuilder` 呼叫 reviewer
   - 若 reviewer 回傳修正版，使用修正版；若回傳 `[LGTM]`，使用原版
7. 推導 output path（若未指定）：`discussions/` → `tasks/`
8. 寫入 output file
9. 回傳 output path

**所有權**：`SpecGenerator` 擁有完整的生成流程。`DelegateProcessBuilder` 負責建構和啟動 AI 子進程（builder 負責 env var 設定、stdin 模式、IPC 清理），caller 不需再設定。

### MCPServer `orrery_spec` tool（新增）

```swift
// toolDefinitions() 中新增
[
    "name": "orrery_spec",
    "description": "Generate a structured implementation spec from a discussion report or any Markdown input.",
    "inputSchema": [
        "type": "object",
        "properties": [
            "input": [
                "type": "string",
                "description": "Path to the input Markdown file"
            ],
            "output": [
                "type": "string",
                "description": "Output path for the generated spec (optional)"
            ],
            "profile": [
                "type": "string",
                "description": "Spec profile name: default, minimal, rfc, or a custom template name"
            ],
            "review": [
                "type": "boolean",
                "description": "Enable dual-model review (default: false)"
            ],
            "environment": [
                "type": "string",
                "description": "Environment name (default: active environment)"
            ]
        ],
        "required": ["input"],
        "additionalProperties": false
    ]
]
```

callTool case：

```swift
case "orrery_spec":
    guard let input = arguments["input"] as? String else {
        return toolError("Missing required parameter: input")
    }
    var args = ["orrery", "spec"]
    if let output = arguments["output"] as? String {
        args += ["-o", output]
    }
    if let profile = arguments["profile"] as? String {
        args += ["--profile", profile]
    }
    if let review = arguments["review"] as? Bool, review {
        args.append("--review")
    }
    if let env = arguments["environment"] as? String {
        args += ["-e", env]
    }
    args.append(input)
    return execCommand(args)
```

### MCPServer `orrery_magi` tool（修改）

inputSchema 新增 `spec` 屬性：

```json
"spec": {
    "type": "boolean",
    "description": "Generate a spec from the discussion result (default: false)"
}
```

callTool 中新增：

```swift
if let spec = arguments["spec"] as? Bool, spec {
    args.append("--spec")
}
```

### `/orrery:spec` slash command（新增，`MCPSetupCommand.swift`）

安裝至 `.claude/commands/orrery:spec.md`：

```markdown
# Generate spec from discussion

Generate a structured implementation spec from a Magi consensus report
or any Markdown discussion document.

Usage: Provide the path to the input Markdown file.

Example: /orrery:spec docs/discussions/2026-04-17-my-discussion.md
Example: /orrery:spec docs/discussions/my-discussion.md --profile minimal

When this command is invoked, use the orrery_spec MCP tool with:
- input: the file path from $ARGUMENTS
- profile: extract from $ARGUMENTS if --profile is specified, otherwise omit
- review: extract from $ARGUMENTS if --review is specified, otherwise false

After receiving the result, show the user the generated spec path
and offer to open or review it.
```

---

## 改動檔案

| 檔案路徑 | 改動描述 |
|---------|---------|
| `Sources/OrreryCore/Spec/SpecCommand.swift` | **新增**：`orrery spec` 子命令定義 |
| `Sources/OrreryCore/Spec/SpecGenerator.swift` | **新增**：核心 spec 生成流程（讀取 → prompt → AI 呼叫 → review → 寫入） |
| `Sources/OrreryCore/Spec/SpecPromptBuilder.swift` | **新增**：生成 prompt 和 review prompt 組裝 |
| `Sources/OrreryCore/Spec/SpecTemplate.swift` | **新增**：`SpecTemplate`、`SpecSection` 資料模型和內建 profiles |
| `Sources/OrreryCore/Spec/SpecProfileResolver.swift` | **新增**：Profile 解析邏輯（內建 → 專案自訂 → 全域自訂） |
| `Sources/OrreryCore/Commands/OrreryCommand.swift` | **修改**：subcommands 陣列加入 `SpecCommand.self` |
| `Sources/OrreryCore/Commands/MagiCommand.swift` | **修改**：新增 `--spec` flag，討論結束後呼叫 `SpecGenerator` |
| `Sources/OrreryCore/MCP/MCPServer.swift` | **修改**：`toolDefinitions()` 新增 `orrery_spec`；`orrery_magi` 加 `spec` 屬性；`callTool()` 新增兩個 case |
| `Sources/OrreryCore/Commands/MCPSetupCommand.swift` | **修改**：`installSlashCommands()` 新增 `orrery:spec.md` |
| `Sources/OrreryCore/Resources/Localization/en.json` | **修改**：新增 `spec.*` 和 `magi.specHelp` L10n keys |
| `Sources/OrreryCore/Resources/Localization/zh-Hant.json` | **修改**：新增對應翻譯 |
| `Sources/OrreryCore/Resources/Localization/ja.json` | **修改**：新增對應翻譯 |
| `Sources/OrreryCore/Resources/Localization/l10n-signatures.json` | **修改**：新增 `Spec.*` 和 `Magi.specHelp` signatures |

**受影響但不需修改的呼叫端**：
- `Sources/OrreryCore/Helpers/DelegateProcessBuilder.swift` — 被 `SpecGenerator` 呼叫，介面不變
- `Sources/OrreryCore/Magi/MagiAgentRunner.swift` — 不受影響（spec 使用自己的 AI 呼叫路徑）

---

## 實作步驟

### Step 1：SpecTemplate.swift — 資料模型和內建 profiles

1. 建立 `Sources/OrreryCore/Spec/` 目錄

2. 定義 `SpecSection` struct：
   - `title: String` — 段落標題（如 `"## 目標"`）
   - `instruction: String` — 填寫指引，將被注入 prompt
   - `required: Bool` — 是否必填

3. 定義 `SpecTemplate` struct：
   - `name: String`、`description: String`、`sections: [SpecSection]`

4. 定義 `BuiltinProfiles` enum with static computed properties：

   **`default` profile**（8 段）：
   - 來源（required）：「標明討論 MD 路徑」
   - 目標（required）：「2-4 句說明 WHY」
   - 介面合約（required）：「每個新增/修改的函數列出簽名、例外、不變量」
   - 改動檔案（required）：「Markdown 表格：檔案路徑 + 改動描述」
   - 實作步驟（required）：「每個檔案一個 Step，函數級粒度」
   - 失敗路徑（required）：「錯誤傳播鏈，區分可恢復/不可恢復」
   - 不改動的部分（required）：「明列不改動的檔案」
   - 驗收標準（required）：「可勾選 checklist + 可執行 bash 測試指令」

   **`minimal` profile**（4 段）：
   - 目標（required）
   - 介面合約（required）
   - 實作步驟（required）
   - 驗收標準（required）

   **`rfc` profile**（5 段）：
   - 摘要（required）：「一段話概述提案」
   - 動機（required）：「為什麼需要這個改動」
   - 詳細設計（required）：「完整技術設計」
   - 替代方案（optional）：「考慮過但未採用的方案」
   - 未解決問題（optional）：「已知的待決事項」

### Step 2：SpecProfileResolver.swift — Profile 解析

1. `resolve(profileName:store:)` 邏輯：
   ```
   profileName ?? "default"
   → 檢查 BuiltinProfiles 是否有匹配 → 回傳內建 template
   → 檢查 .orrery/templates/<name>.json（CWD 下，專案層級）→ 回傳
   → 檢查 store.homeURL/templates/<name>.json（~/.orrery/，全域）→ 回傳
   → throw ValidationError(L10n.Spec.profileNotFound(name))
   ```

2. 自訂 template 的讀取：`JSONDecoder().decode(SpecTemplate.self, from: data)`

3. 專案層級優先於全域層級（相同名稱時）

### Step 3：SpecPromptBuilder.swift — Prompt 組裝

1. `buildPrompt(inputContent:template:projectContext:)` 邏輯：
   ```
   lines = []
   lines += "You are a spec writer. Convert the following discussion/report into a structured implementation spec."
   lines += ""
   lines += "## Template Structure"
   lines += "The spec MUST follow this structure:"
   for section in template.sections:
       lines += "### {section.title}"
       lines += "{section.instruction}"
       lines += "Required: {section.required ? 'yes' : 'no'}"
   lines += ""
   lines += "## Input Document"
   lines += inputContent
   if let context = projectContext:
       lines += ""
       lines += "## Project Context"
       lines += context
   lines += ""
   lines += "Output the complete spec in Markdown. Follow the template structure exactly."
   lines += "Use the language of the input document."
   return lines.joined("\n")
   ```

2. `buildReviewPrompt(specContent:originalInput:template:)` 邏輯：
   ```
   lines = []
   lines += "You are a spec reviewer. Review the following spec for completeness and correctness."
   lines += ""
   lines += "## Spec to Review"
   lines += specContent
   lines += ""
   lines += "## Original Input"
   lines += originalInput
   lines += ""
   lines += "## Template Structure (expected)"
   for section in template.sections:
       lines += "- {section.title} (required: {section.required})"
   lines += ""
   lines += "Check: 1) All decisions from the input are covered 2) Interface signatures are reasonable"
   lines += "3) Failure paths are not missing 4) Acceptance criteria are testable"
   lines += ""
   lines += "If the spec needs fixes, output the corrected full spec."
   lines += "If no changes needed, output exactly: [LGTM]"
   return lines.joined("\n")
   ```

### Step 4：SpecGenerator.swift — 核心生成流程

1. `generate(inputPath:outputPath:profile:tool:review:environment:store:)` 邏輯：

2. 讀取 input：
   ```swift
   let inputURL = URL(fileURLWithPath: inputPath)
   guard FileManager.default.fileExists(atPath: inputURL.path) else {
       throw ValidationError(L10n.Spec.inputNotFound(inputPath))
   }
   let inputContent = try String(contentsOf: inputURL, encoding: .utf8)
   ```

3. Resolve profile：
   ```swift
   let template = try SpecProfileResolver.resolve(profileName: profile, store: store)
   ```

4. 讀取可選的專案上下文（CWD 下的 `CLAUDE.md`，若存在）：
   ```swift
   let claudeMd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
       .appendingPathComponent("CLAUDE.md")
   let projectContext = try? String(contentsOf: claudeMd, encoding: .utf8)
   ```

5. 組裝 prompt：
   ```swift
   let prompt = SpecPromptBuilder.buildPrompt(
       inputContent: inputContent, template: template, projectContext: projectContext)
   ```

6. 選擇 writer tool：
   ```swift
   let writerTool = tool ?? firstAvailableTool()
   // firstAvailableTool() 依序嘗試 .claude, .codex, .gemini
   ```
   - `firstAvailableTool()` 使用與 `MagiCommand.isToolAvailable()` 相同的 `which` 檢查
   - access level：此函數定義在 `SpecGenerator` 內部為 `private static`

7. 呼叫 writer：
   ```swift
   let builder = DelegateProcessBuilder(
       tool: writerTool, prompt: prompt,
       resumeSessionId: nil, environment: environment, store: store)
   let (process, _, outputPipe) = try builder.build(outputMode: .capture)
   ```
   - builder 負責 env var 設定、stdin 設為 nullDevice、IPC 清理
   - 使用 `Pipe` 讀取 stdout，與 `MagiAgentRunner` 相同模式
   - stderr 需額外 drain（DispatchQueue + readDataToEndOfFile）避免 deadlock

8. 讀取 writer output，trim 清理

9. 若 `review == true`：
   ```swift
   let reviewerTool = firstAvailableTool(excluding: writerTool)
   let reviewPrompt = SpecReviewPromptBuilder.buildReviewPrompt(
       specContent: writerOutput, originalInput: inputContent, template: template)
   // 同上呼叫 DelegateProcessBuilder
   // 若 reviewer output 包含 "[LGTM]" → 使用 writerOutput
   // 否則 → 使用 reviewer output 作為最終 spec
   ```

10. 推導 output path（若未指定）：
    ```swift
    let outputURL: URL
    if let outputPath {
        outputURL = URL(fileURLWithPath: outputPath)
    } else {
        // discussions/ → tasks/
        let inputName = inputURL.lastPathComponent
        if inputPath.contains("discussions/") {
            outputURL = URL(fileURLWithPath: inputPath.replacingOccurrences(of: "discussions/", with: "tasks/"))
        } else {
            outputURL = URL(fileURLWithPath: "docs/tasks/\(inputName)")
        }
    }
    ```

11. 確保輸出目錄存在（`createDirectory(withIntermediateDirectories: true)`）

12. 寫入 spec：
    ```swift
    try specContent.write(to: outputURL, atomically: true, encoding: .utf8)
    return outputURL.path
    ```

### Step 5：SpecCommand.swift — 子命令定義

1. 定義如介面合約所述的 `SpecCommand` struct

2. `run()` 實作：
   ```swift
   let store = EnvironmentStore.default
   let envName = environment ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
   let selectedTool: Tool? = tool.flatMap { Tool(rawValue: $0) }

   let outputPath = try SpecGenerator.generate(
       inputPath: input,
       outputPath: output,
       profile: profile,
       tool: selectedTool,
       review: review,
       environment: envName,
       store: store)
   print(outputPath)
   ```

### Step 6：MagiCommand.swift — 新增 --spec flag

1. 在 `roles` option 之後新增：
   ```swift
   @Flag(name: .long, help: ArgumentHelp(L10n.Magi.specHelp))
   public var spec: Bool = false
   ```

2. 在 `run()` 尾部（`MagiOrchestrator.run()` 之後）新增：
   ```swift
   if spec {
       // 用 MagiOrchestrator 的 output（report）作為 spec 的 input
       // 先寫入暫存檔
       let tempDir = FileManager.default.temporaryDirectory
       let tempFile = tempDir.appendingPathComponent("magi-\(UUID().uuidString).md")
       let report = generateReport(run: magiRun)  // 注意：report 已在 MagiOrchestrator 中生成
       try report.write(to: tempFile, atomically: true, encoding: .utf8)

       let specOutput = try SpecGenerator.generate(
           inputPath: tempFile.path,
           outputPath: nil,  // 自動推導
           profile: nil,     // 使用 default
           tool: nil,        // 使用第一個可用 tool
           review: false,    // 預設不 review
           environment: envName,
           store: store)
       FileHandle.standardError.write(Data(("Spec generated: \(specOutput)\n").utf8))
       try? FileManager.default.removeItem(at: tempFile)
   }
   ```

   **注意**：`MagiOrchestrator.run()` 已經回傳 `MagiRun`，但 report 字串是在 `generateReport()` 中產生的（`private static`）。需要讓 `MagiOrchestrator.run()` 也回傳 report，或者讓 `MagiCommand` 從 output file 讀取。

   **建議做法**：從 `MagiOrchestrator.run()` 的 `outputPath` 或 magi JSON 中重新生成 report。最簡單的方式是讓 `MagiCommand` 在有 `--spec` 且有 `--output` 時，直接用 `output` 作為 `SpecGenerator` 的 input。若沒有 `--output`，從 magi run JSON 所在路徑讀取。

   **替代方案**（較乾淨）：將 `generateReport()` 改為 `internal static`，讓 `MagiCommand` 可以呼叫：
   ```swift
   let report = MagiOrchestrator.generateReport(run: magiRun)
   ```
   此需修改 `MagiOrchestrator.generateReport()` 的 access level 從 `private` 改為 `internal`。

### Step 7：MCPServer.swift — 新增 orrery_spec tool

1. 在 `toolDefinitions()` 中，`orrery_magi` 之後新增 `orrery_spec` 定義（如介面合約）

2. 在 `orrery_magi` 的 inputSchema properties 中，新增 `spec` boolean 屬性

3. 在 `callTool()` 新增 `case "orrery_spec"`（如介面合約）

4. 在 `case "orrery_magi"` 中新增：
   ```swift
   if let spec = arguments["spec"] as? Bool, spec {
       args.append("--spec")
   }
   ```

### Step 8：MCPSetupCommand.swift — 新增 /orrery:spec slash command

1. 在 `magiMd` 區塊之後，新增 `specMd` 區塊
2. 建立 `commandsDir.appendingPathComponent("orrery:spec.md")`
3. 寫入如介面合約所述的 slash command prompt

### Step 9：OrreryCommand.swift — 註冊子命令

1. 在 `subcommands` 陣列中，`MagiCommand.self` 之後加入 `SpecCommand.self`

### Step 10：L10n 更新

在 `en.json`、`zh-Hant.json`、`ja.json` 中新增：

| Key | en | zh-Hant | ja |
|-----|-----|---------|-----|
| `spec.abstract` | `"Generate a structured spec from a discussion report"` | `"從討論報告產出結構化 spec"` | `"議論レポートから構造化specを生成"` |
| `spec.inputHelp` | `"Path to the input Markdown file"` | `"輸入 Markdown 檔案路徑"` | `"入力Markdownファイルパス"` |
| `spec.outputHelp` | `"Output path for the generated spec"` | `"生成 spec 的輸出路徑"` | `"生成specの出力パス"` |
| `spec.profileHelp` | `"Spec profile: default, minimal, rfc, or custom template name"` | `"Spec profile：default、minimal、rfc 或自訂 template 名稱"` | `"Specプロファイル：default、minimal、rfc、またはカスタムテンプレート名"` |
| `spec.toolHelp` | `"AI tool to use for generation (claude/codex/gemini)"` | `"用於生成的 AI 工具（claude/codex/gemini）"` | `"生成に使用するAIツール（claude/codex/gemini）"` |
| `spec.reviewHelp` | `"Enable dual-model review for higher quality"` | `"啟用雙模型 review 以提高品質"` | `"品質向上のためデュアルモデルレビューを有効化"` |
| `spec.envHelp` | `"Environment name"` | `"環境名稱"` | `"環境名"` |
| `spec.inputNotFound` | `"Input file not found: {path}"` | `"找不到輸入檔案：{path}"` | `"入力ファイルが見つかりません：{path}"` |
| `spec.profileNotFound` | `"Spec profile not found: {name}. Available: default, minimal, rfc"` | `"找不到 spec profile：{name}。可用：default、minimal、rfc"` | `"Specプロファイルが見つかりません：{name}。利用可能：default、minimal、rfc"` |
| `spec.generating` | `"Generating spec with {tool}..."` | `"使用 {tool} 生成 spec 中..."` | `"{tool}でspec生成中..."` |
| `spec.reviewing` | `"Reviewing spec with {tool}..."` | `"使用 {tool} review spec 中..."` | `"{tool}でspecレビュー中..."` |
| `spec.generated` | `"Spec generated: {path}"` | `"Spec 已生成：{path}"` | `"Spec生成完了：{path}"` |
| `magi.specHelp` | `"Generate a spec from the discussion result"` | `"從討論結果產出 spec"` | `"議論結果からspecを生成"` |

在 `l10n-signatures.json` 中新增對應 signatures：
- `Spec.abstract` → `() -> String`
- `Spec.inputHelp` → `() -> String`
- `Spec.outputHelp` → `() -> String`
- `Spec.profileHelp` → `() -> String`
- `Spec.toolHelp` → `() -> String`
- `Spec.reviewHelp` → `() -> String`
- `Spec.envHelp` → `() -> String`
- `Spec.inputNotFound` → `(String) -> String`（參數：path）
- `Spec.profileNotFound` → `(String) -> String`（參數：name）
- `Spec.generating` → `(String) -> String`（參數：tool）
- `Spec.reviewing` → `(String) -> String`（參數：tool）
- `Spec.generated` → `(String) -> String`（參數：path）
- `Magi.specHelp` → `() -> String`

---

## 失敗路徑

### 輸入檔案不存在（不可恢復）
- 條件：`input` 指定的檔案不存在
- `SpecGenerator` throw `ValidationError(L10n.Spec.inputNotFound(inputPath))`
- CLI 顯示錯誤訊息，exit 1

### Profile 找不到（不可恢復）
- 條件：`--profile` 指定的名稱不在內建 profiles 且找不到自訂 template JSON
- `SpecProfileResolver` throw `ValidationError(L10n.Spec.profileNotFound(name))`
- CLI 顯示錯誤訊息並列出可用 profiles

### 自訂 template JSON 格式錯誤 [inferred]（不可恢復）
- 條件：自訂 template 檔案存在但 JSON decode 失敗
- `JSONDecoder` throw `DecodingError`
- `SpecProfileResolver` 不 catch，讓 error propagate 到 CLI

### 無可用 AI tool（不可恢復）
- 條件：沒有任何 tool（claude/codex/gemini）安裝在 PATH 中
- `SpecGenerator.firstAvailableTool()` throw `ValidationError(L10n.Spec.noToolAvailable)`
- **注意**：需新增 L10n key `spec.noToolAvailable`

### AI tool 執行失敗 [inferred]（不可恢復）
- 條件：`DelegateProcessBuilder.build()` 的 `process.run()` throw（tool binary 不可執行）
- error propagate 到 CLI

### AI tool 回傳空白或無效輸出 [inferred]（可恢復）
- 條件：AI tool 回傳空字串或非 Markdown 內容
- `SpecGenerator` 檢查 output 長度：若 < 100 chars，stderr 警告但仍寫入
- 使用者可手動修正後重跑

### Review tool 不可用 [inferred]（可恢復）
- 條件：`--review` 啟用但只有一個 tool 可用
- `SpecGenerator` 降級為不 review，stderr 警告：「Only one tool available, skipping review」
- 不 throw error，仍然生成 spec

### `--spec` 搭配 magi 時暫存檔寫入失敗 [inferred]（不可恢復）
- 條件：`MagiCommand` 的 `--spec` 寫入暫存檔時磁碟空間不足等
- `write()` throw，error propagate 到 CLI

---

## 不改動的部分

- `Sources/OrreryCore/Magi/MagiRun.swift` — 資料模型不變
- `Sources/OrreryCore/Magi/MagiPromptBuilder.swift` — 討論 prompt 不變
- `Sources/OrreryCore/Magi/MagiResponseParser.swift` — 解析邏輯不變
- `Sources/OrreryCore/Magi/MagiAgentRunner.swift` — 不修改
- `Sources/OrreryCore/Helpers/DelegateProcessBuilder.swift` — 被呼叫但介面不改
- `Sources/OrreryCore/Commands/DelegateCommand.swift` — 不修改
- `Sources/OrreryCore/Storage/EnvironmentStore.swift` — 不修改

**隱含行為變化**：
- `MagiOrchestrator.generateReport()` 若改為 `internal` access level，`MagiAgentRunner` 等同 module 的程式碼將可呼叫，但目前無其他呼叫者，不影響行為。

---

## 驗收標準

### 功能合約

- [ ] `swift build` 成功
- [ ] `orrery spec --help` 顯示 `input`、`--output`、`--profile`、`--tool`、`--review`、`-e` 參數
- [ ] `orrery spec docs/discussions/2026-04-17-magi-spec-pipeline.md` 生成 spec 到 `docs/tasks/`
- [ ] `orrery spec --profile minimal <input>` 使用精簡 4 段格式
- [ ] `orrery spec --profile rfc <input>` 使用 RFC 風格
- [ ] `orrery spec --profile nonexistent <input>` 顯示 "Spec profile not found" 錯誤
- [ ] 自訂 template：將 JSON 放到 `.orrery/templates/custom.json`，`orrery spec --profile custom <input>` 使用該 template
- [ ] `orrery spec --review <input>` 使用雙模型（writer + reviewer）
- [ ] `orrery spec --review <input>` 只有一個 tool 可用時，降級為單模型並顯示警告
- [ ] `orrery spec nonexistent.md` 顯示 "Input file not found" 錯誤
- [ ] `orrery magi --spec --rounds 1 "test topic"` 討論結束後自動生成 spec
- [ ] 生成的 spec 使用 input 文件的語言（中文輸入 → 中文 spec）
- [ ] MCP `tools/list` 回應包含 `orrery_spec` tool
- [ ] MCP `orrery_spec` tool 接受 `input` 參數，回傳 spec 內容
- [ ] MCP `orrery_magi` tool 接受 `spec: true` 參數
- [ ] `orrery mcp setup` 成功後 `.claude/commands/orrery:spec.md` 存在
- [ ] 既有 MCP tool 和 slash command 行為不變

### 測試指令

```bash
# 1. Build
swift build

# 2. Help text
swift run orrery spec --help 2>&1 | grep "profile"

# 3. 基本生成（需要至少一個 AI tool 可用）
swift run orrery spec docs/discussions/2026-04-17-magi-spec-pipeline.md -o /tmp/test-spec.md
test -f /tmp/test-spec.md && echo "OK" || echo "FAIL"

# 4. Profile 選項
swift run orrery spec --profile minimal docs/discussions/2026-04-17-magi-spec-pipeline.md -o /tmp/test-spec-minimal.md

# 5. 不存在的 profile
swift run orrery spec --profile nonexistent docs/discussions/2026-04-17-magi-spec-pipeline.md 2>&1 | grep "not found"

# 6. 不存在的 input
swift run orrery spec nonexistent.md 2>&1 | grep "not found"

# 7. MCP tool definition
echo -e '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | swift run orrery mcp-server 2>/dev/null | tail -1 | grep "orrery_spec"

# 8. Slash command
swift run orrery mcp setup
test -f .claude/commands/orrery:spec.md && echo "OK" || echo "FAIL"

# 9. Magi --spec flag
swift run orrery magi --help 2>&1 | grep "spec"

# 10. 自訂 template
mkdir -p .orrery/templates
echo '{"name":"test","description":"Test template","sections":[{"title":"Summary","instruction":"Write a brief summary","required":true}]}' > .orrery/templates/test.json
swift run orrery spec --profile test docs/discussions/2026-04-17-magi-spec-pipeline.md -o /tmp/test-spec-custom.md
rm -rf .orrery/templates/test.json

# 11. Cleanup
rm -f /tmp/test-spec.md /tmp/test-spec-minimal.md /tmp/test-spec-custom.md
```

---

## 已知限制

1. **Spec 品質依賴 AI 模型能力**：生成的 spec 品質取決於所選模型的能力。不同模型可能產出不同深度的 spec。使用者應 review 生成結果。
2. **無 IR 輸出（v1）**：中間結構化層為 internal，不暴露給使用者。未來可加 `--emit-brief` 輸出中間 IR JSON。
3. **自訂 template 無驗證 UI**：使用者需自行確保 template JSON 格式正確。錯誤的 JSON 會直接 throw decode error。
4. **`--spec` 搭配 magi 時 output path 推導依賴暫存檔**：暫存檔名稱含 UUID，推導出的 spec 路徑不如直接 `orrery spec` 直覺。建議搭配 `--output` 使用。
5. **單次 AI 呼叫，無串流進度**：spec 生成期間使用者無法看到進度。大型討論文件可能需要 1-2 分鐘。
6. **Review 固定為「另一個 tool」**：無法指定 reviewer 為特定模型。未來可加 `--reviewer` option。
7. **依賴前置 task**：依賴 `2026-04-16-magi-roles-and-spec-pipeline`（角色機制）。`orrery spec` 本身不依賴角色機制，但 `--spec` wrapper 路徑經由 `MagiCommand` 因此隱含依賴。
