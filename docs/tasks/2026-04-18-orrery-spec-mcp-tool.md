# Orrery 新增 MCP tool 來實作 orrery_spec 產出的 spec（MVP：`orrery_spec_verify`）

## 來源

`docs/discussions/2026-04-18-orrery-spec-mcp-tool.md`

## 目標

把「discuss → spec → implement」閉環的最後一段從本地 `pickup` skill 升級為產品化的 MCP tool。`orrery_spec` 已能將討論 MD 轉為接近 machine-executable runbook 的結構化 spec；本案在此基礎上新增 `orrery_spec_verify` / `orrery_spec_implement` / `orrery_spec_plan` 三個分階段子 tool 與 composite `orrery_spec_run`，建在現有 `delegate + sessions` 基礎設施之上，讓任意 MCP client 皆可消費 spec、驅動實作與驗證。

**本案僅交付 MVP：`orrery_spec_verify`**（不寫碼、預設 dry-run、風險最低、對既有 spec 立即有用），把破壞半徑限縮在 working directory 內，避免一次到位的 long-running 黑箱與 client timeout 風險。

**任務順序（D17）**：Phase 1 = 本案 Spec MVP；Phase 2 = Magi extraction（`docs/tasks/2026-04-17-magi-extraction.md`）。原 D14「等 Magi extraction 完成後再動」取消；Phase 1 暫放 `Sources/OrreryCore/Spec/` 不動 `Package.swift`，Phase 2 Magi extraction 時一次性建 `OrreryMagi` + `OrrerySpec` 兩個 target 並批次搬遷。

## 介面合約（Interface Contract）

### 1. CLI：`orrery spec-run` 子命令（新）

**所在位置**：`Sources/OrreryCore/Spec/SpecRunCommand.swift`（新檔；依 D17 暫放 `OrreryCore/Spec/`，Phase 2 Magi extraction 時連同既有 `Spec/*` 一併搬到 `OrrerySpec` target）

```swift
public struct SpecRunCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "spec-run",
        abstract: L10n.SpecRun.abstract
    )

    @Argument public var specPath: String
    @Option(name: .long) public var mode: String  // plan|implement|verify|run
    @Option(name: .long) public var tool: String?  // claude|codex|gemini
    @Option(name: .long) public var resumeSessionId: String?
    @Option(name: .long) public var timeout: Int?            // 整體秒數，預設 600
    @Option(name: .long) public var perCommandTimeout: Int?  // 單指令秒數，預設 60
    @Flag(name: .long)   public var execute: Bool = false    // 關閉 dry-run、實際執行 sandboxed shell
    @Flag(name: .long)   public var strictPolicy: Bool = false  // policy_blocked 視為 fail（影響 exit code）
    @Flag(name: .long)   public var review: Bool = false     // verify pass 後觸發 Magi advisory review
    @Option(name: .shortAndLong) public var environment: String?

    public func run() throws  // print structured JSON to stdout
}
```

- **Throws**：
  - `ValidationError(L10n.SpecRun.specNotFound(path))` — spec 檔不存在
  - `ValidationError(L10n.SpecRun.invalidMode(mode))` — mode 不在合法集合
  - `ValidationError(L10n.SpecRun.missingAcceptanceSection)` — spec 缺「驗收標準」段（D16 硬約束）
  - `ValidationError(L10n.SpecRun.unknownTool(tool))` — 指定的 tool 非 `claude|codex|gemini`
- **觀察不變式**：CLI **永遠** 印一個 JSON 物件到 stdout（即使失敗），最終 exit code 由 verify 階段（D12 authoritative）或最早失敗階段決定；review 結果不影響 exit code。
- **無狀態**：command 不持久化任何 session-mapping；session 生命週期由呼叫方（CLI 使用者或 MCP client）管理。

### 2. MCP Tool：`orrery_spec_verify`（MVP 第一個 tool）

**所在位置**：`Sources/OrreryCore/MCP/MCPServer.swift`（修改 `toolDefinitions()` 與 `callTool()`）

**Input schema**：

```json
{
  "type": "object",
  "properties": {
    "spec_path":         { "type": "string", "description": "Path to spec markdown file (relative to CWD or absolute)" },
    "tool":              { "type": "string", "enum": ["claude", "codex", "gemini"] },
    "resume_session_id": { "type": "string", "description": "Accepted but ignored in verify mode (verify always uses fresh session per D9); will appear as an advisory note in stderr" },
    "timeout":           { "type": "integer", "description": "Overall seconds across all acceptance commands (default 600)" },
    "per_command_timeout": { "type": "integer", "description": "Per-command seconds before SIGTERM (default 60)" },
    "execute":           { "type": "boolean", "description": "Disable dry-run and actually execute sandboxed shell commands. Default: false (dry-run)." },
    "strict_policy":     { "type": "boolean", "description": "If true, any policy_blocked command causes non-zero exit. Default false: policy_blocked does not affect exit code." },
    "review":            { "type": "boolean", "description": "After verify completes, spawn one Magi advisory review. Default false." },
    "environment":       { "type": "string" }
  },
  "required": ["spec_path"],
  "additionalProperties": false
}
```

**Output schema**（結構化 JSON，回 MCP client；CLI stdout 同形；**error case 亦遵循同一 schema**，見 §2.error）：

```json
{
  "session_id": "string|null",
  "phase": "verify",
  "completed_steps": ["string"],
  "verification": {
    "checklist": [
      { "item": "string", "status": "pass|fail|skipped|policy_blocked", "evidence": "string" }
    ],
    "test_results": [
      { "command": "string", "exit_code": 0, "stdout_snippet": "string", "stderr_snippet": "string", "duration_ms": 0, "skipped_reason": "string|null" }
    ]
  },
  "summary_markdown": "string",
  "stderr": "string",
  "diff_summary": "string|null",
  "review": "null | { \"verdict\": \"pass|fail|advisory_only\", \"reasoning\": \"string\", \"flagged_items\": [\"string\"] }",
  "error": "string|null"
}
```

