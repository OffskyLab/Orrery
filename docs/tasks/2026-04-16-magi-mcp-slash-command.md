# MCP 整合：新增 orrery_magi MCP tool 及 /orrery:magi slash command

## 來源

討論：`docs/discussions/2026-04-16-magi-mcp-slash-command.md`

## 目標

Orrery 的 `magi` 指令目前只能從 CLI 使用。本任務將 `orrery magi` 暴露為 MCP tool（`orrery_magi`），並新增 `/orrery:magi` slash command，讓使用者可在 Claude Code 等 MCP client 中直接啟動多模型討論。MCP 模式採同步等待、預設單輪，平衡 UX 與執行時間。

---

## 介面合約（Interface Contract）

### `orrery_magi` MCP tool definition（新增，MCPServer.swift）

```swift
// 在 toolDefinitions() 陣列中新增
[
    "name": "orrery_magi",
    "description": "Start a multi-model discussion (Claude, Codex, Gemini) on a topic and produce a consensus report.",
    "inputSchema": [
        "type": "object",
        "properties": [
            "topic": [
                "type": "string",
                "description": "Discussion topic. Use semicolons to separate sub-topics."
            ],
            "rounds": [
                "type": "integer",
                "description": "Maximum discussion rounds (default: 1 for MCP)"
            ],
            "tools": [
                "type": "array",
                "items": ["type": "string", "enum": ["claude", "codex", "gemini"]],
                "description": "Participating tools (default: all installed)"
            ],
            "environment": [
                "type": "string",
                "description": "Environment name (default: active environment)"
            ]
        ],
        "required": ["topic"],
        "additionalProperties": false
    ]
]
```

- **不含 `output` 參數**——MCP 回傳值即為報告文字，caller 自行決定存檔
- `rounds` 未指定時預設 1（MCP 專用預設值，CLI 維持 3）
- `tools` 未指定時由 CLI 決定（fallback 到所有已安裝的 tool）

> **所有權**：命令組裝和子進程生命週期由 `execCommand()` 負責（與 `orrery_delegate` 一致），MCPServer 不直接操作 `MagiOrchestrator`。

> **Framework 備註**：`execCommand()` 使用 `process.waitUntilExit()`，magi 單輪約 1-2 分鐘（3 個 tool），多輪按比例增加。MCP client 需能承受此等待時間。

### `callTool` case（新增，MCPServer.swift）

```swift
case "orrery_magi":
    guard let topic = arguments["topic"] as? String else {
        return toolError("Missing required parameter: topic")
    }
    var args = ["orrery", "magi"]
    let rounds = arguments["rounds"] as? Int ?? 1  // MCP 預設 1 輪
    args += ["--rounds", String(rounds)]
    if let env = arguments["environment"] as? String {
        args += ["-e", env]
    }
    if let tools = arguments["tools"] as? [String] {
        for tool in tools { args.append("--\(tool)") }
    }
    args.append(topic)
    return execCommand(args)
```

### `/orrery:magi` slash command（新增，MCPSetupCommand.swift）

安裝至 `.claude/commands/orrery:magi.md`：

```markdown
# Multi-model discussion (Magi)

Start a multi-model discussion where Claude, Codex, and Gemini debate a topic
and produce a consensus report.

Usage: Describe the topic to discuss. Use semicolons to separate sub-topics.

Example: /orrery:magi Should we use REST or GraphQL for the new API?
Example: /orrery:magi Performance; Developer experience; Maintenance cost

When this command is invoked, use the orrery_magi MCP tool with:
- topic: "$ARGUMENTS"
- rounds: 1 (default; use more rounds only if the user explicitly asks for deeper discussion)

If the user requests multiple rounds (e.g. "3 rounds", "deeper discussion"),
warn them it may take several minutes, then set rounds accordingly.

After receiving the result, summarize the consensus report for the user,
highlighting areas of agreement and disagreement.
```

