# Magi 增強：角色視角機制 + 討論後 Spec 產出管線

## 來源

討論：本次 Magi 即時討論（三輪），主題涵蓋：
1. 是否將 write-spec 整合進 Orrery
2. 討論結果整理流程（共識報告 → 結構化摘要 → spec）
3. Spec 撰寫流程（單一模型撰寫 + 可選 review）
4. Magi 角色視角機制（動態分配 Decision Tension Triad）

## 目標

Magi 目前三個模型使用完全相同的 prompt，容易產出同質化觀點。本任務為 Magi 加入**角色視角機制**，讓每個參與模型以不同的決策壓力切入議題（如正確性/風險、實作/交付、架構/演化），製造真正互補的分析框架。同時加入**討論後 spec 產出管線**，讓使用者可在 Magi 討論結束後，將共識報告收斂為結構化摘要（spec-ready brief），再由單一模型撰寫 spec，可選地由另一模型 review。

---

## 介面合約（Interface Contract）

### `MagiRole`（新增，MagiRun.swift）

```swift
public struct MagiRole: Codable, Equatable {
    public let id: String          // e.g. "verifier", "pragmatist", "strategist"
    public let label: String       // 顯示名稱，e.g. "Verifier"
    public let instruction: String // 一行短指令，注入 prompt
    // instruction 範例：
    // "Prioritize finding risks, assumption gaps, and verification holes."
    // "Prioritize estimating delivery cost, complexity, and operability."
    // "Prioritize evaluating module boundaries, extensibility, and long-term evolution."
}
```

- `instruction` 控制在 1-2 句以內（50-80 tokens），不寫厚重人設
- `id` 用於 JSON 序列化和 CLI 參數對應

### `MagiRolePreset`（新增，MagiRun.swift）

```swift
public enum MagiRolePreset: String, CaseIterable, Codable {
    case balanced    // 預設三角：Verifier / Pragmatist / Strategist
    case adversarial // Devil's Advocate / Optimist / Mediator
    case security    // Attacker / Defender / Auditor
}
```

每個 preset 提供一組 `[MagiRole]`：

```swift
extension MagiRolePreset {
    public var roles: [MagiRole] {
        switch self {
        case .balanced:
            return [
                MagiRole(id: "verifier",
                         label: "Verifier",
                         instruction: "Prioritize finding risks, assumption gaps, and verification holes. Challenge: Is this really correct?"),
                MagiRole(id: "pragmatist",
                         label: "Pragmatist",
                         instruction: "Prioritize estimating delivery cost, complexity, and operability. Challenge: Is this worth it? Can we ship it?"),
                MagiRole(id: "strategist",
                         label: "Strategist",
                         instruction: "Prioritize evaluating module boundaries, extensibility, and long-term evolution. Challenge: Will this hold up in 6 months?"),
            ]
        case .adversarial:
            return [
                MagiRole(id: "devils-advocate", label: "Devil's Advocate",
                         instruction: "Actively argue against the proposal. Find every flaw, edge case, and reason it could fail."),
                MagiRole(id: "optimist", label: "Optimist",
                         instruction: "Argue for the proposal's strengths. Highlight benefits, opportunities, and positive outcomes."),
                MagiRole(id: "mediator", label: "Mediator",
                         instruction: "Synthesize both sides. Identify common ground and propose balanced compromises."),
            ]
        case .security:
            return [
                MagiRole(id: "attacker", label: "Attacker",
                         instruction: "Think like an attacker. Find vulnerabilities, attack surfaces, and exploitation paths."),
                MagiRole(id: "defender", label: "Defender",
                         instruction: "Design defenses. Propose mitigations, hardening measures, and monitoring strategies."),
                MagiRole(id: "auditor", label: "Auditor",
                         instruction: "Verify compliance. Check against standards, best practices, and regulatory requirements."),
            ]
        }
    }
}
```

### `MagiRun`（修改，MagiRun.swift）

```swift
public struct MagiRun: Codable {
    // ... 現有欄位不變 ...
    public var roleAssignments: [String: MagiRole]?  // 新增，key = tool.rawValue
}
```

- `roleAssignments` 為 nil 時表示無角色（向後相容）
- JSON 序列化時 key 為 tool name，value 為 MagiRole

### `MagiAgentResponse`（修改，MagiRun.swift）

```swift
public struct MagiAgentResponse: Codable {
    public let tool: Tool
    public let role: MagiRole?           // 新增，此回應時的角色
    public let rawOutput: String
    public let positions: [MagiPositionEntry]?
    public let votes: [MagiVote]?
    public let parseSuccess: Bool
}
```