- **`session_id` 為一級欄位**（D3）；verify **一律 fresh session**（D9），所以 `resume_session_id` 會被忽略，並在 `stderr` 註記 `verify phase uses fresh session; ignored resume_session_id=<id>`。
- **預設 dry-run**：`execute=false` 時，所有 spec 中的「驗收指令」**只印不跑**，`status` 為 `skipped`，`skipped_reason="dry-run"`。
- **`execute=true` 時走 sandbox**（見 §3）：違反 policy 的指令回 `status="policy_blocked"`，**整體不中止**（其他 allowlisted 指令繼續跑）；對 exit code 的影響由 `strict_policy` 控制（預設 false = 不影響；true = 視為 fail）。
- **`review` 欄位語意**：
  - 呼叫時 `review=false`（預設）→ 輸出 `review: null`
  - 呼叫時 `review=true` 且 verify 全部 `pass` → 實際觸發 Magi、填 `{verdict, reasoning, flagged_items}`
  - 呼叫時 `review=true` 但 verify 未全 pass → 輸出 `{verdict:"advisory_only", reasoning:"verify did not fully pass; review skipped", flagged_items:[]}`；**不**呼叫 Magi（D12：review 絕不覆蓋 verify 的 authoritative exit code）
- **`error` 欄位**：正常路徑為 `null`；validation error（spec 不存在、缺驗收段、mode 不合法等）時為錯誤訊息字串，其餘 schema 欄位填空陣列/空字串以保持 client 可穩定反序列化（H5）。
- **路徑解析（M5）**：`spec_path` 為相對路徑時以 CLI 呼叫端 CWD 為基準；絕對路徑原樣使用。MCP client 建議傳絕對路徑避免歧義。

### 3. Sandbox 政策（`SpecSandboxPolicy`）

**所在位置**：`Sources/OrreryCore/Spec/SpecSandboxPolicy.swift`（新檔；依 D17 暫放 `OrreryCore/Spec/`）

```swift
public struct SpecSandboxPolicy {
    // Word-boundary-based prefixes; matched against trimmed command with
    // subsequent char requirement of end-of-string OR whitespace/tab.
    public static let allowlistPrefixes: [String] = [
        "swift build", "swift test", "swift package",
        "grep", "rg", "test",
        "git diff", "git log", "git status",
        "echo", "cat", "ls", "head", "tail",
        ".build/debug/orrery"
    ]
    // Token match: substring scan (no trailing space). Enforced BEFORE allowlist.
    public static let blocklistTokens: [String] = [
        "rm", "sudo", "dd", "mkfs",
        "git push", "git reset --hard", "git commit",
        "git checkout", "git clean", "git restore", "git stash",
        "|sh", "| sh", "|bash", "| bash", "bash -c", "sh -c",
        "cd /", "cd ~", "pushd", "popd"
    ]
    public static let perCommandTimeoutDefault: TimeInterval = 60
    public static let overallTimeoutDefault: TimeInterval = 600
    public static let stdoutByteCap: Int = 1_000_000
    public static let allowedCWDPrefix: String  // = repo root, resolved at runtime

    public enum Decision { case allowed, blocked(reason: String) }
    public static func decide(command: String) -> Decision
    public static func lintPythonRegex(snippet: String) -> Decision  // MVP: regex-based approximation (not a real AST lint; see Q8)
}
```

- **命名誠實化（H6）**：函式命名為 `lintPythonRegex` 而非 `auditPython`/`astLint`，明確它是 **regex 近似**而非真實 AST lint；Q8 留實作期把 regex 升級為呼叫 `python3 -c 'import ast; ...'` 做真 AST 解析。
- **三層防禦對應**（D10）：L1 = caller 傳 `execute=false`；L2 = `decide()` 之 blocklist（先）+ allowlist（後）；L3 = `perCommandTimeoutDefault` / `overallTimeoutDefault` / `stdoutByteCap` / CWD 鎖。
- **Blocklist 匹配規則（M1）**：token 為子字串 match，**不帶**尾空格；token 本身含空格（如 `"git push"`）靠字面字串完整匹配。token 順序：危險 token 靠前以便最早短路。
- **Allowlist 匹配規則**：對 trimmed command 做 `hasPrefix(t)` 且其後一字必為 end-of-string 或 whitespace（避免 `grepx` 誤判為 `grep` 系列）。
- **`lintPythonRegex`**：MVP 採 deny-list regex — 拒絕 `__import__` / `\bexec\s*\(` / `\beval\s*\(` / `open\s*\([^)]*['\"](?:w|a)` / `import\s+(?!ast|json|sys|re)\w+`；通過→`allowed`，否則 `blocked(reason: "python regex lint failed: <rule>")`。

### 4. Spec parser：`SpecAcceptanceParser`

**所在位置**：`Sources/OrreryCore/Spec/SpecAcceptanceParser.swift`（新檔；依 D17 暫放 `OrreryCore/Spec/`）

```swift
public struct SpecAcceptanceParser {
    public struct ChecklistItem { public let text: String }
    public struct Command       { public let line: String }

    public static func parse(markdown: String) throws -> (
        checklist: [ChecklistItem],
        commands: [Command]
    )
}
```

- **解析規則**：
  1. 找第一個 `^##\s+(驗收標準|Acceptance Criteria)\s*$` heading；找不到 → throws。
  2. 從該 heading 的**下一行**開始讀，遇到下一個 `^##\s+` heading 即停。
  3. 範圍內掃 `^- \[[ xX]\]\s+(.+)$` 為 checklist item（trim 尾空白、保留前綴 `[ ]/[x]` 資訊丟棄、只留 text）。
  4. **Fence state machine（H3）**：以 `inFence: Bool` 狀態追蹤：
     - `inFence == false` 時，遇 `^```(bash|sh)?\s*$` → 設 `inFence = true`，跳至下一行（本行不收）。
     - `inFence == true` 時，遇 `^```\s*$` → 設 `inFence = false`，跳至下一行（本行不收）；其餘行若非空且首非空白字元非 `#`，收為 command。
  5. **多行續行合併（H4）**：若 command 行以 `\` 結尾，持續讀下一行 fence 內內容並以單空格拼接，直到某行不以 `\` 結尾或 fence 結束為止；合併後再判定是否以 `#` 開頭（若整合後是註解則丟棄）。
- **Throws**：`ValidationError(L10n.SpecRun.missingAcceptanceSection)` — 若找不到「驗收標準」標題。
- **觀察不變式**：parser 不執行任何指令；commands 順序保留 spec 內出現順序；不去重。

### 5. 依賴的既有契約（MVP 使用關係）