---

## 改動檔案

| 檔案路徑 | 動作 |
|---------|------|
| `Sources/OrreryCore/MCP/MCPServer.swift` | **修改**：`toolDefinitions()` 新增 `orrery_magi`；`callTool()` 新增 case |
| `Sources/OrreryCore/Commands/MCPSetupCommand.swift` | **修改**：`installSlashCommands()` 新增 `orrery:magi.md` |
| `Sources/OrreryCore/Resources/Localization/en.json` | **修改**：更新 `mCPSetup.success` 訊息 |
| `Sources/OrreryCore/Resources/Localization/zh-Hant.json` | **修改**：更新 `mCPSetup.success` 訊息 |
| `Sources/OrreryCore/Resources/Localization/ja.json` | **修改**：更新 `mCPSetup.success` 訊息 |

---

## 實作步驟

### Step 1：修改 MCPServer.swift — toolDefinitions()

1. 在 `toolDefinitions()` 陣列中，`orrery_memory_write` 之後新增 `orrery_magi` 的 tool 定義
2. Input schema 如介面合約所述：`topic` (required string)、`rounds` (optional integer)、`tools` (optional array of strings)、`environment` (optional string)

### Step 2：修改 MCPServer.swift — callTool()

1. 在 `callTool()` 的 switch 中，`case "orrery_memory_write"` 之前新增 `case "orrery_magi"`
2. 驗證 `topic` 存在，不存在則 `return toolError("Missing required parameter: topic")`
3. 組裝命令：`["orrery", "magi", "--rounds", String(rounds), ...]`
4. `rounds` 預設 1（`arguments["rounds"] as? Int ?? 1`）——這是 MCP 專用預設，CLI 的預設仍為 3
5. `environment` 若有則加 `-e <env>`
6. `tools` 若有則對每個 tool 加 `--<tool>` flag
7. 最後 append `topic`
8. 呼叫 `execCommand(args)` 回傳

### Step 3：修改 MCPSetupCommand.swift — installSlashCommands()

1. 在 `resumeMd` 區塊之後，新增 `magiMd` 區塊
2. 建立 `commandsDir.appendingPathComponent("orrery:magi.md")`
3. 寫入如介面合約所述的 slash command prompt 內容
4. `try magiContent.write(to: magiMd, atomically: true, encoding: .utf8)`

### Step 4：更新 L10n — mCPSetup.success

更新三個語言檔的 `mCPSetup.success` key，加入 `/orrery:magi`：

| Key | en | zh-Hant | ja |
|-----|-----|---------|-----|
| `mCPSetup.success` | `"...to use /orrery:delegate, /orrery:sessions, /orrery:resume, and /orrery:magi."` | `"...即可使用 /orrery:delegate、/orrery:sessions、/orrery:resume 和 /orrery:magi。"` | `"...を使用できます：/orrery:delegate、/orrery:sessions、/orrery:resume、/orrery:magi。"` |

---

## 失敗路徑

### 缺少 topic 參數（不可恢復）
- 條件：MCP client 呼叫 `orrery_magi` 時未帶 `topic`
- `callTool()` return `toolError("Missing required parameter: topic")` → MCP client 顯示錯誤
- 不觸發子進程

### orrery magi CLI 失敗（不可恢復）
- 條件：`execCommand()` 執行 `orrery magi ...` 後 exit code != 0（如不足 2 個 tool）
- `execCommand()` 讀取 stderr → return `toolError(msg)` → MCP client 顯示錯誤
- 常見原因：`"At least 2 tools must be available for a discussion."` (L10n.Magi.insufficientTools)

### 子進程啟動失敗 [inferred]（不可恢復）
- 條件：`process.run()` throw（`orrery` binary 不在 PATH）
- `execCommand()` catch → return `toolError("Failed to run: ...")`