### `MagiPromptBuilder.buildPrompt()`（修改）

```swift
public static func buildPrompt(
    topic: String,
    subtopics: [String],
    previousRounds: [MagiRound],
    currentRound: Int,
    targetTool: Tool,
    role: MagiRole?           // 新增參數
) -> String
```

Prompt 結構變化——在 `### Your Task` 段落前插入角色指令：

```
### Your Role
You are {tool.rawValue} acting as **{role.label}**.
{role.instruction}

Analyze each sub-topic from this perspective. Your role shapes your priorities,
not your conclusion — you can still agree or disagree with others.
```

- 若 `role == nil`，省略此段落（向後相容）
- 角色指令不改變 JSON 輸出格式要求

> **所有權**：角色分配由 `MagiOrchestrator` 負責，`MagiPromptBuilder` 只負責注入。`MagiCommand` 負責解析 CLI 參數為角色配置。

### `MagiOrchestrator.run()`（修改）

```swift
public static func run(
    topic: String,
    subtopics: [String],
    tools: [Tool],
    maxRounds: Int,
    environment: String?,
    store: EnvironmentStore,
    outputPath: String?,
    roles: [String: MagiRole]?  // 新增參數
) throws -> MagiRun
```

- `roles` 為 nil → 不使用角色（向後相容）
- `roles` 非 nil → 逐 tool 查找對應角色，傳給 `MagiPromptBuilder`
- 若 `roles` 的 key 數量與 `tools` 不匹配，忽略多餘的、缺少的 tool 無角色

### `generateReport()`（修改，MagiOrchestrator 內部）

報告增加角色資訊：

```markdown
**Roles**: Claude (Verifier), Codex (Pragmatist), Gemini (Strategist)
```

Round details 中每個 agent header 標示角色：

```markdown
#### claude (Verifier)
```

### `MagiCommand`（修改）

```swift
@Option(name: .long, help: ArgumentHelp(L10n.Magi.rolesHelp))
public var roles: String?
// 格式：逗號分隔，按 tool 順序對應
// e.g. "verifier,pragmatist,strategist"
// 或使用 preset 名稱：e.g. "balanced", "adversarial", "security"
```

解析邏輯（在 `run()` 中）：
```
若 roles == nil → roleAssignments = nil
若 roles 是 MagiRolePreset.rawValue → 使用 preset.roles 依序分配給 tools
否則 → 以逗號分隔為 role IDs，從 balanced preset 中查找匹配的 role
      若找不到 → 建構自訂 MagiRole(id: input, label: input.capitalized, instruction: "Focus on: \(input)")
```

> **Framework 備註**：`--roles` 是 `String?` 而非 `[String]`，因為 ArgumentParser 的 `@Option` 陣列語法需要重複 flag（`--roles a --roles b`），不如逗號分隔直覺。

### MCPServer `orrery_magi` tool（修改）

inputSchema 新增：

```json
"roles": {
    "type": "string",
    "description": "Role preset (balanced, adversarial, security) or comma-separated role IDs"
}
```

callTool 新增：

```swift
if let roles = arguments["roles"] as? String {
    args += ["--roles", roles]
}
```

---

### L10n 新增 keys

| Key | en | zh-Hant | ja |
|-----|-----|---------|-----|
| `magi.rolesHelp` | `"Role preset or comma-separated role IDs (e.g. balanced, verifier,pragmatist,strategist)"` | `"角色預設或逗號分隔的角色 ID（如 balanced、verifier,pragmatist,strategist）"` | `"ロールプリセットまたはカンマ区切りのロールID（例：balanced、verifier,pragmatist,strategist）"` |
| `magi.roleAssigned` | `"{tool} assigned role: {role}"` | `"{tool} 分配角色：{role}"` | `"{tool} にロールを割り当て：{role}"` |

---

## 改動檔案