- `EnvironmentStore.default` / `Tool` enum — 沿用 `SpecCommand` 既有用法。
- `firstAvailableTool()`（`SpecGenerator.swift`）— 可被 `SpecRunCommand` 重用以挑 default tool（在需要啟動 Magi review 時）。
- `MagiOrchestrator` / `orrery magi` CLI — 僅於 `review=true` 時透過 `Process` subprocess 呼叫；不直接 link。
- **`ProcessAgentExecutor`（屬 Magi extraction 交付物）— 依 D17 Phase 1 不存在**。verify MVP 不呼叫任何 AI agent，也無需此 protocol（M2）；未來 `implement` / `plan` 階段（Phase 1 後期）若先於 Magi extraction 完成，則暫時直接使用 `DelegateProcessBuilder` + `SessionResolver`（現有 public API），等 Magi extraction 完成後再遷移至 `AgentExecutor`。

### 6. 後續階段（同案、後續 release，僅列接口骨架）

| Tool                    | Mode        | Session 行為（D9）                    | Sandbox 預設    |
|-------------------------|-------------|---------------------------------------|-----------------|
| `orrery_spec_plan`      | `plan`      | create session_A, return id           | n/a（純 LLM）   |
| `orrery_spec_implement` | `implement` | resume session_A（預設）              | LLM 自主，無 shell sandbox |
| `orrery_spec_verify`    | `verify`    | **always fresh**                       | dry-run 預設    |
| `orrery_spec_run`       | `run`       | 串接三者，回 `{plan_session_id, impl_session_id, verify_session_id, phase_reached}` | 比照各階段 |

`run` 失敗為 **stop-and-report**（D11）；不自動 rollback、不執行任何 `git stash/reset/restore/checkout`。

## 改動檔案

| File Path | Change Description |
|---|---|
| `Sources/OrreryCore/Spec/SpecRunCommand.swift` | 新增 `spec-run` 子命令；解析 mode 後委派至對應 phase runner，將結果序列化為 JSON 印到 stdout。 |
| `Sources/OrreryCore/Spec/SpecAcceptanceParser.swift` | 新增 markdown 解析器，從 spec 抽出「驗收標準」checklist 與 bash 指令。 |
| `Sources/OrreryCore/Spec/SpecSandboxPolicy.swift` | 新增 sandbox 政策（allowlist/blocklist/timeout/CWD/stdout cap/python AST lint）。 |
| `Sources/OrreryCore/Spec/SpecVerifyRunner.swift` | 新增 verify 執行器：跑 checklist、按 sandbox 執行 commands、收集結果為結構化 JSON。 |
| `Sources/OrreryCore/Spec/SpecRunResult.swift` | 新增 `Encodable` 結果型別（`SpecRunResult`、`VerificationResult`、`ChecklistOutcome`、`CommandOutcome`、`ReviewOutcome`）+ CodingKeys 做 snake_case 轉換，統一 JSON 形狀。 |
| `Sources/OrreryCore/Commands/OrreryCommand.swift` | 在 `subcommands` array 加入 `SpecRunCommand.self`。 |
| `Sources/OrreryCore/MCP/MCPServer.swift` | `toolDefinitions()` 加入 `orrery_spec_verify`；`callTool()` 加入對應 case，組成 `orrery spec-run --mode verify` 並回傳 stdout（已是 JSON）。**另外調整 `execCommand` 的 exit-非零路徑**：改為「stdout 有內容時優先回傳 stdout」（原本是 stderr 優先）— 讓 `orrery_spec_verify` 在 `strict-policy` 失敗時仍能把結構化 JSON 送到 client。這是全域行為變更，影響所有 MCP tools（但其他 tools 在 exit 非零時 stdout 通常為空，實務上無影響）。 |
| `Sources/OrreryCore/Commands/MCPSetupCommand.swift` | 在 `installSlashCommands(projectDir:)` 內新增 `orrery:spec-verify.md` 寫入段（~40 行，抄 `orrery:magi.md` pattern）— 讓使用者可在對話框直接用 `/orrery:spec-verify`。同時 success 訊息列出 `orrery_spec_verify` 可用。 |
| `.claude/commands/orrery:spec-verify.md` | 新增 slash command 定義（由 `orrery mcp setup` 寫入）；內容說明 `/orrery:spec-verify` 的 usage 與三個 opt-in flag（`--execute` / `--strict-policy` / `--review`），以及呼叫時要 map 到 `orrery_spec_verify` MCP tool 的 arguments。 |
| `Sources/OrreryCore/Resources/Localization/en.json` | 新增 `specRun.*` 鍵（abstract、specNotFound、invalidMode、missingAcceptanceSection、unknownTool、startingPhase、policyBlocked、timeout、completed）。 |
| `Sources/OrreryCore/Resources/Localization/zh-Hant.json` | 同上中文翻譯。 |
| `Sources/OrreryCore/Resources/Localization/ja.json` | 同上日文翻譯。 |
| `Sources/OrreryCore/Resources/Localization/l10n-signatures.json` | 由 L10nCodegen plugin 自動更新。 |
| `Tests/OrreryTests/SpecAcceptanceParserTests.swift` | 新增測試：缺段落 → throw、有段落 → 正確抽出 checklist + commands、`\` 續行合併、```sh`` fence 支援、fence 未閉合容錯。 |
| `Tests/OrreryTests/SpecSandboxPolicyTests.swift` | 新增測試：allowlist / blocklist / word-boundary / CWD 越界 / `lintPythonRegex`。 |
| `Tests/OrreryTests/SpecRunCommandTests.swift` | 新增測試：`--mode verify` 對 fixture spec 跑 dry-run、JSON schema 完整、strict-policy exit code、review 三態、缺驗收段落 error shell。 |
| `CHANGELOG.md` | `## [Unreleased]` 加入 `orrery spec-run --mode verify` + `orrery_spec_verify` MCP tool；同步公告 pickup skill 進入 D13 第一階段（推薦 MCP、skill 保留）。 |
| `docs/discussions/2026-04-18-orrery-spec-mcp-tool.md` | 不變動內容；spec 完成後保持在 discussions 目錄作為決策真實來源。 |

## 實作步驟

### Step 1 — `Sources/OrreryCore/Spec/SpecAcceptanceParser.swift`