### 長時間無回應 [inferred]（使用者可中斷）
- 條件：magi 執行時間過長（多輪 + 多 tool）
- MCP client 端使用者可取消；MCPServer 無超時機制
- 第一版不處理——slash command prompt 已建議預設 1 輪

---

## 不改動的部分

- `Sources/OrreryCore/Magi/MagiOrchestrator.swift` — 不修改核心編排邏輯
- `Sources/OrreryCore/Magi/MagiPromptBuilder.swift` — 不修改 prompt 組裝
- `Sources/OrreryCore/Magi/MagiResponseParser.swift` — 不修改解析邏輯
- `Sources/OrreryCore/Magi/MagiRun.swift` — 不修改資料模型
- `Sources/OrreryCore/Commands/MagiCommand.swift` — 不修改 CLI 定義（MCP 透過 execCommand 呼叫 CLI）
- `Sources/OrreryCore/Helpers/DelegateProcessBuilder.swift` — 不修改
- `.mcp.json` — 不需修改（MCP server binary 不變，只是多了一個 tool）
- `Sources/OrreryCore/Resources/Localization/l10n-signatures.json` — `mCPSetup.success` 簽名不變（無新參數）

---

## 驗收標準

### 功能合約

- [ ] `swift build` 成功
- [ ] `orrery mcp setup` 執行成功，`.claude/commands/orrery:magi.md` 檔案存在
- [ ] `orrery mcp setup` 的成功訊息包含 `/orrery:magi`
- [ ] `.claude/commands/orrery:magi.md` 包含 `orrery_magi` MCP tool 名稱和 `$ARGUMENTS`
- [ ] MCPServer 的 `tools/list` 回應包含 `orrery_magi` tool
- [ ] MCPServer 的 `orrery_magi` tool 接受 `topic` 參數，回傳共識報告文字
- [ ] 未帶 `topic` 時回傳 `isError: true` 和 `"Missing required parameter: topic"`
- [ ] `rounds` 未指定時預設 1 輪（MCP 專用）
- [ ] 既有 MCP tool（`orrery_delegate` 等）行為不變

### 測試指令

```bash
# 1. Build
swift build

# 2. Setup slash commands
swift run orrery mcp setup

# 3. Verify slash command file exists
test -f .claude/commands/orrery:magi.md && echo "OK" || echo "MISSING"

# 4. Verify slash command content
grep "orrery_magi" .claude/commands/orrery:magi.md

# 5. Verify success message includes /orrery:magi
swift run orrery mcp setup 2>&1 | grep "orrery:magi"

# 6. Verify MCPServer tool definition (send tools/list via JSON-RPC)
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}' | swift run orrery mcp-server 2>/dev/null | head -1
# Then:
echo -e '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | swift run orrery mcp-server 2>/dev/null | tail -1 | grep "orrery_magi"

# 7. Regression: existing tools still listed
echo -e '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | swift run orrery mcp-server 2>/dev/null | tail -1 | grep "orrery_delegate"
```

---

## 已知限制

1. **同步阻塞**：MCP 模式下 magi 執行期間 MCP server 無法處理其他請求。這是現有 MCPServer 架構的限制，非本 task 引入。
2. **無進度通知**：MCP client 無法得知 magi 執行進度（第幾輪、哪個 tool 在回應）。背景執行 + 輪詢（方案 B）延後至未來版本。
3. **遞迴呼叫 API 消耗**：從 Claude Code 呼叫 `orrery_magi`，magi 會另起 `claude -p` 子進程（獨立實體），不與 parent session 衝突，但消耗額外 API quota。
4. **MCP 預設 1 輪 vs CLI 預設 3 輪**：MCP 的 `rounds` 預設值（1）在 `callTool()` 中硬編碼，非 `MagiCommand` 的預設值。若未來 CLI 預設值變更，MCP 不受影響。
5. **依賴前置 task**：依賴 `2026-04-15-magi-multi-model-discussion`（已完成）。