| 檔案路徑 | 改動描述 |
|---------|---------|
| `Sources/OrreryCore/Magi/MagiRun.swift` | 新增 `MagiRole`、`MagiRolePreset`；修改 `MagiAgentResponse` 加 `role` 欄位；修改 `MagiRun` 加 `roleAssignments` 欄位 |
| `Sources/OrreryCore/Magi/MagiPromptBuilder.swift` | `buildPrompt()` 加 `role` 參數；插入 `### Your Role` 段落 |
| `Sources/OrreryCore/Magi/MagiOrchestrator.swift` | `run()` 加 `roles` 參數；傳遞角色到 prompt builder 和 response；報告加角色標示 |
| `Sources/OrreryCore/Commands/MagiCommand.swift` | 新增 `--roles` option；解析 preset 或自訂角色 |
| `Sources/OrreryCore/MCP/MCPServer.swift` | `orrery_magi` tool definition 加 `roles` 屬性；`callTool` 傳遞 `--roles` |
| `Sources/OrreryCore/Resources/Localization/en.json` | 新增 `magi.rolesHelp`、`magi.roleAssigned` |
| `Sources/OrreryCore/Resources/Localization/zh-Hant.json` | 新增 `magi.rolesHelp`、`magi.roleAssigned` |
| `Sources/OrreryCore/Resources/Localization/ja.json` | 新增 `magi.rolesHelp`、`magi.roleAssigned` |
| `Sources/OrreryCore/Resources/Localization/l10n-signatures.json` | 新增 `Magi.rolesHelp`、`Magi.roleAssigned` signatures |

---

## 實作步驟

### Step 1：MagiRun.swift — 新增角色資料模型

1. 在 `MagiVote` struct 之後新增 `MagiRole` struct：
   - `id: String`、`label: String`、`instruction: String`
   - 實作 `Codable`、`Equatable`

2. 新增 `MagiRolePreset` enum：
   - cases: `balanced`、`adversarial`、`security`
   - 實作 `CaseIterable`、`Codable`
   - computed property `roles: [MagiRole]`，回傳該 preset 的 3 個角色定義
   - `balanced` preset 的角色：
     - `verifier`: "Prioritize finding risks, assumption gaps, and verification holes. Challenge: Is this really correct?"
     - `pragmatist`: "Prioritize estimating delivery cost, complexity, and operability. Challenge: Is this worth it? Can we ship it?"
     - `strategist`: "Prioritize evaluating module boundaries, extensibility, and long-term evolution. Challenge: Will this hold up in 6 months?"

3. 修改 `MagiAgentResponse`：新增 `public let role: MagiRole?`
   - 放在 `tool` 之後
   - 由於新增了 non-optional → optional property，Codable 自動合成仍相容（nil 時 JSON 中不存在此 key，decode 時 fallback nil）

4. 修改 `MagiRun`：新增 `public var roleAssignments: [String: MagiRole]?`
   - 放在 `participants` 之後
   - Optional，舊 JSON 反序列化時 fallback nil

### Step 2：MagiPromptBuilder.swift — 注入角色指令

1. 修改 `buildPrompt()` 簽名，加入 `role: MagiRole? = nil`

2. 在 `### Your Task` 段落之前（line 56 之前），插入角色段落：
   ```swift
   if let role {
       lines.append("")
       lines.append("### Your Role")
       lines.append("You are \(targetTool.rawValue) acting as **\(role.label)**.")
       lines.append(role.instruction)
       lines.append("")
       lines.append("Analyze each sub-topic from this perspective. Your role shapes your priorities, not your conclusion — you can still agree or disagree with others.")
   }
   ```

3. 修改 `### Your Task` 段落（line 58-69），將 `You are \(targetTool.rawValue).` 改為：
   ```swift
   let identity = role != nil
       ? "You are \(targetTool.rawValue) (\(role!.label))."
       : "You are \(targetTool.rawValue)."
   ```

4. 在 `### Other Participants' Positions` 段落（line 44），若有角色資訊，標示對方角色：
   - 從 `response.role` 取得角色 label
   - 原本：`"- \(response.tool.rawValue): ..."`
   - 改為：`"- \(response.tool.rawValue)\(roleLabel): ..."` where `roleLabel = response.role.map { " (\($0.label))" } ?? ""`
   - 注意：此處 `response` 的型別是 `MagiAgentResponse`，其 `role` 欄位在 Step 1 已新增

### Step 3：MagiOrchestrator.swift — 傳遞角色

1. 修改 `run()` 簽名，加入 `roles: [String: MagiRole]? = nil`

2. 在建構 `MagiRun` 時，傳入 `roleAssignments: roles`

3. 在 `for tool in tools` 迴圈內（line 30-74）：
   ```swift
   let role = roles?[tool.rawValue]
   if let role {
       print(L10n.Magi.roleAssigned(tool.rawValue, role.label))
   }
   ```

4. 修改 `MagiPromptBuilder.buildPrompt()` 呼叫（line 33-38），加入 `role: role`