1. 定義 `ChecklistItem` / `Command` 與 `parse(markdown:)` 簽名。
2. 以 `markdown.components(separatedBy: "\n")` 切行，掃描第一個 `^##\s+(驗收標準|Acceptance Criteria)\s*$` heading；找不到 → `throw ValidationError(L10n.SpecRun.missingAcceptanceSection)`。
3. 從該 heading 之後讀，遇到下一個 `^##\s+` heading 即停。
4. 在範圍內以 state machine 處理：
   - 維護 `inFence: Bool`（初始 false）、`pendingLine: String?`（for `\` 續行）。
   - `inFence == false`：
     - 若行符合 `^- \[[ xX]\]\s+(.+)$` → checklist item（trim 尾空白，只保留 text group）。
     - 若行符合 `^\`\`\`(bash|sh)?\s*$` → `inFence = true`，continue（本行不收）。
   - `inFence == true`：
     - 若行符合 `^\`\`\`\s*$` → `inFence = false`，若 `pendingLine != nil` 先 flush（視同正常 command），再 continue。
     - 其餘：trim 行；若空字串 → skip。
     - 若 `pendingLine != nil`：合併 `pendingLine + " " + trimmedLine`；否則取 trimmedLine 為當前行 `line`。
     - 若 `line` 以 `\` 結尾：`pendingLine = line.dropLast().trim()`，continue。
     - 否則：若 `line.first != "#"`，收為 Command；`pendingLine = nil`。
5. 回傳 tuple；保留出現順序；不去重。

### Step 2 — `Sources/OrreryCore/Spec/SpecSandboxPolicy.swift`

1. 宣告 `allowlistPrefixes`、`blocklistTokens`、timeout/cap 常數（見 §3）。
2. `decide(command:)` 流程：
   - `let t = command.trimmingCharacters(in: .whitespaces)` → 若 empty → `blocked(reason: "empty command")`。
   - **Blocklist first**：對每個 `token in blocklistTokens`，若 `t.contains(token)` → `blocked(reason: "blocklist:\\(token)")`。避免 `git diff && git push` 這類混合行被 allowlist 放行。
   - **Allowlist next**：對每個 `prefix in allowlistPrefixes`，若 `t.hasPrefix(prefix)` **且** 緊接其後字元為 end-of-string 或 `.whitespaces` 中一個（含 ` `, `\t`）→ `allowed`。此規則避免 `grepx` 誤判為 `grep`。
   - Fallback → `blocked(reason: "not in allowlist")`。
3. `lintPythonRegex(snippet:)`（H6 命名）：
   - 依序拒絕：`__import__`、`\bexec\s*\(`、`\beval\s*\(`、`open\s*\([^)]*['\"](?:w|a)`、`import\s+(?!ast|json|sys|re)\w+`。
   - 通過 → `allowed`；不過 → `blocked(reason: "python regex lint failed: \\(rule)")`。
4. `allowedCWDPrefix` 由呼叫端用 `FileManager.currentDirectoryPath` 注入；任何指令含 `cd /` / `cd ~` / `pushd` / `popd` 皆視為 blocklist 命中（已在 §3 列入）。

### Step 3 — `Sources/OrreryCore/Spec/SpecRunResult.swift`

1. 定義 `Encodable` 階層：`SpecRunResult { sessionId, phase, completedSteps, verification, summaryMarkdown, stderr, diffSummary, review, error }`、`VerificationResult { checklist, testResults }`、`ChecklistOutcome { item, status, evidence }`、`CommandOutcome { command, exitCode, stdoutSnippet, stderrSnippet, durationMs, skippedReason }`、`ReviewOutcome { verdict, reasoning, flaggedItems }`。
2. **CodingKeys（M4）**：每個 struct 宣告 `enum CodingKeys: String, CodingKey` 將 Swift camelCase 對應到 JSON snake_case（`sessionId → "session_id"`、`testResults → "test_results"` 等），確保 output 與 §2 schema 一致。
3. status enum 字面值：`pass | fail | skipped | policy_blocked`；review verdict：`pass | fail | advisory_only`。
4. `review` 欄位型別為 `ReviewOutcome?`（nullable）；`error` 為 `String?`，正常路徑為 `nil`、error case 為訊息字串。
5. 提供 `func toJSONString() throws -> String`，使用 `JSONEncoder` with `.sortedKeys, .prettyPrinted`。
6. 提供便利建構子 `SpecRunResult.errorShell(phase:error:)` 用於 validation error，填空陣列/空字串保持 schema 穩定（H5）。
7. **自訂 `encode(to:)`（schema stability 必要）**：Swift `JSONEncoder` 預設會**省略** nil Optional 欄位，但 §2 output schema 規定 `session_id` / `review` / `diff_summary` / `error` 等欄位即使為 null 也要**顯式**出現在 JSON（否則 MCP client 無法穩定 decode）。故在 `SpecRunResult` 與 `CommandOutcome`（`skipped_reason: String?`）兩個 struct 內 override `encode(to:)`，逐欄 `try container.encode(optionalValue, forKey: .xxx)` — Swift 的 `KeyedEncodingContainer.encode(_:forKey:)` 對 Optional 會自動呼叫 `encodeNil(forKey:)`，產出 `"key": null`。不在 `VerificationResult` / `ChecklistOutcome` / `ReviewOutcome` override（它們沒有 nil 欄位需要顯示）。

### Step 4 — `Sources/OrreryCore/Spec/SpecVerifyRunner.swift`

1. 簽名：`public static func run(specPath:, tool:, environment:, store:, execute:, strictPolicy:, perCommandTimeout:, overallTimeout:, review:) throws -> SpecRunResult`。
2. **路徑解析（M5）**：若 `specPath` 為相對路徑，以 `FileManager.currentDirectoryPath` 為基準 resolve；絕對路徑原樣使用。resolve 後檢查存在。
3. 讀 spec → call `SpecAcceptanceParser.parse`。
4. checklist：MVP 不嘗試自動驗證 prose checklist，每一項回 `status="skipped"`, `evidence="manual review required"`（後續 release 可疊加 LLM judge）。
5. commands：
   - 若 `execute == false` → 全部 `status="skipped"`, `skippedReason="dry-run"`，`exitCode=0`, snippets 空字串。
   - 若 `execute == true`：
     - 啟整體 timer（`overallTimeout`）；超時則之後所有指令直接 `status="skipped"`, `skippedReason="overall timeout"`。
     - 對每個 command：`SpecSandboxPolicy.decide` → blocked 則 `status="policy_blocked"`, `skippedReason=<reason>`；allowed 則 `Process` 執行（`/bin/bash -c <cmd>`）並設 `currentDirectoryURL = repoRoot`、`perCommandTimeout` 看門狗強制 `terminate()`、stdout/stderr 各別 drain 且 cap 在 1MB（超過截斷並在 `stdoutSnippet` 結尾追加 `…[truncated]`）。
     - exit 0 → `pass`；非 0 或 timeout → `fail`。
6. **session_id（D9）**：verify 一律 fresh session；verify MVP 本身**不**呼叫任何 agent（無 LLM judge），故 `sessionId = nil`；於 `stderr` 註記 `verify MVP runs locally without agent session`。若 caller 傳了 `resumeSessionId`，於 stderr 額外註記 `verify phase uses fresh session; ignored resume_session_id=<id>`。
7. `diffSummary`：執行 `git diff --stat`（非破壞、屬 allowlist）收集 stdout；若 working tree 乾淨則為空字串（不用 `nil`）。
8. `review`（對齊 §2 三態）：
   - `review == false`（預設）→ `result.review = nil`
   - `review == true` 且 test_results 全 `pass` 或 `skipped(dry-run)`、無 `fail`、且（依 `strictPolicy`）無阻擋的 `policy_blocked` → spawn `orrery magi --rounds 1` advisory 呼叫並把結果摘要塞入 `ReviewOutcome(verdict: ..., reasoning: ..., flaggedItems: ...)`
   - `review == true` 但 verify 未全 pass → `result.review = ReviewOutcome(verdict: "advisory_only", reasoning: "verify did not fully pass; review skipped", flaggedItems: [])`；**不**呼叫 Magi
   - Magi subprocess 本身失敗 → `ReviewOutcome(verdict: "advisory_only", reasoning: "magi review unavailable: <stderr>", flaggedItems: [])`
9. `summaryMarkdown`：拼一段含 pass/fail/policy_blocked 計數、第一個 fail 指令的 stderr snippet、以及（若有 `policy_blocked`）**建議**的手動執行提示（僅字串，**絕不**自動執行）。

### Step 5 — `Sources/OrreryCore/Spec/SpecRunCommand.swift`

1. 解析 flags；`mode` 不是 `plan|implement|verify|run` → throw `invalidMode`。
2. MVP 只實作 `verify`：其餘 mode 直接 throw `ValidationError(L10n.SpecRun.modeNotImplemented(mode))`，error message 指向「下一個 release」。
3. 解析 spec 路徑（相對路徑用 CWD resolve，見 Step 4.2；不存在 → `specNotFound`）。
4. resolve env、tool（`tool` 字串轉 `Tool?`，未識別 → throw `unknownTool`）。
5. call `SpecVerifyRunner.run(...)` → 取得 `SpecRunResult`。
6. `print(try result.toJSONString())`。**Exit code 規則（D12）**：
   - `test_results` 中任何 `fail` → exit 1
   - `strictPolicy == true` 且有任何 `policy_blocked` → exit 1；`strictPolicy == false`（預設）→ `policy_blocked` 不影響 exit code（僅在 stderr 警告「N commands were policy_blocked; pass --strict-policy to fail on these」）
   - `review` 欄位絕不影響 exit code（D12：verify authoritative）
   - 其他 → exit 0
7. catch ValidationError → 用 `SpecRunResult.errorShell(phase: "verify", error: msg)` 產**完整 schema** 的 JSON（空陣列 + error 欄位填訊息，H5）印到 stdout，然後 `throw` 讓 ArgumentParser 設非零 exit code。

### Step 6 — `Sources/OrreryCore/Commands/OrreryCommand.swift`

1. 在 `subcommands` array 中 `SpecCommand.self` 之後插入 `SpecRunCommand.self`，保持字母順序略以 spec 群組相鄰為先。

### Step 7 — `Sources/OrreryCore/MCP/MCPServer.swift`

1. `toolDefinitions()`：在 `orrery_spec` 之後新增一個 dict，name `orrery_spec_verify`，description "Verify a spec's acceptance criteria. Default dry-run; pass `execute=true` to run sandboxed shell commands."，inputSchema 依 §2 定義。
2. `callTool(name:arguments:)` 新增 `case "orrery_spec_verify":`：
   - 取 `spec_path`（缺失 → `toolError("Missing required parameter: spec_path")`）。
   - 組 `args = ["orrery", "spec-run", "--mode", "verify", spec_path]`，依參數加 `--tool`、`--environment`、`--timeout`、`--per-command-timeout`、`--execute`、`--strict-policy`、`--review`、`--resume-session-id`（即便會被 verify 忽略，仍轉傳以便 stderr 註記一致）。
   - `execCommand(args)`；CLI 已印結構化 JSON，直接回傳。
3. **調整 `execCommand` 的 exit-非零路徑**（全域行為變更）：原本 `let msg = errOutput.isEmpty ? output : errOutput` 改為 `let msg = output.isEmpty ? errOutput : output` — stdout 有內容時優先送回 stdout。理由：`orrery_spec_verify` 在 `strict-policy` 失敗情境下 CLI 仍在 stdout 印完整 schema JSON；原本的順序會把那段 JSON 丟掉、只回 stderr 文字給 MCP client。其他 MCP tools 在 exit 非零時 stdout 通常為空，實務上不受影響；仍建議在 PR review 時 cross-check 每個 tool 的 error path。

### Step 7b — `Sources/OrreryCore/Commands/MCPSetupCommand.swift`（slash command 安裝）

1. 在 `installSlashCommands(projectDir:)` 內抄 `orrery:magi.md` 的 pattern，新增 `orrery:spec-verify.md` 寫入段（位置：接在 `try specContent.write(to: specMd, ...)` 之後）。
2. markdown 內容說明：
   - Usage：提供 spec 路徑 + 可選 flags (`--execute` / `--strict-policy` / `--review`)
   - 三條範例
   - 指示對話 LLM 使用 `orrery_spec_verify` MCP tool，並如何從 `$ARGUMENTS` 解析 flag 映射到 `execute` / `strict_policy` / `review` boolean
   - 結果摘要規範：列出 fail / policy_blocked / review verdict；`error` 非空時直接顯示錯誤
3. 重建 + 重裝後，使用者跑 `orrery mcp setup` 會把這個檔案寫到專案的 `.claude/commands/`，重啟（或自動重掃）後 `/orrery:spec-verify` 就在對話框可用。

### Step 8 — Localization

1. 在三個 `*.json` 中加入：
   - `specRun.abstract`
   - `specRun.specNotFound` (`"Spec file not found: {path}"`)
   - `specRun.invalidMode` (`"Invalid mode: {mode}. Expected one of plan|implement|verify|run"`)
   - `specRun.missingAcceptanceSection` (`"Spec is missing the '## 驗收標準' section"`)
   - `specRun.unknownTool` (`"Unknown tool: {tool}. Expected claude|codex|gemini"`)
   - `specRun.modeNotImplemented` (`"Mode '{mode}' is not yet implemented in this release. Only 'verify' is available."`)
   - `specRun.verifyFreshSession` (`"verify phase uses fresh session; ignored resume_session_id={id}"`)
   - `specRun.policyBlockedSummary` (`"{count} command(s) were policy_blocked; pass --strict-policy to fail on these"`)
   - `specRun.startingPhase` / `specRun.policyBlocked` / `specRun.timeout` / `specRun.completed`
2. 不手改 `l10n-signatures.json`；由 plugin 在 `swift build` 時重生。
3. 同步 `mCPSetup.success` 訊息加入 `orrery_spec_verify` 提示（[inferred] 三語同步）。

### Step 9 — Tests

1. `SpecAcceptanceParserTests`：
   - fixture A（含驗收段落 + 4 checklist + 3 bash 指令）→ 計數正確、順序正確。
   - fixture B（缺段落）→ throws `missingAcceptanceSection`。
   - fixture C（fence 內含 `# comment` 與空行）→ 正確被忽略。
   - fixture D（多行 `\` 續行指令）→ 合併為單一 command、`\` 後內容正確拼接。
   - fixture E（fence 以 ```` ```sh ```` 開頭）→ 被正確辨識為 command block。
   - fixture F（fence 未閉合）→ 至 EOF 結束；已收指令仍回傳。
2. `SpecSandboxPolicyTests`：
   - `swift build` / `swift test` / `grep foo` → allowed。
   - `rm -rf /` / `sudo ls` / `dd if=/dev/zero of=...` → blocked(blocklist)。
   - `git diff && git push` → blocked（blocklist 先於 allowlist）。
   - `echo hi | sh` / `echo hi | bash` → blocked。
   - `grepx foo` → blocked(not in allowlist)（word-boundary 檢查）。
   - `cd /tmp && ls` / `pushd /foo` → blocked。
   - `unknown_cmd` → blocked(not in allowlist)。
   - `lintPythonRegex`：`import ast; print(ast.parse('1'))` → allowed；`__import__('os').system('x')` → blocked；`open("f", "w")` → blocked；`import os` → blocked（不在 ast/json/sys/re 允許清單）。
3. `SpecRunCommandTests`：
   - `--mode plan` / `implement` / `run` → throws `modeNotImplemented`。
   - `--mode verify` over fixture A 預設 → 印完整 schema JSON、`test_results` 全 `skipped(dry-run)`、exit 0。
   - `--mode verify --execute` over fixture A 中含 `swift --version` → 該指令 `pass`、exit 0。
   - spec 路徑不存在 → 印 `errorShell` JSON（schema 完整、`error != null`）到 stdout、throws、exit 非零。
   - 缺驗收段落 → 同上（完整 schema JSON + `error: "Spec is missing..."`）。
   - `--resume-session-id foo --mode verify` → stdout JSON `session_id == null`、stderr 含 `verify phase uses fresh session`。
   - `--mode verify --execute` with fixture containing `git push` → `policy_blocked`；**無** `--strict-policy` → exit 0；**加** `--strict-policy` → exit 1。
   - `--mode verify --review` 且全 pass → `result.review.verdict ∈ {"pass","fail"}`；verify 未全 pass → `review.verdict == "advisory_only"` 且 Magi 子程序未啟動。

### Step 10 — `CHANGELOG.md` 與 D13 並行公告

1. `## [Unreleased] - Added`：`orrery spec-run --mode verify` 與 `orrery_spec_verify` MCP tool（含預設 dry-run、`--execute` gated 行為描述）。
2. `## [Unreleased] - Notes`：宣告 D13 第一階段 — 推薦使用 `orrery_spec_verify` MCP tool；`pickup` skill 保留作 local preview，行為不分叉；後續 +2 release 加 `@deprecated` 標記。
3. **不**動 version 字串（待整體 release 階段一次 bump，符合 CLAUDE.md 版本管理規範）。

## 失敗路徑

1. **Spec 檔不存在** → `SpecRunCommand.run` 偵測 → `throw ValidationError(L10n.SpecRun.specNotFound)` → ArgumentParser 設非零 exit；MCP `callTool` 收到非零 exit → 回 `toolError(stderr)`。**不可恢復**（需使用者修正路徑）。
2. **Spec 缺驗收段落** → `SpecAcceptanceParser.parse` raise `missingAcceptanceSection` → `SpecRunCommand` catch → 同上路徑。**不可恢復**（D16 硬約束：spec 必須有驗收段才能跑）。
3. **Mode 非法 / mode 未實作** → `SpecRunCommand.run` raise → 回 client 明確 hint「only verify available」。**不可恢復**。
4. **Sandbox blocklist 命中**（`execute=true`）→ `SpecSandboxPolicy.decide` 回 `blocked` → `SpecVerifyRunner` 設該 command `status="policy_blocked"` 並繼續下一個指令；**整體不中止**。Exit code 行為依 `strict_policy` 切換：預設（false）**不**設 1（policy_blocked 視為使用者明示 sandbox 行為，不算驗證失敗）；若 `--strict-policy` 則視為 fail、exit 1。stderr 額外 log 警告（`{count} command(s) were policy_blocked; pass --strict-policy to fail on these`）。**部分失敗 / 可恢復**（呼叫者收到 JSON 後可決定是否手動執行）。**MCP 路徑**：`strict-policy + blocklist` 組合會讓 CLI exit 1；`execCommand` 依 Step 7b 修訂的優先順序**仍把 stdout 的結構化 JSON 塞進** MCP 回應的 `content[0].text`，但 `isError=true` — client 端可 parse 該 text 取得完整 `test_results`。
5. **單指令 timeout** → `Process` 看門狗 `terminate()` → `CommandOutcome` 標 `status="fail"`, `stderr_snippet` 加 `[killed: per-command timeout exceeded]`；其餘指令繼續；最終 exit code = 1。**部分失敗**。
6. **整體 timeout** → 由 `SpecVerifyRunner` 的 timer 觸發 → 後續未跑指令全標 `status="skipped"`, `skipped_reason="overall timeout"`；最終 exit code = 1。**部分失敗**。
7. **Stdout 超過 1MB** → drain loop 截斷並在 snippet 結尾追加 `…[truncated]`；命令本身仍視為其原本 exit code 結果，不額外標 fail。**非錯誤**。
8. **`--review` 觸發但 verify 未全 pass** → `SpecVerifyRunner` **不**呼叫 Magi、寫入 `review={verdict:"advisory_only", reasoning:"verify did not fully pass; review skipped"}`；exit code 仍由 verify 決定（D12：review 永不覆蓋 verify）。**非錯誤**。
9. **Magi review 子程序失敗**（`--review` 真正觸發後）→ catch 並寫入 `review={verdict:"advisory_only", reasoning:"magi review unavailable: <stderr>"}`；exit code **不**改變（review 為 advisory）。**可恢復**。
10. **Spec 中 `git stash/reset --hard/...` 等破壞性指令** → blocklist 攔截路徑（同 #4）；任何狀況下 `SpecVerifyRunner` 都**不**自動執行 rollback 指令；可在 `summary_markdown` 中**建議** rollback 指令字串供人類複製，但**絕不**執行（D11）。

## 不改動的部分

- `Sources/OrreryCore/Spec/SpecCommand.swift`、`SpecGenerator.swift`、`SpecPromptBuilder.swift`、`SpecProfileResolver.swift`、`SpecTemplate.swift` — `orrery_spec` 既有的「discussion → spec」契約不變（討論限制：不改 orrery_spec input/output 契約）。
- `Sources/OrreryCore/Magi/*` — 不為了本案修改 Magi；review 走現有 `orrery magi --rounds 1` 子程序介面。
- `Sources/OrreryCore/Helpers/SessionResolver.swift`、`Commands/DelegateCommand.swift`、`Commands/SessionsCommand.swift` — verify MVP 不直接呼叫 delegate / sessions（無 LLM session 需求）；後續 implement/plan 階段才會用到。
- `Sources/OrreryCore/Commands/MagiCommand.swift` — 不改；review 走 CLI subprocess。
- `Package.swift` — MVP **不**新增 `OrrerySpec` library target（依 **D17**：任務順序調整為「Spec 先、Magi 後」；Phase 2 Magi extraction 時**一次性**建 `OrreryMagi` + `OrrerySpec` 兩個 target 並批次搬遷 `OrreryCore/Magi/*` 與 `OrreryCore/Spec/*`）。Phase 1 新檔案**必須集中** `Sources/OrreryCore/Spec/`，**禁止**散落 `OrreryCore` 其他子目錄，以利 Phase 2 批次搬遷。
- ~~`Sources/OrreryCore/Commands/MCPSetupCommand.swift` — 除了 success 訊息字串外，不新增 slash command 安裝（MVP 不出 `/orrery:spec-verify`）。~~ **~~已作廢（update-spec 2026-04-20）：~~**實作時發現使用者需要在對話框直接觸發，遂補上 `/orrery:spec-verify` slash command；相關改動見「改動檔案」table 的 `MCPSetupCommand.swift` / `.claude/commands/orrery:spec-verify.md` 兩列與實作步驟 T7b。
- `Sources/OrreryCore/Version.swift`、`docs/index.html`、`docs/zh_TW.html` — 版本字串本案**不**改動，留待 release 階段統一 bump（CLAUDE.md 約束）。
- `pickup` skill 程式碼 — 本案不改 skill 行為；只在 CHANGELOG 公告 D13 階段一遷移指引（並行期行為不得分叉）。
- 既有 `orrery_spec` MCP tool 的 input/output schema — 不修改（範圍約束）。
- **隱性行為注意**：新增 `orrery_spec_verify` 的 `execute=true` 預設 timeout 60s/600s 對既有大型 spec 的指令可能不足，已在 input schema 暴露 `timeout` / `per_command_timeout` 讓呼叫端覆寫；MCP server 本身**仍無狀態**，不會因新 tool 而引入後台執行緒或 cache。

## 驗收標準

### Functional contract checklist

- [ ] `orrery spec-run --mode verify <spec>` 對含「## 驗收標準」段落的 spec，預設 dry-run 模式回傳**完整 schema** JSON（`session_id`、`phase`、`completed_steps`、`verification`、`summary_markdown`、`stderr`、`diff_summary`、`review`、`error` 欄位皆存在）且 `verification.test_results` 全 `skipped(dry-run)`、`review == null`、`error == null`。
- [ ] `orrery spec-run --mode verify <spec>` 對缺「## 驗收標準」段落的 spec，stdout 仍印**完整 schema** JSON（空陣列 + `error` 填訊息）、stderr 顯示 `Spec is missing the '## 驗收標準' section`、exit code 非零。
- [ ] `orrery spec-run --mode plan|implement|run` 立即 throw `modeNotImplemented`；error message 指向 verify only。
- [ ] `orrery spec-run --mode verify --execute` 對含 allowlist 指令的 spec：allowed 指令以 `pass`/`fail` 紀錄、blocklist 指令以 `policy_blocked` 紀錄、其餘指令繼續執行。
- [ ] `orrery spec-run --mode verify --execute` 跑 60s 內完成的指令時，整體在 600s（預設）內回傳，且每個指令 `duration_ms` 欄位有值。
- [ ] `orrery spec-run --mode verify --execute` 對含 `rm -rf /` / `git push` / `git reset --hard HEAD` / `sudo ls` / `dd ...` 的 spec，**全數** `policy_blocked` 且**未**真實執行（驗證方式：執行後 `git status` 與執行前相同、檔案系統未被刪改）。
- [ ] `orrery spec-run --mode verify --execute` 預設（**無** `--strict-policy`）遇 `policy_blocked` 時 exit 0；加 `--strict-policy` 時 exit 1；兩種情況 stderr 皆警告 policy_blocked 計數。
- [ ] `orrery spec-run --mode verify --execute` 中單一指令超過 `--per-command-timeout` 設定值時被 `terminate()`、標 `fail`、其餘指令繼續、最終 exit 1。
- [ ] `orrery spec-run --mode verify --execute` 中整體超過 `--timeout` 設定值時，後續未跑指令全標 `skipped(overall timeout)`、最終 exit 1。
- [ ] `orrery spec-run --mode verify --resume-session-id <id>` 將 session id 列入 stderr 警告 `verify phase uses fresh session; ignored resume_session_id=<id>`，且 stdout JSON 的 `session_id` 為 `null`。
- [ ] `orrery spec-run --mode verify --execute --review` 在 verify 全 pass 時 `review.verdict ∈ {"pass","fail"}`、reasoning 非空；verify 未全 pass 時 `review.verdict == "advisory_only"`、Magi 子程序未被啟動（驗證：未在 `~/.orrery/magi/` 產生新檔）；`review=false`（預設）時 `review == null`。
- [ ] Parser 正確處理：`\` 續行合併為單一 command、```` ```sh ```` 與 ```` ```bash ```` 皆被辨識為 command fence、fence 未閉合時至 EOF 結束。
- [ ] verify 結果中 `diff_summary` 以 `git diff --stat` 形式呈現；若 working tree 乾淨則為空字串而非 `null`。
- [ ] verify 結果 stdout 大於 1MB 的指令，`stdout_snippet` 以 `…[truncated]` 結尾、不破壞 JSON parsing。
- [ ] JSON 所有欄位以 **snake_case** 序列化（`session_id`、`test_results`、`duration_ms` 等），即便 Swift 內部為 camelCase。
- [ ] `orrery_spec_verify` MCP tool 出現在 `tools/list` 結果中、input schema 與 §2 一致（含 `strict_policy` 欄位）。
- [ ] 透過 MCP client 呼叫 `orrery_spec_verify` 並傳 `spec_path` 即可跑通；回傳 JSON 與 CLI stdout 同形。
- [ ] `Tests/OrreryTests` 新增的三個測試檔皆通過（`SpecAcceptanceParserTests` / `SpecSandboxPolicyTests` / `SpecRunCommandTests`）。
- [ ] L10n 三語檔 `specRun.*` 鍵齊全（含 `verifyFreshSession`、`policyBlockedSummary`），`swift build` 後 `l10n-signatures.json` 自動更新且無 warning。
- [ ] `CHANGELOG.md` 含 `orrery spec-run --mode verify` 條目、D13 階段一 pickup 並行公告、以及 D17 任務順序調整說明；版本字串未變動。
- [ ] `Sources/OrreryCore/Spec/` 下新增的檔案皆位於 `OrreryCore` target 內、未動 `Package.swift`、未新增 library target（D17 Phase 1 約束）。
- [ ] `MCPSetupCommand` 的 `installSlashCommands(projectDir:)` 寫入 `orrery:spec-verify.md` 到專案的 `.claude/commands/`（驗證：跑 `orrery mcp setup` 後 `test -f .claude/commands/orrery:spec-verify.md` 成立，內容提及 `orrery_spec_verify` MCP tool mapping 與三個 opt-in flag）。
- [ ] `MCPServer.execCommand` 於 exit-非零路徑優先回傳 stdout（當 stdout 非空）— 手測：對一份只含 `git push` 指令的 fixture 以 `strict_policy=true` 呼叫 `orrery_spec_verify` MCP tool，回應 `isError=true` 但 `content[0].text` 仍為可 parse 的 `SpecRunResult` JSON。
- [ ] `SpecRunResult.encode(to:)` 顯式 encode 所有 Optional 欄位 — 手測：跑 dry-run，stdout JSON 的 `session_id` / `review` / `error` 三欄皆以 `null` 值出現，而非被省略。

### Test commands

```bash
# Build
swift build

# Unit tests
swift test --filter SpecAcceptanceParserTests
swift test --filter SpecSandboxPolicyTests
swift test --filter SpecRunCommandTests
swift test  # full suite must remain green

# CLI smoke — dry-run on existing spec
.build/debug/orrery spec-run --mode verify docs/tasks/2026-04-17-magi-extraction.md

# CLI smoke — invalid mode
.build/debug/orrery spec-run --mode plan docs/tasks/2026-04-17-magi-extraction.md ; echo "exit=$?"

# CLI smoke — missing acceptance section (use a discussion file as negative fixture)
.build/debug/orrery spec-run --mode verify docs/discussions/2026-04-18-orrery-spec-mcp-tool.md ; echo "exit=$?"

# CLI smoke — gated execute on a curated test spec
.build/debug/orrery spec-run --mode verify --execute --per-command-timeout 30 --timeout 120 \
  docs/tasks/2026-04-17-magi-extraction.md

# Verify blocklist — handcraft a spec containing `git push origin main` then run with --execute,
# confirm that the entry is policy_blocked and `git status` is unchanged before/after.
git status > /tmp/before.txt
.build/debug/orrery spec-run --mode verify --execute /tmp/blocklist-fixture.md
git status > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt  # must be empty

# strict-policy escalation — same fixture, expect non-zero exit
.build/debug/orrery spec-run --mode verify --execute --strict-policy /tmp/blocklist-fixture.md ; echo "exit=$?"

# MCP tools/list shows new tool
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' > /tmp/mcp.in
echo '{"jsonrpc":"2.0","method":"notifications/initialized"}' >> /tmp/mcp.in
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' >> /tmp/mcp.in
.build/debug/orrery mcp-server < /tmp/mcp.in | grep orrery_spec_verify

# MCP tools/call — verify in dry-run
cat <<'EOF' | .build/debug/orrery mcp-server | tail -1 | python3 -c 'import sys,json; print(json.dumps(json.loads(sys.stdin.read())["result"], indent=2)[:400])'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"orrery_spec_verify","arguments":{"spec_path":"docs/tasks/2026-04-17-magi-extraction.md"}}}
EOF

# JSON shape sanity — top-level keys present
.build/debug/orrery spec-run --mode verify docs/tasks/2026-04-17-magi-extraction.md \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); assert {"session_id","phase","completed_steps","verification","summary_markdown"} <= set(d.keys()); print("ok")'

# CHANGELOG and version untouched
grep -E "^- .*orrery_spec_verify" CHANGELOG.md
grep -E "currentVersion" Sources/OrreryCore/MCP/MCPServer.swift
```