5. 修改 `MagiAgentResponse` 建構（line 62-65, 68-71），加入 `role: role`（成功時）和 `role: roles?[tool.rawValue]`（失敗時）

6. 修改 `generateReport()` 函數（line 153-200）：
   - 在 `**Participants**` 行之後，若 `run.roleAssignments` 非 nil：
     ```swift
     if let assignments = run.roleAssignments {
         let roleDesc = run.participants.compactMap { tool in
             assignments[tool.rawValue].map { "\(tool.rawValue) (\($0.label))" }
         }.joined(separator: ", ")
         lines.append("**Roles**: \(roleDesc)")
     }
     ```
   - Round details 的 agent header（line 183）改為：
     ```swift
     let roleLabel = response.role.map { " (\($0.label))" } ?? ""
     lines.append("#### \(response.tool.rawValue)\(roleLabel)")
     ```

### Step 4：MagiCommand.swift — 新增 --roles 選項

1. 在 `output` option 之後新增：
   ```swift
   @Option(name: .long, help: ArgumentHelp(L10n.Magi.rolesHelp))
   public var roles: String?
   ```

2. 在 `run()` 函數中，`let subtopics = ...` 之後新增角色解析邏輯：
   ```swift
   let roleAssignments: [String: MagiRole]?
   if let rolesInput = roles {
       if let preset = MagiRolePreset(rawValue: rolesInput) {
           // Preset 名稱 → 依序分配給 tools
           let presetRoles = preset.roles
           var map: [String: MagiRole] = [:]
           for (i, tool) in tools.enumerated() {
               map[tool.rawValue] = presetRoles[i % presetRoles.count]
           }
           roleAssignments = map
       } else {
           // 逗號分隔的 role IDs
           let ids = rolesInput.components(separatedBy: ",")
               .map { $0.trimmingCharacters(in: .whitespaces) }
           let allKnownRoles = MagiRolePreset.allCases.flatMap(\.roles)
           var map: [String: MagiRole] = [:]
           for (i, tool) in tools.enumerated() {
               guard i < ids.count else { break }
               let id = ids[i]
               if let known = allKnownRoles.first(where: { $0.id == id }) {
                   map[tool.rawValue] = known
               } else {
                   // 自訂角色：用 id 建構簡易角色
                   map[tool.rawValue] = MagiRole(
                       id: id, label: id.capitalized,
                       instruction: "Focus on: \(id)")
               }
           }
           roleAssignments = map
       }
   } else {
       roleAssignments = nil
   }
   ```

3. 修改 `MagiOrchestrator.run()` 呼叫，加入 `roles: roleAssignments`

### Step 5：MCPServer.swift — 擴充 orrery_magi tool

1. 在 `orrery_magi` 的 inputSchema properties 中（`"environment"` 之後），新增：
   ```swift
   "roles": [
       "type": "string",
       "description": "Role preset (balanced, adversarial, security) or comma-separated role IDs"
   ]
   ```

2. 在 `callTool` 的 `case "orrery_magi"` 中，`args.append(topic)` 之前新增：
   ```swift
   if let roles = arguments["roles"] as? String {
       args += ["--roles", roles]
   }
   ```

### Step 6：L10n 更新

在 `en.json`、`zh-Hant.json`、`ja.json` 中新增：
- `magi.rolesHelp`
- `magi.roleAssigned`

在 `l10n-signatures.json` 中新增對應的 signatures：
- `Magi.rolesHelp` → `() -> String`
- `Magi.roleAssigned` → `(String, String) -> String`（參數：tool, role）

---

## 失敗路徑

### --roles preset 名稱不存在 [inferred]（可恢復）
- 條件：使用者輸入 `--roles unknown`，且 `unknown` 不是有效的 `MagiRolePreset`
- 退化為自訂角色：`MagiRole(id: "unknown", label: "Unknown", instruction: "Focus on: unknown")`
- 不中斷，只是角色指令較泛用
- 不 throw error，因為自訂角色是設計中的功能

### 角色數量與 tool 數量不匹配（可恢復）
- 條件：`--roles verifier,pragmatist`（2 個角色）但有 3 個 tool
- 第三個 tool 無角色（`role = nil`），其 prompt 不含角色段落
- 不 throw error

### 舊版 MagiRun JSON 反序列化（可恢復）
- 條件：讀取不含 `roleAssignments` 和 `role` 欄位的舊 JSON
- `Optional` 屬性 decode 為 nil（Codable 自動合成行為）
- 不影響舊資料讀取

---

## 不改動的部分

- `Sources/OrreryCore/Magi/MagiResponseParser.swift` — 解析邏輯不變，角色不影響 JSON 輸出格式
- `Sources/OrreryCore/Helpers/DelegateProcessBuilder.swift` — 不修改
- `Sources/OrreryCore/Commands/DelegateCommand.swift` — 不修改
- `Sources/OrreryCore/Commands/OrreryCommand.swift` — MagiCommand 已註冊，不需再改
- `Sources/OrreryCore/Commands/MCPSetupCommand.swift` — slash command prompt 不修改（MCP client 透過 roles 參數傳遞）
- `.claude/commands/orrery:magi.md` — 不修改（使用者可手動加 roles 參數）

---

## 驗收標準

### 功能合約

- [ ] `swift build` 成功
- [ ] `orrery magi --help` 顯示 `--roles` 選項及說明
- [ ] `orrery magi "test topic"` 不帶 `--roles` 時行為不變（無角色注入）
- [ ] `orrery magi --roles balanced --rounds 1 "test topic"` 正確分配 Verifier/Pragmatist/Strategist
- [ ] 討論報告中包含 `**Roles**:` 行，列出每個 tool 的角色
- [ ] 報告 Round details 的 agent header 包含角色標示（如 `#### claude (Verifier)`）
- [ ] `--roles verifier,pragmatist,strategist` 等同 `--roles balanced`
- [ ] `--roles adversarial` 使用 Devil's Advocate / Optimist / Mediator 組合
- [ ] `--roles security` 使用 Attacker / Defender / Auditor 組合
- [ ] `--roles custom1,custom2,custom3` 建構自訂角色（label = capitalized, instruction = "Focus on: ..."）
- [ ] 角色數量少於 tool 數量時，多餘的 tool 無角色，不 crash
- [ ] MagiRun JSON 中 `roleAssignments` 正確序列化
- [ ] 讀取不含 `roleAssignments` 的舊 MagiRun JSON 不 crash
- [ ] MCP `orrery_magi` tool 的 `tools/list` 回應包含 `roles` 屬性
- [ ] MCP 呼叫 `orrery_magi` 帶 `roles: "balanced"` 正確傳遞至 CLI

### 測試指令

```bash
# 1. Build
swift build

# 2. Help text 包含 --roles
swift run orrery magi --help 2>&1 | grep "roles"

# 3. 無角色時行為不變
swift run orrery magi --rounds 1 "tabs vs spaces" 2>&1 | head -20

# 4. balanced preset
swift run orrery magi --roles balanced --rounds 1 "tabs vs spaces"
# 檢查報告包含 Roles 行
swift run orrery magi --roles balanced --rounds 1 --output /tmp/magi-roles-test.md "tabs vs spaces"
grep "Roles" /tmp/magi-roles-test.md

# 5. 自訂角色
swift run orrery magi --roles "optimist,pessimist,realist" --rounds 1 "test"

# 6. 舊 JSON 相容性（讀取既有 JSON）
ls ~/.orrery/magi/*.json | head -1 | xargs swift -e 'import Foundation; let d = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])); _ = try JSONDecoder().decode(MagiRun.self, from: d); print("OK")'

# 7. MCP tool definition 包含 roles
echo -e '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | swift run orrery mcp-server 2>/dev/null | tail -1 | grep '"roles"'

# 8. Cleanup
rm -f /tmp/magi-roles-test.md
```

---

## 已知限制

1. **角色不影響共識判定邏輯**：`computeConsensus()` 仍為 deterministic 多數決，不對角色加權。角色加權共識延至未來版本。
2. **自訂角色的 instruction 較泛用**：`--roles custom1` 產生 `"Focus on: custom1"` 的指令，效果可能不如 preset。未來可支援 `--role-file` 讀取自訂定義。
3. **角色與 tool 的對應為位置性**：`--roles a,b,c` 按 tool 排列順序分配。若使用者只選 2 個 tool，只有前 2 個角色被使用。
4. **Spec 產出管線不在此 task 範圍**：本 task 僅實作角色機制。討論後的 spec 產出管線（共識報告 → 結構化摘要 → write-spec）將作為獨立 task，依賴本 task 完成。
5. **動態角色選擇延後**：根據議題語意自動選擇最適合的角色組合（Phase 2）不在此 task 範圍。第一版使用者需手動指定 `--roles`。
6. **依賴前置 task**：依賴 `2026-04-16-magi-mcp-slash-command`（已完成）。
