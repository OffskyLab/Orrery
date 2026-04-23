---
topic: "Magi 功能從 Orrery 拆分為獨立專案（依賴 Orrery）"
status: consensus
created: "2026-04-17"
updated: "2026-04-18"
participants:
  - Claude (Opus 4.6)
  - Codex (GPT-5.4)
  - Gemini
facilitator: Claude
rounds_completed: 2
---

# Magi 功能從 Orrery 拆分為獨立專案（依賴 Orrery）

## 議題定義

### 背景

- 目前 Magi 以多個檔案內嵌於 `OrreryCore`：
  - `Sources/OrreryCore/Magi/` — `MagiOrchestrator`, `MagiAgentRunner`, `MagiRun`, `MagiPromptBuilder`, `MagiResponseParser`
  - `Sources/OrreryCore/Commands/MagiCommand.swift` — CLI 子命令
  - MCP 工具 `orrery_magi` 註冊於 `Sources/OrreryCore/MCP/MCPServer.swift`
  - `mcp setup` 中寫入 `orrery:magi` slash command
  - L10n keys 於 `Resources/Localization/*.json`
- Magi 對 Orrery 內部組件的依賴：
  - `EnvironmentStore`（env、homeURL、檔案持久化）
  - `DelegateProcessBuilder`（tool 執行器）
  - `SessionResolver`（session id 偵測）
  - `Tool` enum（claude/codex/gemini 名單）
  - `L10n.Magi` 字串
  - `SpecGenerator`（`--spec` 整合）
- `OrreryCore` 已經是 `library` product（`Package.swift` line 9），外部 Swift Package 可直接依賴。
- 已有 `orrery sync` 作為「獨立 repo、獨立 binary、由 orrery shell-out」的先例。

### 目標

- 評估「將 Magi 抽離為獨立專案並反向依賴 Orrery」的可行性與成本。
- 若可行，產出**遷移計畫**：repo 結構、依賴介面、CLI/MCP/slash 分配、版本發佈策略、遷移步驟。
- 若不可行，明確指出阻礙與替代方案（例如僅在同 repo 內模組化）。

### 範圍

**討論內**：
- Magi 是否適合拆分、拆分的動機與代價
- 依賴 Orrery 的方式（Swift library / CLI shell-out / 混合）
- Repo 與發佈策略（同 repo 多 target / 獨立 repo / Homebrew）
- CLI、MCP、slash command 的歸屬
- 遷移步驟與回退計畫

**討論外**：
- Magi 本身功能迭代（角色機制、roles preset 等）
- Spec pipeline 內部設計（另有討論 `2026-04-17-magi-spec-pipeline`）
- `orrery delegate` / `session` 本身的演進

### 約束

- 使用者已上線的 `orrery magi` / MCP / slash command 體驗不能硬切中斷（需有漸進遷移或對齊方案）。
- Orrery 版本與 `orrery-sync` 共用版本號（見 `CLAUDE.md` Versioning），新 repo 若獨立需明確版本策略。
- Homebrew formula 為主要發佈通路，拆分後需對應 formula 變更。
- Magi 強依賴 Orrery 的 session/env 系統，不可能完全獨立；必然需要某種反向依賴形式。

### 子議題

- [ ] 子議題 1：是否值得拆分？動機、益處、代價、風險評估
- [ ] 子議題 2：反向依賴的介面形式（Swift library / CLI shell-out / 混合）
- [ ] 子議題 3：Repo 與發佈策略（同 repo 新 target / 獨立 repo / Homebrew formula / 版本號耦合）
- [ ] 子議題 4：CLI/MCP/Slash 歸屬（`orrery magi` vs 獨立 `magi` binary；MCP server 在哪一側）
- [ ] 子議題 5：遷移路徑與回退計畫（步驟、deprecation timeline、breakage surface）

---

## 討論紀錄

### Round 1

#### Claude (Opus 4.6) — 2026-04-17

**整體立場**：**技術可行，但建議延後到有具體外部使用者或獨立迭代需求時再動手**。目前的邊界對 `OrreryCore` 內部依賴度高（`EnvironmentStore`、`DelegateProcessBuilder`、`SessionResolver`），拆分會產生實質成本但目前看不到對應的收益。我支持先做「repo 內模組化」（新 target `OrreryMagi` 依賴 `OrreryCore`），作為日後拆分的前置條件。

**子議題 1：是否值得拆分？**

- 論點 1.1 — **拆分的潛在益處有限**：
  - Magi 目前只有一個消費者（orrery 本身）。拆分帶來的「獨立版本迭代」「第三方可依賴」並沒有現實需求驅動。
  - 體積與 build time 差異可忽略（Magi 約 5 個檔案、~1.5k 行）。
- 論點 1.2 — **拆分的成本是可見的**：
  - Magi 用到 `EnvironmentStore.homeURL`、`DelegateProcessBuilder`、`SessionResolver.findScopedSessions`、`Tool` enum、`L10n.Magi`。其中 L10n 是 build-plugin 生成的（`Sources/OrreryCore/Resources/Localization/`），跨 package 使用需要複製或下放機制。
  - `orrery-sync` 的先例說明：跨 repo 會拉高版本協調成本（`CLAUDE.md` 明確規定兩 repo 共用版號）。
  - MCP tool 與 slash command 目前寫在 `MCPServer.swift` / `MCPSetupCommand.swift` 中；拆分後要決定誰擁有註冊權。
- 論點 1.3 — **拆分的正確觸發條件**（未來再做）：
  - Magi 出現非 orrery 的消費者（例如其他 CLI、IDE 擴充、Web 服務）。
  - Magi 要自己的釋出節奏（例如 weekly alpha）與 orrery stable 不一致。
  - Magi 成長到獨立團隊維護，跨 repo 隔離維護邊界才有意義。

**子議題 2：反向依賴的介面**

- 論點 2.1 — **優先考慮 Swift library 依賴**：
  - `OrreryCore` 已是 library product，Swift Package 可直接 `.package(url: …orrery…)` + `.product(name: "OrreryCore", …)`。這是最省成本的路線。
  - Magi 用到的 API 都是 public（見 `MagiOrchestrator.swift:12` 使用 `EnvironmentStore`；`MagiAgentRunner.swift:35` 使用 `DelegateProcessBuilder`）。
- 論點 2.2 — **CLI shell-out 不建議作為主介面**：
  - Magi 需要 `Tool` enum、parsed session metadata、`MagiRun.save(store:)` 的持久化路徑等結構化資料。透過 `orrery delegate` CLI shell-out 會重新序列化/反序列化，錯誤處理與語意保真度都下降。
  - `orrery-sync` 選 shell-out 是因為它是「檔案同步器」，介面是檔案系統，天然適合 out-of-process；Magi 是邏輯協調器，不同場景。
- 論點 2.3 — **需要下放（extract）的穩定 API surface**：
  - `EnvironmentStore` / `EnvironmentStore.homeURL`
  - `DelegateProcessBuilder`（若要讓外部使用，要穩定其 public 介面）
  - `SessionResolver.findScopedSessions`
  - `Tool` enum
  - `L10n` — 要嘛複製一份、要嘛 Magi 自己管 L10n（獨立後比較合理由 Magi 自管）

**子議題 3：Repo 與發佈策略**

- 論點 3.1 — **短期：同 repo、新 target**（推薦）：
  - `Package.swift` 增加 `OrreryMagi` library target，依賴 `OrreryCore`；`orrery` executable 依賴兩者。
  - 零釋出變更、零 Homebrew 變更；可同時驗證「Magi 可基於 Public API 運作」的假設，當作未來拆 repo 的 dry-run。
- 論點 3.2 — **長期：獨立 repo + 獨立 Homebrew formula**：
  - 只有在子議題 1 的觸發條件成立時才動。
  - 版本策略：**解耦版號**（不像 `orrery-sync` 那樣硬綁），聲明「Magi X.Y requires Orrery ≥ A.B」即可。orrery-sync 綁版號是因為它幾乎是 orrery 的延伸；Magi 獨立後需要獨立版號。
  - Homebrew：另建 `homebrew-orrery/Formula/magi.rb`，`depends_on "orrery"`。
- 論點 3.3 — **避免**：跨 repo 但版號硬綁 — 同時承擔分 repo 的成本與合 repo 的僵硬，沒有好處。

**子議題 4：CLI/MCP/Slash 歸屬**

- 論點 4.1 — **拆分後 binary 是 `magi`，不是 `orrery magi`**：
  - 若仍叫 `orrery magi`，則 orrery 必須知道 magi 的存在並 shell-out —— 等於回到 `orrery sync` 的模型，但 Magi 比 sync 複雜太多（參數多、有 resume、有 spec flag），shell-out 轉發會變成維護負擔。
  - 改成 `magi run <topic>` / `magi resume <id>` 較清爽，並對外宣告「`orrery magi` 於 vX.Y 起已 deprecated，請改用 `magi`」。
- 論點 4.2 — **MCP server 歸屬**：
  - `orrery mcp-server` 目前註冊 `orrery_magi` tool；拆分後兩種選擇：
    - (a) magi 自己跑 MCP server（`magi mcp-server` 或 stdio plugin），orrery MCP server 移除 magi tool。
    - (b) orrery MCP server 繼續代理 magi，內部 shell-out 到 `magi run`。
  - 傾向 (a)：MCP server 本來就是按能力分 server 註冊，client 端可以同時連 orrery 與 magi。(b) 會使得 orrery 再次耦合 magi。
- 論點 4.3 — **Slash command**：
  - `orrery:magi` 應改為 `magi:run` 或直接 `magi`；由 magi 的 setup 命令寫入（例如 `magi setup`）。
  - `mcp setup` 的 Magi 區塊需從 `MCPSetupCommand.swift` 移除。

**子議題 5：遷移路徑**

- 步驟 1 — 模組化（同 repo 內）：
  - 建 `OrreryMagi` target；移動 `Sources/OrreryCore/Magi/*` → `Sources/OrreryMagi/`；`MagiCommand` 留在 orrery executable 但改 import `OrreryMagi`。
  - 盤點 `EnvironmentStore` / `DelegateProcessBuilder` / `SessionResolver` / `Tool` 的 public surface 是否足夠；不足則補 public。
  - L10n：Magi 的 keys 複製到 `OrreryMagi` 子模組或交由 Magi 自己管（這一步會決定後續拆 repo 的難度）。
- 步驟 2 — 驗證階段（停留至少一個 release）：
  - 同 repo 內跑一段時間，確認 API surface 穩定、沒有頻繁 breakage。
  - 若此時看不到獨立 repo 的具體驅動，就停在這裡 — 收益停損。
- 步驟 3 — 拆 repo（若觸發條件成立）：
  - 建 `grady/magi` repo；把 `Sources/OrreryMagi/` 搬過去，`Package.swift` 依賴 `grady/orrery`。
  - Orrery 版本 vA.B：`orrery magi` 子命令標記 deprecated，shell-out 到 `magi`（若有裝）；否則提示安裝。
  - Orrery 版本 vA.C+1：移除 `orrery magi`。
  - Homebrew：新增 `magi.rb`；使用者 `brew install magi`。
- 步驟 4 — 回退計畫：
  - 整個拆分流程應可被還原（同 repo 多 target → 合回單 target，成本低）。
  - 只要**不把 L10n 和 public API 鎖死在跨 repo 狀態下**，還原就是倒轉步驟 1。

**證據/參考**：
- `Package.swift:9` — `OrreryCore` 已是 library product，library 依賴路線可行
- `MagiOrchestrator.swift:12` — `EnvironmentStore` 為主要依賴
- `MagiAgentRunner.swift:35` — `DelegateProcessBuilder` 為 tool 執行路徑
- `CLAUDE.md` — orrery/orrery-sync 共用版本號的先例
- `MCPServer.swift:128, 247` — MCP tool 註冊位置
- `MCPSetupCommand.swift:133-155` — Magi slash command 生成

**小結（Claude）**：
- 技術上完全可行（`OrreryCore` 已是 library，介面大多 public）。
- **但目前沒有外部消費者、沒有獨立迭代需求，拆 repo 是 premature modularization**。
- 建議：先做「repo 內模組化」，把 Magi 移到獨立 Swift target、依賴 `OrreryCore` public API；這一步幾乎零風險，又能驗證邊界、為未來拆 repo 鋪路。只在出現實際驅動因素時才動 repo。

#### Codex (GPT-5.4) — 2026-04-17

**整體立場**：從務實/工程成本看，**不支持現在直接拆 repo；支持先做同 repo 模組化**，把 Magi 變成獨立 product/target，再觀察一個 release。目前 Magi 直接依賴 Orrery 的 env/session/process/L10n/spec 管線（`MagiOrchestrator.swift:37-47, 139-161, 177-182, 215-220`；`MagiAgentRunner.swift:51-58, 115-123`；`MagiCommand.swift:99-127`），直接拆 repo 新增的是版本聯動、包裝與相容層成本，短期看不到對應價值。

**子議題 1：是否值得拆分？**
1. 現在值得拆的是「模組邊界」，不是「repo 邊界」。使用者入口全部掛在 Orrery：`OrreryCommand.swift:4-37` 註冊 `MagiCommand`、`MCPServer.swift:128-161, 247-267` 暴露 `orrery_magi`、`MCPSetupCommand.swift:133-155` 寫入 `/orrery:magi`。就算今天拆 repo，Orrery 仍得保留 3 個相容入口。**估同 repo 模組化 8-14h**。
2. 直接拆 repo 初始成本比收益更明確。`CLAUDE.md:3-22` release 流程是手動單線，`orrery sync` 是另一個需同步管版本的外部 binary 先例。再多一個 Magi repo，至少多出版本相容宣告、另一個 formula、另一條發佈節奏。**估初始額外成本 16-28h**；之後每次 Orrery public API 變動再多 **1-2h/次** 相容檢查。
3. Magi 對 Orrery 的依賴是產品級能力：run 持久化 (`MagiRun.swift:133-140`)、session resume (`MagiAgentRunner.swift:51-58`)、spec 後處理 (`MagiCommand.swift:111-126`)。這些都不是拆 repo 後會消失的耦合，只會改成跨 package 耦合。**至少 5 個依賴面需明文化**：`EnvironmentStore`、`DelegateProcessBuilder`、`SessionResolver`、`Tool`、`SpecGenerator`/L10n。

**對 Claude 立場**：**agree**。ROI 不成立，拆完 Orrery 仍要承擔大部分對外整合面。

**子議題 2：反向依賴介面形式**
1. 主介面必須是 Swift library/package 依賴，不應是 CLI shell-out。`OrreryCore` 已是 library product (`Package.swift:7-11`)，Magi 直接吃結構化型別。**若走 library 路線，同 repo 只需 6-10h 就能做出邊界**；CLI boundary 則讓參數與錯誤語意變字串協議，維護成本更高。
2. **不同意 Claude 「library surface 幾乎已經 ready」的程度判斷**。`SessionResolver.findScopedSessions` 目前是 `internal static`，且回傳 `SessionsCommand.SessionEntry` (`SessionResolver.swift:4-12, 36-41`)；`MagiOrchestrator.generateReport` 也同 module 才可見 (`MagiOrchestrator.swift:365-430`)。**把 access 改 public 約 2-4h；抽乾淨 DTO 約 4-6h**。
3. 建議先在同 repo 收斂出薄 adapter surface：讓 Magi 依賴「session discovery + process launching + env store + tool identity」這組小介面，CLI/spec/MCP 留在 Orrery 側。**adapter 抽取 4-8h**。
4. CLI shell-out 最多當相容 wrapper。`SyncCommand.swift:25-50` 是 pass-through，但 `MagiCommand.swift:10-40, 99-127` 有多 flags/options 加 `--spec` 後處理，壓回 shell-out 有 CLI 協議漂移風險。

**對 Claude 立場**：**partially-agree** — 主介面走 library 正確，但「API 大多已 public」的前提被低估了清理成本。

**子議題 3：Repo 與發佈策略**
1. 短期最佳解：同 repo 多 product / 多 target。加 `OrreryMagi` target/product 最便宜，不影響現有 Homebrew 安裝與 `orrery` 指令。**估 8-14h**。
2. 直接拆獨立 repo 短期 ROI 最差。`orrery sync` 已證明外部 binary 不是零成本 (`SyncCommand.swift:30-50, 53-95`)。**初始 12-20h**，其中一部分是 release plumbing。
3. **補充新路徑：monorepo + tag 前綴**（例如 `magi-vX.Y.Z`）。若未來需要獨立發佈節奏但未達獨立團隊門檻，這比直接拆 repo 更務實，**新增規則與文件約 4-6h**。
4. 版本策略：同 repo 期間不解耦版號；真要外發再談解耦。硬解耦版號會產生 **1-2h/release** 的相容驗證固定稅。

**對 Claude 立場**：**partially-agree** — 短期同意多 target；長期比 Claude 保守，優先 monorepo + prefixed tags，不一定跳雙 repo。

**子議題 4：CLI/MCP/Slash 歸屬**
1. 現況是 Orrery 擁有全部入口：`OrreryCommand.swift:8-37` + `MCPServer.swift:128-161, 247-267` + `MCPSetupCommand.swift:133-155` + 三份 L10n 寫死 `/orrery:magi` (`en/zh-Hant/ja.json:127`)。**共 3 個入口 + 3 份文案要動**。
2. 長期 Magi 擁有新入口合理，但**中期必須雙軌**，因為 issue 約束明講「不能硬切中斷」。**雙軌遷移 6-10h**；parity 維護 **1-2h/次 CLI 變動**。
3. 不建議一開始就把 MCP/slash 完全搬走 — Magi 沒先提供自己的 setup/MCP story 前，會留下安裝與 discoverability 空窗。
4. `sync` 不能當 Magi ownership 模板。`MagiCommand` 不是簡單 pass-through，wrapper parity 要 **4-8h** 且 drift 風險較高。

**對 Claude 立場**：**partially-agree** — 長期方向一致；短期不同意把 Orrery 側 MCP/slash 很快移除。

**子議題 5：遷移路徑**
1. **Phase 0（新增）**：先做 API 收斂，不先搬 repo。清單化 Magi 依賴的宿主能力（`EnvironmentStore`、`DelegateProcessBuilder`、`Tool`、session discovery DTO）；第一個該清的邊界是 `SessionResolver.findScopedSessions` 仍 `internal` 且漏出 `SessionsCommand.SessionEntry`。**估 4-6h**。**回退點**：若發現要暴露太多 command-layer 型別，就停在 repo 內模組化。
2. Phase 1：同 repo 模組化。`Sources/OrreryCore/Magi/*` 移成獨立 target/product，`orrery` executable 保留 `MagiCommand`。**估 8-14h**。
3. Phase 2：至少觀察一個 release，刻意驗證 Magi 邊界是否頻繁受 `OrreryCore` API 變動影響。**1-2h release note**。**回退點**：若一個 release 內多次被迫改 support API，不適合拆 repo。
4. **Phase 3（新增）**：若出現外部需求，**先在同 repo 產獨立 binary**，不急著先拆 repo。驗證 CLI contract、安裝方式、wrapper 策略。**估 4-8h**。
5. Phase 4：最後才是 repo/發佈拆分。**估 10-16h** + formula/文件。**回退點**：外部安裝與版本協調負擔高於預期，就停在「同 repo 多 product + 獨立 binary」。

**對 Claude 立場**：**partially-agree** — 同意大順序；但插入「同 repo 獨立 binary」階段更便宜驗證。

**小結（Codex）**：現在不值得直接拆獨立 repo，但值得立刻做同 repo 模組化。下一步建議不是開新 repo，而是先列出 Magi 所需最小宿主 API，做一次 repo 內 dry-run。

#### Gemini — 2026-04-17

**整體立場**：**技術可行、短期不值、但 Magi 確實具備成為獨立生態元件的潛力** — 前提是用「先佈局介面、延後拆 repo」策略保留最大 optionality。與 Claude 結論方向一致（先 repo 內模組化），但從長期演進角度認為 Claude **低估了 Magi 的潛力**：Magi 本質不是 Orrery 的子功能，而是一個**跨工具 multi-agent debate orchestrator**（對應 2025–2026 的 DSPy/LangGraph/AutoGen/CrewAI 生態），但仍不是現在拆 repo 的理由 — 功能尚在快速迭代（近 48 小時才加入 roles、parallelization、spec pipeline），且 Orrery ↔ Magi 的深度耦合正是 Orrery 的差異化（session resume、shared memory、environment isolation）。

**策略建議**：「模組化優先、拆 repo 延後、介面設計時 forward-compatible with 獨立發佈」— 今天付一次成本，保留兩條未來路徑。

**子議題 1：是否值得拆分？**
1. **同意 Claude 短期結論，但反對理由**：真正短期阻礙是**功能尚未穩定**，不是「只有一個消費者」。證據：`docs/discussions/2026-04-16-magi-parallelization.md`、`2026-04-16-magi-role-differentiation.md`、`2026-04-17-magi-spec-pipeline.md` 都是過去 48 小時內展開；`MagiOrchestrator.swift:200-213` 的 verdict prompt、`MagiPromptBuilder.swift:75-86` 的 JSON contract 都是 hard-coded 待變。現在拆 repo = 在合約期冷凍介面。
2. **Magi 的長期價值被系統性低估**。`MagiRun` (`MagiRun.swift:119-141`) 已經是完整的 debate schema（participants、roles、rounds、consensus、verdict、session resume），可獨立存在。對比生態（DSPy/LangGraph/AutoGen/CrewAI）幾乎沒有以 **CLI agent 為 first-class citizen** 的工具 — Magi 的差異化是「把安裝好的 Claude Code / Codex / Gemini CLI 當 agent」，TAM 不是 Orrery 使用者而是「同時裝了多個 AI CLI 的開發者」。
3. **新增「隱藏收益」**：(a) 強制穩定 `OrreryCore` public API — Magi 作為真實外部用戶會施加契約壓力；(b) 獨立發佈節奏選項（Orrery 穩定 vs. Magi 快速）；(c) 敘事分離（「多 CLI 統一管理」vs「多 AI 辯論產出共識」）。
4. **拆分的真正風險**（Claude 沒講透）：(a) 生態 timing — multi-agent debate 尚未收斂，可能被 CrewAI v2/AutoGen 0.5 吃掉；(b) 版本矩陣爆炸；(c) 使用者心智成本（兩個 brew formula）。

**對 Claude 立場**：**partially-agree** — 短期同；反對「只以單一消費者為判準」；主張模組化時就按「未來可拆」標準設計介面。**補充觸發條件**：加「Magi API 表面連續兩個 release 未變更」作技術成熟度門檻。

**子議題 2：反向依賴介面形式**
1. **強烈同意 Swift library 路線**。
2. **新增建議：引入 `AgentExecutor` protocol 抽象層**。讓 Magi 不直接依賴 `DelegateProcessBuilder`，改依賴 protocol。好處：(a) Magi 可注入 mock executor（`MagiAgentRunner.swift:16-22` 直持 `Process` 是可測試性硬傷）；(b) 未來 Magi 獨立可定義自己的 executor（直打 API、跑 Docker container）；(c) 對 Orrery 幾乎零成本。
3. **L10n 是最大未解耦點**。`Plugins/L10nCodegenTool` 是 Orrery 專屬 build tool，跨 repo 依賴 build plugin 在 SwiftPM 是脆弱模式。**建議**：模組化階段 `OrreryMagi` target 自己管 L10n（複製生成機制）；拆 repo 時 Magi 帶走自己的 keys。
4. **反對 hybrid（部分 library 部分 shell-out）**：錯誤模式 N × M，debug 地獄。要嘛全 library，要嘛全 shell-out。

**對 Claude 立場**：**agree + extend**。

**子議題 3：Repo 與發佈策略**
1. 同意短期同 repo、新 target。**必要條件補充**：`Package.swift` 同時把 `OrreryMagi` 列為 **Package product**（`.library(name: "OrreryMagi", ...)`），即使短期沒外部依賴 — 公開宣告「可被外部依賴」、保留 optionality。成本：一行。
2. **對版號策略補 nuance**：orrery-sync 硬綁版號是**技術債**不是最佳實踐。Magi 獨立應走 **semver + compatibility matrix**（`magi 1.x` requires `orrery >= 1.3, < 2.0`；Homebrew `depends_on "orrery" => ">= 1.3.0"`）。**代價**：CI 要跑「Orrery 1.3/1.4/1.5 × Magi HEAD」矩陣。
3. **Homebrew tap 策略**：選 (a) 同 tap 多 formula（`homebrew-orrery/Formula/magi.rb`），不選獨立 tap。強化「Orrery 生態系」敘事、tap 維護 overhead 低。
4. **Swift Package Index 可見性**：拆 repo 時註冊 SPI — 近乎免費的生態 signaling。

**對 Claude 立場**：**agree + extend**（模組化時就公開 product、同 tap、接受版號矩陣 CI 成本）。

**子議題 4：CLI/MCP/Slash 歸屬**
1. **部分不同意 CLI 命名**：同意「應提供 `magi` binary」，**反對立刻 deprecate `orrery magi`**。可用**參數 pass-through**（`orrery magi` = `exec magi "$@"`）規避 Claude 擔心的維護負擔 — Orrery 只需知道「有沒有裝 magi」，不需追蹤 magi 的 flag 變化。**保留 3–6 個月後再 deprecate**。
2. **同意 MCP 選 (a) 獨立 server**，補強理由：(a) `MCPServer.swift:128-162` 把 magi 塞進 orrery MCP 違反 SRP；(b) MCP 生態方向是「多 server 組合」，Claude Code/Cursor/Continue 都支援同時連多個 server。**延伸建議**：模組化時先抽成 `MagiMCPTools.register(on:)` 掛載點。
3. **同意 slash command 遷移**，加一個**並存期**（`orrery:magi` 和 `magi:run` 同時存在）。

**對 Claude 立場**：CLI **partially-disagree**（保留過渡 wrapper）；MCP/Slash **agree + 模組化時抽掛載點**。

**子議題 5：遷移路徑與回退計畫**
1. **新增 Step 0 — API 穩定度審核**：模組化前 review `MagiOrchestrator.run`、`MagiRun` schema、`MagiRole`、`MagiAgentRunner.Result`。證據：`docs/discussions/2026-04-16-magi-role-differentiation.md:50-53` 的子議題還 open — role 機制未定案。**先做完變更、讓 API 定下來，再開始模組化**，避免半年後重做。
2. **Step 1 強化**：模組化時按「未來拆 repo」標準做 — (a) 引入 `AgentExecutor` protocol；(b) L10n 由 Magi 自管；(c) 公開 `OrreryMagi` 為 Package product。
3. **Step 2 量化驗證門檻**：至少**兩個 minor release** 期間 `MagiOrchestrator.run` signature、`MagiRun` schema 不變；且**至少一次 Orrery 側 breaking change** 觀察 Magi 是否平滑跟進。
4. **Step 3 deprecation timeline**：vA.B 拆 repo 同時，`orrery magi` 變 shell-out wrapper + stderr 印 deprecation；vA.B+3（6 個月）移除。
5. **三個不可回退風險點**：(a) Magi 累積非 Orrery 的新 external dependency — **對策**：模組化期間禁止新 dep；(b) SPI 外部使用者依賴 `magi` — **對策**：拆 repo 必伴隨 v1.0 穩定 API；(c) Homebrew 使用者 `brew install magi` — **對策**：合回去保留空殼 formula。

**對 Claude 立場**：**agree + enhance**（+ Step 0 API 審核、量化驗證門檻、6 個月 deprecation、3 個不可回退風險）。

**策略性補充**（超出五議題）：
- **Magi 獨立定位假設**：「CLI-agent-first 的 multi-agent debate orchestrator」— 零程式碼、裝了 CLI 就能跑，對比 LangGraph/AutoGen/CrewAI 的 Python-first 是真實 niche。
- **Option value 框架**：70% Magi 沒起飛 / 20% 有外部使用 / 10% 成為 niche category。**「先模組化、按未來拆分標準設計、延後 repo 決定」是 dominant strategy**，regret 最低。
- **Time window**：multi-agent debate 品類窗口在 2026 上半年。**最遲 2026 Q3 拆出**；錯過就變跟隨者。

**小結（Gemini）**：「先模組化、按『未來拆分』標準設計介面、等 API 穩定兩個 release 週期後再決定是否拆 repo；若拆，以『CLI-agent-first multi-agent debate orchestrator』為 Magi 的獨立定位，搶 2026 上半年品類窗口。」

### Round 2

#### Claude (Opus 4.6) — 2026-04-17

**整體立場**：R1 已收斂大方向，R2 應只做「**落地決策**」，不再推演拆 repo 遠景。我對 5 個 R2 待處理項目給出具體立場 + 成本估算，並提出可直接 feed 給 `/orrery:spec` 的任務骨架。

**A. Step 0 邊界清理清單**

針對 R1 已 agreed 的 D3，逐項定案：

- **A.1 `SessionResolver`**（必做）：
  - 問題：`findScopedSessions` 目前 `internal static`；回傳 `SessionsCommand.SessionEntry` — 把 command layer 的 DTO 漏給 Helpers/Magi。
  - 修法：
    - 把 `SessionsCommand.SessionEntry` 抽出為 top-level `public struct SessionEntry`（保留在 `Helpers/` 或 `Models/`）。`SessionsCommand` 繼續 `typealias SessionEntry = OrreryCore.SessionEntry` 以保 source compatibility。
    - `findScopedSessions` 改 `public static`。
    - 附帶 `resolve(_:tool:cwd:store:activeEnvironment:)` 也要確認 public（目前是）— OK。
  - 成本估：**3-5h**（含測試、L10n 無影響）。
  - 破壞面積：`SessionsCommand.SessionEntry` 的 call sites（`SessionPicker.swift`, `SessionResolver.swift`, `SessionMapping.swift` — 可用 typealias 零破壞過渡）。

- **A.2 `DelegateProcessBuilder`**（已可用，但可加強）：
  - 現況：已是 `public struct`，三個 `public enum`（`StdinMode`、`OutputMode`）和 `public init` + `public func build(...)`（`DelegateProcessBuilder.swift:4-31`）。API 表面穩定。
  - 風險：`build()` 返回 `(Process, StdinMode, Pipe?)` 這個 triple 是過度曝露實作細節。對 Magi 的實際需求來說，它要的是「丟 prompt 進去、拿 rawOutput/stderr/exitCode/sessionId 出來」— 這是 `MagiAgentRunner` 做的事。
  - **結論**：`DelegateProcessBuilder` **不動**（穩定），但在 `OrreryMagi` 或 `OrreryCore` 中**加一層 `AgentExecutor` protocol**（見 A.3）作為推薦依賴面，並提供預設實作 `ProcessAgentExecutor` 包裝 `DelegateProcessBuilder`。

- **A.3 `AgentExecutor` protocol**（Gemini 建議，我採納）：
  - 動機：(a) 測試可注入 mock；(b) 未來 Magi 若拆出，可定義自己的 executor（例如直打 API 或 Docker）；(c) 把「為 Magi 暴露 API」與「一般 delegate 流程」分離，降低 OrreryCore public surface 的搖擺風險。
  - 設計草稿（放在 `OrreryCore`）：
    ```swift
    public protocol AgentExecutor {
        func execute(
            tool: Tool,
            prompt: String,
            resumeSessionId: String?,
            timeout: TimeInterval
        ) throws -> AgentExecutionResult
    }

    public struct AgentExecutionResult {
        public let rawOutput: String
        public let stderrOutput: String
        public let exitCode: Int32
        public let timedOut: Bool
        public let sessionId: String?
        public let duration: TimeInterval
    }

    public struct ProcessAgentExecutor: AgentExecutor {
        public let environment: String?
        public let store: EnvironmentStore
        public init(environment: String?, store: EnvironmentStore)
        public func execute(...) throws -> AgentExecutionResult
        // 內部用 DelegateProcessBuilder + SessionResolver
    }
    ```
  - 成本估：**4-6h**（定義 protocol、實作 `ProcessAgentExecutor` 把 `MagiAgentRunner` 目前做的 session-id-diff 搬進來、`MagiAgentRunner` 改成依賴 protocol）。
  - 回退：若實作困難 > 8h，回退到「Magi 直接依賴 `DelegateProcessBuilder`」— 不阻塞模組化。

**B. L10n 方案**

- 選項盤點：
  - **(B1) `OrreryMagi` 共用 `OrreryCore` 的 L10n**：直接在 Magi source 裡 `import OrreryCore` 然後用 `L10n.Magi.*`。**零額外成本**，但把 Magi 的字串鎖在 OrreryCore 下 — 未來拆 repo 時要搬。
  - **(B2) `OrreryMagi` 自帶 locale JSONs + 應用 `L10nCodegen` plugin**：`Package.swift` 的 target plugin wire-up 複製到 `OrreryMagi`。短期有重複；長期是乾淨邊界。
  - **(B3) 折衷**：模組化階段用 (B1)，只在 Magi 原始字串不動的前提下；拆 repo 時才搬到 (B2)。
- **建議（Claude）**：**採 B3（折衷）**。理由：
  - `L10n.Magi.*` 目前有 ~20 個 keys（`zh-Hant.json`/`en.json`/`ja.json` 的 magi section）。短期搬動風險與收益不對稱。
  - R1 已 agreed「模組化前 API 穩定」— L10n 字串也該算 API 的一部分。字串不動前，搬家只會製造 merge conflict。
  - 成本估：**B3 = 0h**（模組化階段）；**拆 repo 時 B3→B2 = 4-6h**。
- 但我**傾向接受 Gemini 論點 2.3 的批評** — B3 等於把決策推後，Gemini 擔心「跨 repo 依賴 build plugin 是 SwiftPM 脆弱模式」。折衷：**模組化階段立即執行 (B2) 的第一步 — 只把 Magi 的 locale keys 從 `en/zh-Hant/ja.json` 挪到 `OrreryMagi/Resources/Localization/magi.en.json` 等**，但 plugin 仍由 OrreryCore 拉這些檔案（plugin 接受多個 JSON 是現有能力）。這樣拆 repo 時只要搬 plugin invocation，不用搬字串。成本：**1-2h**。

**C. 3 個 disputed 議題的收斂立場**

- **(Q1) 是否有「同 repo 獨立 binary」中間階段（Codex Phase 3）**：
  - 我 R1 未包含，**R2 接受 Codex 的建議**。理由：增加一個 `magi` executable target 在 `Package.swift` 的成本極低（~2h），且能在不拆 repo 的前提下驗證 CLI contract 與 Homebrew formula 設計。這完全符合「保留 optionality」原則。
  - **新立場**：同意 Phase 3（同 repo 產獨立 `magi` binary），但將其**標記為條件觸發**（only when 真的要驗證獨立 distribution path）。若 Magi 永遠不獨立，此階段可跳過。
- **(Q2) 獨立 repo vs monorepo + prefixed tags**：
  - Codex 的論點（monorepo + tag prefix 成本更低）技術上正確，但**我維持原立場：若真拆就走獨立 repo**。理由：
    - tag prefix monorepo 在 Swift Package 生態不是 first-class（SwiftPM `from:` 不天然支援 tag prefix，需要 `.exact()` 或自定 resolver）。
    - Gemini 提出的「semver + compatibility matrix」在獨立 repo 下才自然運作。
    - Monorepo 在別的生態（Bazel/Nx/Lerna）有工具支援；Swift 生態目前對此薄弱。
  - **但接受 deferred 標記**：在確認要拆 repo 之前不需最終定案 — 我只是主張，**若拆則獨立 repo**，不做 monorepo + prefix。
- **(Q3) `orrery magi` 去留（立即 deprecate vs 保留 pass-through）**：
  - **接受 Codex/Gemini 的方案**（保留 pass-through wrapper）。Gemini 的關鍵洞見是「`orrery magi` = `exec magi "$@"`」能消除 Claude 原先擔心的「多 flag 轉發維護負擔」— 因為 Orrery 根本不 parse flags，只做 exec。成本轉為零。
  - **新立場**：拆 repo 時，`orrery magi` 退為 3 行的 pass-through（檢測 `magi` 是否安裝 → 安裝則 exec、未安裝則 stderr 印安裝指引），6 個月後移除（Gemini 的 deprecation window）。

**D. 驗證期量化門檻（Q7）**

- Claude R1「一個 release」太模糊；Gemini R1「兩個 minor + 一次 Orrery breaking change」更可操作。
- **新立場（調整後）**：**採 Gemini 方案**，但把「一次 Orrery breaking change」放寬為 **"一次對 `AgentExecutor` protocol、`SessionEntry` DTO、`EnvironmentStore.homeURL`、或 `Tool` enum 的任何修改"**（對 Magi 有影響的 surface 才算）。
- 成本：純觀察期，無實作成本。

**E. R2 產出的實作任務清單草稿**

依 R1/R2 共識，切成以下 tickets（可直接 feed 給 `/orrery:spec`）：

| Ticket | 描述 | 估時 | 依賴 |
|--------|------|------|------|
| T1 | 抽出 `public struct SessionEntry`；`SessionsCommand.SessionEntry` 變 typealias | 2-3h | — |
| T2 | `SessionResolver.findScopedSessions` 改 `public` | 0.5h | T1 |
| T3 | 定義 `public protocol AgentExecutor` + `public struct AgentExecutionResult` + 實作 `ProcessAgentExecutor`（OrreryCore 內） | 4-6h | T1, T2 |
| T4 | `MagiAgentRunner` 改成 depend on `AgentExecutor`；OrreryCore test 注入 mock executor | 2-3h | T3 |
| T5 | 把 Magi 的 locale keys 搬到 `Resources/Localization/magi.en.json` 等分檔（B3 折衷執行）；更新 `L10nCodegen` plugin 的 input glob | 1-2h | — |
| T6 | 新增 `Sources/OrreryMagi/` target + `Package.swift` 宣告 library product；搬 `Sources/OrreryCore/Magi/*` 過去 | 3-5h | T1-T5 |
| T7 | 抽出 `MagiMCPTools.register(on:)` 掛載點；`MCPServer` 改 import 呼叫 | 1-2h | T6 |
| T8 | `MagiCommand` 改 `import OrreryMagi`；`OrreryCommand.swift` 註冊不變 | 1h | T6 |
| T9 | CI / build 驗證、CHANGELOG 更新 | 1-2h | T1-T8 |

**總估時：15-25h**（跟 R1 的 8-14h 差距，因加了 `AgentExecutor` 與 L10n 分檔）。

**對 Codex/Gemini 立場的整合**：
- 採納 Codex 的 Phase 3（條件觸發）與量化成本估算方法 → 任務表總時
- 採納 Gemini 的 `AgentExecutor` protocol → T3/T4
- 採納 Gemini 的 L10n 自管方向（以 B3→B2 過渡）→ T5
- 採納 Gemini 的量化驗證門檻 → D 節
- 採納 Codex/Gemini 的 `orrery magi` pass-through wrapper 方案 → Q3

**證據/參考**：
- `SessionResolver.swift:4-47` — 當前 API level 與 DTO 漏點
- `DelegateProcessBuilder.swift:15-31` — 當前 public surface
- `Plugins/L10nCodegenTool/main.swift:50-60` — plugin 接受多個 JSON 的能力
- `MagiAgentRunner.swift:32-36, 52-58` — 現有 Process + SessionResolver 使用模式

**小結（Claude）**：R2 接受 Codex/Gemini 多數補強意見，產出 **9 個可執行 tickets、總估 15-25h**，並在 3 個 disputed 議題上做出收斂（Q1 採納；Q2 維持立場但標 deferred；Q3 採納 pass-through wrapper）。唯一未採納的是 Codex 的 monorepo + prefixed tags（技術理由：Swift 生態支援薄弱）。

#### Codex (GPT-5.4) — 2026-04-18

**整體立場**：大致同意 Claude R2 方向（`OrreryMagi` 同 repo 模組化、加 `AgentExecutor`、保留 `orrery magi` wrapper）。**主要分歧兩點**：(i) T5 L10n 工時被明顯低估；(ii) **T7/T8 忽略了現有 SwiftPM target graph 會形成 cycle**，不能靠「改 import」落地（`Package.swift:15-41`、`OrreryCommand.swift:3-39`、`MagiCommand.swift:4-128`）。

**A. Step 0 邊界清理**
- A.1 接受。DTO 本身沒明顯 UI-only 欄位（僅 `id/firstMessage/lastTime/userCount`，`SessionsCommand.swift:67-72`）；真正的洩漏是被巢狀在 command type + parser 有 `"(empty)"` 這種 presentation-ish fallback（`SessionsCommand.swift:123,170,238`）。**僅 top-level DTO + typealias + `findScopedSessions` public：2-3h；含 fallback 語義化 + 測試：3-5h。**
- A.2 接受 `DelegateProcessBuilder` 先不動，但**只接受它作 low-level helper，不接受它成為 Magi 建議依賴面**。`build()` triple（`DelegateProcessBuilder.swift:31-32,141`）導致兩個 Magi call site 都各自 override stderr、drain、timeout（`MagiAgentRunner.swift:36-49,62-109`；`MagiOrchestrator.swift:216-247`）— 這正是應該被 `AgentExecutor` 吃掉的細節。
- A.3 接受但草案仍缺：
  - `cancellation` 不能消失（`MagiAgentRunner.terminate()` 於 `MagiAgentRunner.swift:136-138`）
  - `stderr draining` **必須**是 executor 責任（`MagiAgentRunner.swift:77-80`、`MagiOrchestrator.swift:236-247`）
  - `streaming` 現在可 defer（`MagiOrchestrator.swift:249-258` 只吃 final output）
  - `Tool` 綁死 protocol 參數短期可接受，但加 case 會影響 `Tool.allCases` 與 switch exhaustiveness（`Tool.swift:3-65`）
  - **`sessionId` 保留一級欄位**，Magi 明確持久化 + 續跑用它（`MagiOrchestrator.swift:33-48,124-127`），不需泛化成 metadata dict

**B. L10n 策略** ⚠️ **關鍵發現**
- 現有 plugin/tool **不能不改就吃多 target JSON**。`L10nCodegenTool` signatures 路徑寫死 `Sources/OrreryCore/Resources/Localization/l10n-signatures.json`（`Plugins/L10nCodegenTool/main.swift:59-62`）；build plugin 只對 `target.name == "OrreryCore"` 生效（`Plugins/L10nCodegen/plugin.swift:7-15`）。
- Claude 引的「plugin 接受多 JSON」只代表「多 locale 檔」，**不是「多 shard / 多 target」**。tool 會把檔名 stem 當 locale code（`main.swift:63-70`），`magi.en.json` 會變成名為 `magi.en` 的 locale；且 tool 拿第一個檔當 base、要求其他 key set 完全一致（`main.swift:73-83,109-132`），**`en.json` 和 `magi.en.json` 並存會驗證失敗**。`AppLocale` 也只認 `en/zhHant/ja`（`AppLocale.swift:3-27`）。
- **T5 的 1-2h 不實在**。真要分檔需改 plugin 成「同 locale 多 shard merge」或「接受多 signatures / 多 locale dir」，**實際 4-6h** + 要補 localization tests（`Tests/OrreryTests/LocalizationTests.swift:27-53`）。
- **Codex 建議**：Phase 1 採 **B1（`OrreryMagi` 繼續吃 `OrreryCore.L10n.Magi`）**，不把 L10n 變成模組化 blocker；另開 follow-up ticket 重構 codegen 為 shard-aware，之後再搬字串。比 Claude 折衷版務實。

**C. 分歧議題**
- **Q1**：「條件觸發」不夠，應明文寫 trigger。建議「只有當要驗證獨立 distribution / Homebrew formula / `orrery magi` pass-through 行為時，才加同 repo `magi` binary」（目前僅單一 executable `orrery`：`Package.swift:7-18`、`Sources/orrery/main.swift:1-4`）。
- **Q2**：接受 Claude 拒絕 monorepo + prefixed tags。目前 repo 無 release tooling 支撐這條路（`Package.swift:4-47`），SwiftPM 確實不是 first-class。無足夠反駁。
- **Q3**：agreed。

**D. 驗證門檻**
- Claude surface 大致正確，但**`Tool` 的加 case 也該算 breaking** — `Tool.allCases` 驅動 Magi 預設參與者（`MagiCommand.swift:50-54`）、影響 env 清理（`DelegateProcessBuilder.swift:107-112`），不是 harmless additive。
- `EnvironmentStore.homeURL` 必須監控（Magi run 路徑直接拼接：`MagiOrchestrator.swift:37-39,177-179`）。
- **`DelegateProcessBuilder` 應列為「間接實作依賴」監控項**。即使 Magi 名義上只依賴 `AgentExecutor`，實際 process/env/session 行為仍透過 builder 落地（`MagiAgentRunner.swift:32-36`、`MagiOrchestrator.swift:216-220`）。

**E. Ticket 審查** ⚠️ **關鍵發現：package graph cycle**
- T1：2-3h 合理；3-5h 需連 parser fallback 一起處理。
- T2：0.5h 合理（T1 完成後）。
- T3：4-6h 勉強合理，但 `ProcessAgentExecutor` **必須吃掉 session-diff + timeout + stdout/stderr drain**，否則只是換名字（`MagiAgentRunner.swift:52-58,83-109,115-123`）。
- T4：**範圍漏了 `generateSummarizedVerdict`**。該處也直接 new `DelegateProcessBuilder`（`MagiOrchestrator.swift:193-259`），不一起改走 executor = 抽象層半套。**2-3h 偏低，實際 3-4h**。
- T5：**1-2h 不實在**（見 B）。
- T6：同意 `OrreryMagi` 公開為 product（R1 option value），但 **3-5h 偏低**，因 command/MCP 組裝點現都在 `OrreryCore`，不是單純搬 `Sources/OrreryCore/Magi/*`（`OrreryCommand.swift:8-37`、`MCPServerCommand.swift:3-14`、`MCPServer.swift:40-47,247-267`）。
- **T7：1-2h 偏低，且目前設計不成立**。`MCPServer` 在 `OrreryCore`，若它 `import OrreryMagi` → `OrreryMagi → OrreryCore` 形成 **cycle**（`Package.swift:21-32`、`MCPServer.swift:4-59`）。
- **T8：1h 不成立**。`MagiCommand` 目前在 `OrreryCore`，`OrreryCommand` 也在 `OrreryCore` 註冊它；若 `OrreryMagi → OrreryCore`，**這裡不能反向 import**。**組裝點必須搬到 executable 或新 integration target**。此外 `generateReport` 也不是 public（`MagiOrchestrator.swift:365-448`）。
- T9：1-2h 只夠 build/changelog；加 executor regression 測試應抓 2-3h。
- **漏掉的 ticket**：「command/MCP composition 上移」是必要的。`MCPSetupCommand.swift:133-155` 可不改（Phase 1 仍用 `orrery_magi` / `/orrery:magi`）。

**修訂後的任務清單（Codex）** — 共 R1–R8，**總估 18-27h**：

| Ticket | 描述 | 估時(h) | 依賴 |
|--------|------|--------:|------|
| **R1** | 抽出 top-level `SessionEntry` + typealias + `findScopedSessions` public | 2.5-3.5 | — |
| **R2** | `AgentExecutor`/`AgentExecutionResult`/`ProcessAgentExecutor`；把 timeout/stderr drain/session diff 收進 executor | 5-7 | R1 |
| **R3** | 全部 Magi call site 改走 executor（含 `generateSummarizedVerdict`） | 3-4 | R2 |
| **R4** | **Package graph 重構**：新 `OrreryMagi` library product、搬 `Magi/*`、**command 組裝點移到 executable/integration layer**（避免 cycle）| 4-6 | R1-R3 |
| **R5** | MCP 組裝重構：抽 `MagiMCPTools`，註冊點放在 Core/Magi 之上 | 2-3 | R4 |
| **R6** | `MagiCommand --spec` 路徑收斂（公開 `generateReport` 或由 Magi 提供 facade）| 1-2 | R4 |
| **R7** | **L10n 暫不分檔；記錄 follow-up infra ticket** | 0.5-1 | — |
| **R8** | 驗證與文件：build / executor regression / CHANGELOG | 2-3 | R1-R7 |

**小結（Codex）**：落地順序應是「先收斂 `SessionEntry` 與 `AgentExecutor` → 再處理 package graph → 最後碰 MCP 組裝」。**L10n 不該進這輪 critical path**，否則會在 plugin infra 燒掉不成比例時間。依此修正版，總工時約 **18-27h**，風險更集中、結構真的拆得開。

#### Gemini — 2026-04-18

**整體立場**：Claude R2 大致保留 R1 主張的 option value，**conditional accept**。9 個 ticket 的 surface 相容於「70/20/10」三條未來路徑。但有**三個 optionality 漏洞**必須 R2 補：
1. **`AgentExecutor` protocol 表面太窄** — 只支援「一次性拿完整輸出」，沒支援 cancellation/streaming/nested sub-agent，等於把 Magi 未來擴張到「直打 API / Docker / long-running agent」的路徑預先關閉。
2. **L10n hybrid 把 `L10nCodegenTool` 的 package-root 假設帶進 `OrreryMagi`**（plugin 硬編碼 `Sources/OrreryCore/Resources/Localization/l10n-signatures.json`，`main.swift:61`）— 這正是 R1 擔心的 SwiftPM build-plugin 脆弱模式，**半拆反而鎖死了全拆路徑**。
3. **缺少 `OrreryCore → OrreryMagi` 的 public API 契約文件** — 沒有契約，Claude D 節的驗證門檻沒有單一可追蹤來源。

**A. Step 0 邊界清理**
- **A.1 agree**。補充：field audit（確認無 presentation 欄位）；新增 `Codable` conformance（Magi run 已把 session id 寫進 `MagiRun` JSON，`MagiAgentRunner.swift:123`，未來外部消費者會需要）。+0.5h。
- **A.2 agree**。提醒：`build()` triple 是「誰 own I/O」的模糊邊界（`MagiAgentRunner.swift:42-48` 立刻 override stderr、重配 stdout）。應在 `ProcessAgentExecutor` 內**完全封裝 triple**，讓它不出現在 `OrreryMagi` import surface。
- **A.3 partially-agree**（方向 yes、草案不足）：
  - Claude 草案過於保守 — 1:1 搬 `MagiAgentRunner` shape 為 protocol，解決 mock 但沒解決「Magi 自定 executor」路徑。
  - **缺 cancellation**：R1 20% 外用場景幾乎必需。
  - **缺 streaming / progress events**：`MagiOrchestrator.generateSummarizedVerdict`（`MagiOrchestrator.swift:193-259`）目前只能「running...」→ 一次跳完整段；Web UI / 長時程必需。protocol 不需立即實作 streaming，但應設計**不排斥 streaming 的 shape**。
  - **`tool: Tool` 洩漏 Orrery 概念**（closed enum 只涵蓋 claude/codex/gemini）。未來 Magi 支援任意 CLI agent / API agent 就不對。**現在改 `agentIdentifier: String` = +1h；拆 repo 時改 = +4-6h**。
  - **`AgentExecutionResult.sessionId` 強 coupling**：建議改 `metadata: [String: String]`，拆 repo 時 Magi 擴充自有 metadata（cost/tokens/model version）不需改 protocol。
  - **修訂後 protocol**：
    ```swift
    public protocol AgentExecutor {
        func execute(request: AgentExecutionRequest) async throws -> AgentExecutionResult
        func events(for request: AgentExecutionRequest) -> AsyncThrowingStream<AgentEvent, Error>
    }
    public struct AgentExecutionRequest {
        public let agentIdentifier: String     // 不綁 Tool
        public let prompt: String
        public let resumeSessionId: String?
        public let timeout: TimeInterval
        public let metadata: [String: String]
    }
    public struct AgentExecutionResult {
        public let rawOutput: String; public let stderrOutput: String
        public let exitCode: Int32; public let timedOut: Bool; public let duration: TimeInterval
        public let metadata: [String: String]  // sessionId 放這裡
    }
    ```
  - 成本增量 +2-3h（T3 變 6-9h）。10% niche 場景擴充點全開啟；70% 不拆情境也不累贅。
  - **最小讓步**：至少抽象掉 `tool: Tool`，其他可延後。這是拆 repo 成本的最大決定因子。

**B. L10n 策略** — conditional-agree，但實作有陷阱
- Claude B3→B2 方向對，**實作細節有問題**：
  - `Plugins/L10nCodegenTool/main.swift:61` 硬編碼 signatures 絕對相對路徑。分檔到 `Sources/OrreryMagi/Resources/Localization/magi.en.json` 時，**SwiftPM build plugin 的 input file 必須在該 target 的 sources/resources 下**；`OrreryCore` 的 plugin 無法天然讀取 `OrreryMagi` resources 而不 hack。
- **建議 B3.5**：
  - T5 同時分 **signatures 檔案**：`magi-signatures.json` + `magi.en.json` 等
  - `L10nCodegenTool` 接受「多 signatures」參數：`--signatures <file>...`
  - `OrreryMagi` target 宣告**自己的 plugin invocation**（複用同一個 executable）
- **成本**：Claude 估 1-2h，**修訂為 3-5h**（plugin 多 signatures +1-2h、Magi target plugin wiring +1-2h、locale 搬遷 +1h）。
- **戰略意義**：+2-3h 是把「B3 鎖回」升級為「B3 實作、B2 就緒」；不做則 R1 擔心的「半解耦亂局」成真。

**C. 分歧議題**
- **Q1 Phase 3**：agree 條件觸發，**補觸發條件明文化**：
  - (a) 至少一個具體第三方 SwiftPM consumer 明確表示要直接 import `OrreryMagi`；或
  - (b) Orrery 社群 ≥3 獨立來源「想用 Magi 但不想裝 Orrery」的 Issue/Discussion；或
  - (c) 2026-06-30 前，Magi API（`MagiOrchestrator.run`、`MagiRun` schema）連兩個 minor release 無 breaking change
  - (c) 是時間觸發，呼應 R1 的 2026 Q3 窗口。沒 (a/b/c) 其一達成則 Phase 3 跳過無成本。
- **Q2**：agree Claude 結論；但標記 `deferred` 而非 closed — 若 Swift 5.11+ / SwiftPM 加入原生 workspace / sub-package 語意，決策可重開。
- **Q3**：agreed。

**D. 驗證門檻**
- Surface 大致正確，但：
  - `Tool` enum **維度偏高** — Orrery 演進加新 Tool（.aider、.opencode）是加法，對 Magi 不破壞。**建議改為「`Tool` enum 移除或 rename 才算 breaking」**，加法不計入。
  - **缺 `DelegateProcessBuilder`**：即使 Magi 改走 `AgentExecutor`，`ProcessAgentExecutor` 內部仍依賴它，間接變 Magi 傳遞依賴（R1 Q9 點出過）。建議納入監控、標「間接 surface」。
  - **新增建議：引入 CONTRACT.md** — 有單一文件，「什麼算 breaking」就有客觀判定。

**E. Ticket 審查 — 戰略性 lock-in 風險檢查**
- T1/T2/T4/T6（加 product 宣告）/T7/T8/T9：無 lock-in 風險，對等支援 stop/continue。
- **T3 有風險**（若採 Claude 窄草案）：拆 repo 時加欄位 = breaking。
- **T5 有風險**（若 plugin wiring 不補齊）：拆 repo 時 L10n 變 blocker。
- **缺漏 ticket**：
  - **T10（新增）**：`docs/CONTRACT-OrreryMagi.md` — 明列 `OrreryCore` 對 `OrreryMagi` 的 public surface（SessionEntry / SessionResolver / AgentExecutor & ProcessAgentExecutor / EnvironmentStore.homeURL / Tool / L10nCodegenTool plugin input contract）。Orrery PR review checklist。**+1-2h**。是把 D 節門檻「抽象 → 可執行流程」的必要配件。
  - **T11（新增、可選）**：`MagiOrchestrator` 內部事件/時序 log — 幫助 parallelization/role differentiation debug；未來 streaming / external observability 起點。+2-3h，非阻塞。
- **T4 範圍擴大**：不只 `MagiAgentRunner`，**`MagiOrchestrator.generateSummarizedVerdict`（`MagiOrchestrator.swift:193-259`）所有直呼 `DelegateProcessBuilder` 也要改走 `AgentExecutor`**。否則「Magi 只依賴 protocol」是半真半假。**+1-2h**。
- **T6 必須明文**：宣告 `.library(name: "OrreryMagi", targets: ["OrreryMagi"])` 為 Package product（一行成本）。

**策略性補充**
1. **三條路徑覆蓋**：70% 不拆 OK；20% 外用靠 library product 宣告；10% 獨立 niche 靠**寬版 protocol + 修訂 L10n + CONTRACT.md** 共同覆蓋。若 T3/T5 採 Claude 原版，10% 路徑**成本會從 10-16h 膨脹到 20-30h**。
2. **option value 價格**：Claude 估 15-25h；Gemini 修訂 +2-3h (T3) + 2-3h (T5) + 1-2h (T10) = **+5-8h，總 20-33h**。**若有任何拆的可能（>20% 情境），此成本 ROI 為正**。
3. **時程錨點**：修訂範圍 + Orrery 每 1-2 週 minor release 節奏，**驗證期自然落在 5-6 月，Phase 3 Go/No-Go 落在 2026 Q3 初（7 月）** — 對上 R1 品類窗口。建議 T9 CHANGELOG / T10 CONTRACT.md 明記 **2026-07-01 Go/No-Go review date** 作為自然節奏錨點。

**修訂後的任務清單（Gemini）**：

| Ticket | Claude 原版 | Gemini 修訂 | 理由 |
|--------|-------------|-------------|------|
| T1 | 2-3h | 2.5-3.5h | +`Codable`；先做 field audit |
| T3 | 4-6h | **6-9h** | 寬版 protocol：`AgentExecutionRequest/Result` 用 metadata dict；`agentIdentifier: String` 取代 `Tool`；加 `cancel()`；預留 streaming shape |
| T4 | 2-3h | **3-5h** | 範圍擴到 `generateSummarizedVerdict` |
| T5 | 1-2h | **3-5h** | `L10nCodegenTool` 接受多 signatures；`OrreryMagi` 獨立 plugin wiring；分檔含 signatures |
| T6 | 3-5h | 3-5h（無增） | 明文包含「宣告 `.library(name: "OrreryMagi", ...)` public product」 |
| **T10（新）** | — | **1-2h** | `CONTRACT-OrreryMagi.md` |
| **T11（新、可選）** | — | 2-3h | `MagiOrchestrator` 事件/時序 log；可留 follow-up |

**總估：20-33h**（含 T11 則 22-36h）。

**非 ticket 動作**：
- Phase 3 觸發條件明文寫進討論（見 C.Q1）
- Q2 標 `deferred`，重開條件：SwiftPM workspace/subpackage 原生支援
- **2026-07-01 Go/No-Go review 日期**寫進 CHANGELOG / CONTRACT.md

**小結（Gemini）**：整體支持 Claude R2 落地骨架。關鍵修訂三處，皆是「今天多付 5-8h 換取兩條未來路都不鎖死」的 option value 投資：(1) T3 寬版 protocol；(2) T5 L10n plugin 正確分檔；(3) T10 CONTRACT-OrreryMagi.md。時程上 20-33h + Orrery release 節奏讓 Phase 3 Go/No-Go 自然落在 2026 Q2 末 / Q3 初，對齊品類窗口。

---

## 共識看板

| # | 子議題 | Claude | Codex | Gemini | 狀態 |
|---|--------|--------|-------|--------|------|
| 1 | 是否值得拆分（短期） | 不直接拆；先 repo 內模組化 | 同 | 同 | **agreed** |
| 2 | 依賴介面：library vs shell-out | Library 優先 | 同 | 同 | **agreed** |
| 2b | `AgentExecutor` protocol | 窄版（R2 採納） | 窄版 + executor 必須吃 session diff/stderr drain/timeout | 寬版（metadata dict/agentIdentifier/cancellation/streaming shape） | **agreed 方向；width 見 D8** |
| 2c | L10n 歸屬（Phase 1） | B3 折衷分檔 1-2h | **B1 先共用、L10n 不進 critical path** | B3.5 分檔 + plugin 改造 3-5h | **agreed Codex 方案**（Claude R2 估時不實 — plugin 硬編碼 OrreryCore） |
| 2d | `SessionEntry` DTO 抽出 + `findScopedSessions` public | 3-5h | 2-3h（或含 fallback 3-5h）| + `Codable` conformance | **agreed** |
| 2e | `DelegateProcessBuilder` | 不動、列為穩定依賴面 | 不動、但**只做 low-level**、不當建議依賴面 | 不動、但 triple 由 executor 封裝掉 | **agreed**（不動 + executor 封裝實作細節） |
| 3 | 短期 repo 策略 | 同 repo 多 target + 公開 `OrreryMagi` product | 同 | 同 | **agreed** |
| 3b | 長期 repo 策略 | 獨立 repo | 接受獨立 repo；monorepo 論點撤 | 同意獨立 repo，標 deferred 可重開 | **agreed**（若拆則獨立 repo；deferred 直到觸發） |
| 3c | Homebrew tap | 新 formula | — | 同 tap 多 formula | **agreed**（同 tap） |
| 4 | CLI 命名 / `orrery magi` | R2 改採 pass-through wrapper | pass-through | pass-through = `exec magi "$@"`，3-6 月後 deprecate | **agreed** |
| 4b | MCP server 歸屬 | Magi 自跑 | 同 + 組裝點需上移避免 cycle | 同 + SRP | **agreed** |
| 4c | Slash command 歸屬 | 由 magi setup 寫入 | 同（Phase 1 先不動 `MCPSetupCommand.swift:133-155`）| 並存期 | **agreed** |
| 5 | 遷移骨架 | 4 步 → R2 改為 9 tickets | **8 tickets 修訂版 (R1-R8)**，發現 package graph cycle | 9 tickets + T10/T11 | **agreed 骨架；見 E 節最終任務清單** |
| 5b | 驗證門檻 | 採 Gemini 量化門檻 | 同 + **`DelegateProcessBuilder` 列間接監控**、`Tool` 加 case 也算 breaking | 量化 + `Tool` 加法不算 + `DelegateProcessBuilder` 間接監控 + CONTRACT.md | **agreed**（最終版見 D5）|
| 5c | Phase 3（同 repo 獨立 binary） | 條件觸發 | 明文觸發條件 | 明文三條觸發條件 (a/b/c) | **agreed**（採 Gemini 三條觸發條件）|
| **R2 新發現** | Package graph cycle | 未發現 | **發現：`OrreryCommand`/`MagiCommand`/`MCPServer` 都在 `OrreryCore`，若 `OrreryMagi → OrreryCore` 則組裝點必須上移到 executable/integration layer** | 未明確發現 | **agreed**（採 Codex 重構方案） |
| **R2 新發現** | `generateSummarizedVerdict` 也用 `DelegateProcessBuilder` | 未發現 | 發現（T4 範圍應擴） | 發現（T4 範圍應擴）| **agreed** |

**狀態說明**：
- `agreed` — 三方達成共識
- `majority` — 兩方同意，一方保留意見
- `disputed` — 有根本分歧
- `pending` — 尚未充分討論
- `deferred` — 延後到後續議題

---

## 決策紀錄

| # | 決定 | 達成日期 | 依據 Round | 備註 |
|---|------|---------|-----------|------|
| D1 | **短期不直接拆 repo**；立即啟動「repo 內模組化」：新增 `OrreryMagi` Swift target 依賴 `OrreryCore` | 2026-04-17 | R1 | 三方一致（Claude/Codex/Gemini）。估 8-14h 工作量。 |
| D2 | 反向依賴形式：**Swift library**，拒絕 CLI shell-out 作為主介面，也拒絕 hybrid | 2026-04-17 | R1 | 三方一致。`OrreryCore` 已是 library product。 |
| D3 | 模組化**前**必須先清理 `SessionResolver.findScopedSessions` 的 access level 與 DTO（目前 `internal` 且回傳 `SessionsCommand.SessionEntry`） | 2026-04-17 | R1 | 三方一致。Codex/Gemini 均明確點出；估 2-6h。 |
| D4 | MCP server 長期歸屬：**Magi 自跑獨立 MCP server**；模組化階段先抽出註冊掛載點（例如 `MagiMCPTools.register(on:)`），不立即搬走 | 2026-04-17 | R1 | 三方一致。符合 MCP 生態「多 server 組合」慣例。 |
| D5 | Slash command 長期歸屬：由 Magi 自管；遷移期採**並存期**（`orrery:magi` 與 `magi:run/magi` 同時存在） | 2026-04-17 | R1 | 三方一致。 |
| D6 | 遷移路徑包含「**Step 0：API 穩定度審核 / 邊界清理**」作為模組化的前置條件 | 2026-04-17 | R1 | 三方一致。採用 Codex「Phase 0」+ Gemini「Step 0 API 審核」合併命名。 |
| D7 | **`MagiOrchestrator.generateSummarizedVerdict`**（`MagiOrchestrator.swift:193-259`）也要改走 `AgentExecutor`，不只 `MagiAgentRunner` | 2026-04-18 | R2 | Codex/Gemini 同時發現 Claude R2 T4 漏此 call site；否則抽象層半套。 |
| D8 | **Package graph 必須重構**：`OrreryCommand` / `MagiCommand` / `MCPServer` 現都在 `OrreryCore`，若 `OrreryMagi → OrreryCore` 則**組裝點必須上移到 `orrery` executable target 或新 integration target**，避免 module cycle | 2026-04-18 | R2 | Codex R2 發現；Claude R2 T7/T8 原設計不可行（cycle）。 |
| D9 | **L10n Phase 1 採 B1**（`OrreryMagi` 共用 `OrreryCore.L10n.Magi`），不進本輪 critical path；`L10nCodegenTool` shard-aware 重構另開 follow-up | 2026-04-18 | R2 | Codex 技術證據：`main.swift:59-62,73-83,109-132` 硬編碼 OrreryCore 路徑 + 要求 locale key set 完全一致，分檔立刻驗證失敗。Claude R2 的 1-2h 不實，Gemini B3.5 實為 3-5h。採 Codex 務實路線。 |
| D10 | 模組化時**立即宣告 `OrreryMagi` 為 Package library product**（一行成本；保留 option value） | 2026-04-18 | R1+R2 | Gemini R1 + Codex R2 + Claude R2 T6 皆同意。 |
| D11 | **新增 `docs/CONTRACT-OrreryMagi.md`**：明列 `OrreryMagi → OrreryCore` 的 public API 契約（SessionEntry / SessionResolver / AgentExecutor & ProcessAgentExecutor / EnvironmentStore.homeURL / Tool / DelegateProcessBuilder 間接監控）。作為 D5 驗證門檻的單一真實來源 | 2026-04-18 | R2 | Gemini 提出；Claude/Codex 同意有助於把抽象門檻變成可執行 review checklist。 |
| D12 | **`AgentExecutor` protocol 採「中間版」**：`execute(request:) -> Result` + **cancellation** + stderr drain 為 executor 責任 + 保留 `sessionId: String?` 一級欄位；**`Tool` 參數維持現狀**（短期不抽成 `agentIdentifier: String`）；**streaming 延後**但 Result 欄位設計不排斥未來擴充（`metadata: [String: String]` 作為可選 forward-compat 欄位）| 2026-04-18 | R2 | 綜合三方：Claude 窄版 + Codex 要求 drain/cancel 必須吃進 executor + Gemini 的 forward-compat 欄位。`Tool` 不抽象：Codex 主張 sessionId 一級（Magi 確實持久化），Tool enum 作為 Orrery 內部概念可接受。 |
| D13 | **Phase 3（同 repo 獨立 `magi` binary）明文觸發條件**（Gemini 版本，任一滿足即執行）：(a) 至少一個具體第三方 SwiftPM consumer 要直接 import `OrreryMagi`；(b) Orrery 社群 ≥3 獨立來源的「想用 Magi 但不想裝 Orrery」Issue/Discussion；(c) 2026-06-30 前 Magi API 連兩個 minor release 無 breaking change | 2026-04-18 | R2 | Codex/Gemini 皆要求明文。 |
| D14 | **驗證門檻 surface 最終版**：`AgentExecutor` protocol、`SessionEntry` DTO、`EnvironmentStore.homeURL`、`Tool` enum（僅**移除或 rename** 算 breaking；加 case 不算）、`DelegateProcessBuilder` 作為**間接監控項**（標註 indirect surface）| 2026-04-18 | R2 | 綜合 Gemini「Tool 加法不算」+ Codex「DelegateProcessBuilder 間接監控」+ `Tool` 加 case 爭議以「加法不算」收斂（與 Gemini R2 一致）。 |
| D15 | **2026-07-01 設為 Go/No-Go review 錨點日**：屆時 Magi API 穩定度、Phase 3 觸發條件達成度、2026 Q3 品類窗口影響等做一次決策 review。寫入 CHANGELOG / CONTRACT-OrreryMagi.md | 2026-04-18 | R2 | Gemini 提出；Codex/Claude 未反對。 |
| D16 | **任務順序調整：Spec MVP 優先、Magi extraction 延後**。原 D6/D8 的模組化步驟骨架（Step 0 → Modularization → Validation → Phase 3）順序維持不變，但**整體 Magi extraction 延後至 Orrery Spec MCP tool MVP（`docs/tasks/2026-04-18-orrery-spec-mcp-tool.md`）完成之後**才啟動。期間若 Spec MVP 對 `OrreryCore` 既有 public API（`SessionEntry` / `EnvironmentStore.homeURL` / `Tool`）有新需求，依 D14 驗證門檻處理 | 2026-04-19 | 使用者指示 | 使用者 2026-04-19 明確要求「先把實作 spec 的 CLI 完成，之後再去把 magi 跟 orrery 拆分」。詳見 `docs/discussions/2026-04-18-orrery-spec-mcp-tool.md` D17。 |

---

## 開放問題

**R1 後仍開放、R2 結果**（✅=R2 已解；🔄=deferred）：

- ✅ **(Q1)** Phase 3 同 repo 獨立 binary — R2 agreed 為條件觸發 + 三條明文觸發條件（D13）
- 🔄 **(Q2)** 獨立 repo vs monorepo prefixed tags — Codex R2 撤回 monorepo；採獨立 repo，但標 `deferred` 直到拆 repo 觸發時最終定案
- ✅ **(Q3)** `orrery magi` 去留 — R2 agreed 採 pass-through wrapper + 6 個月 deprecation window
- ✅ **(Q4)** `AgentExecutor` protocol — R2 agreed 採「中間版」（D12）
- ✅ **(Q5)** L10n 處理 — R2 agreed Phase 1 採 B1 共用（D9），shard-aware 另開 follow-up
- ✅ **(Q6)** 拆分量化觸發門檻 — D13 三條觸發條件覆蓋
- ✅ **(Q7)** 驗證期長度 — D14 + D15（2026-07-01 Go/No-Go 錨點）
- 🔄 **(Q8)** 2026 Q3 品類窗口 — 接受作為**軟性** timing signal；不改變 D1-D15；2026-07-01 review 若判斷窗口已關閉，Phase 3 可跳過
- ✅ **(Q9)** `DelegateProcessBuilder` 穩定性 — D14 列為「間接監控 surface」

**R2 後新開放問題**（留給實作階段或 follow-up）：

- **(Q10)** `L10nCodegenTool` shard-aware 重構何時啟動？（驗證期 / Phase 3 / Phase 4）
- **(Q11)** `AgentExecutor.Result` 的 `metadata: [String: String]` forward-compat 欄位在 Phase 1 要不要先加？（over-engineering 風險 vs 未來重構成本）
- **(Q12)** D8 組裝點上移放 `orrery` executable target 還是新建 integration target（例如 `OrreryCLI`）？— 實作時決定；若 executable 變太胖再抽 integration target

---

## 最終合併任務清單（R2 結論）

綜合 Claude R2（9 tickets / 15-25h）、Codex R2（8 tickets / 18-27h，發現 package graph cycle）、Gemini R2（9+2 tickets / 20-33h，寬版 protocol + CONTRACT.md）後的**合併最終版**，採用 Codex 的修訂編號 + Gemini 的 T10（契約文件）：

| Ticket | 描述 | 估時(h) | 依賴 | 關鍵來源 |
|--------|------|--------:|------|---------|
| **T1** | 抽出 top-level `public struct SessionEntry`；`SessionsCommand.SessionEntry` 保留 typealias；`findScopedSessions` 改 `public static`；可選：`Codable` conformance（Gemini）| 2.5-3.5 | — | D3 / Codex R1+R2 / Gemini A.1 |
| **T2** | 新增 `public protocol AgentExecutor` + `AgentExecutionRequest` + `AgentExecutionResult` + `ProcessAgentExecutor`（OrreryCore 內）。**Executor 必須吃掉 timeout / stderr drain / session-id diff / cancellation**；`sessionId` 保留一級欄位；`Tool` 維持現狀；保留 `metadata: [String: String]` forward-compat 欄位（見 Q11） | 5-7 | T1 | D12 / Codex R2 / Gemini A.3 |
| **T3** | 把 Magi 所有 call site 改走 `AgentExecutor`：`MagiAgentRunner` + **`MagiOrchestrator.generateSummarizedVerdict`**（`MagiOrchestrator.swift:193-259`） | 3-4 | T2 | D7 / Codex R2 E / Gemini 策略性補充 3 |
| **T4** | **Package graph 重構**：新增 `Sources/OrreryMagi/` target + `Package.swift` 宣告 `.library(name: "OrreryMagi", targets: ["OrreryMagi"])` **public product**；搬 `Sources/OrreryCore/Magi/*` 過去；**把 `MagiCommand` 與 MCP tool 組裝點上移到 `orrery` executable（或新 integration target）**，避免 `OrreryCore ↔ OrreryMagi` cycle | 4-6 | T1-T3 | D8 / D10 / Codex R2 R4 |
| **T5** | MCP 組裝重構：抽 `MagiMCPTools`，**註冊掛載點放在 executable / integration layer**（高於 Core 與 Magi） | 2-3 | T4 | D4 / Codex R2 R5 / Gemini 延伸建議 |
| **T6** | `MagiCommand --spec` 路徑收斂：把 `MagiOrchestrator.generateReport` 改 `public`（或 Magi 側提供 facade） | 1-2 | T4 | Codex R2 R6 |
| **T7** | **L10n 暫不分檔**：`OrreryMagi` 繼續共用 `OrreryCore.L10n.Magi`；另開 follow-up ticket `T7-FUTURE` 重構 `L10nCodegenTool` 為 shard-aware | 0.5-1 | — | D9 / Codex R2 R7 / Q10 |
| **T8** | **新增 `docs/CONTRACT-OrreryMagi.md`**：明列 `OrreryMagi → OrreryCore` public surface（`SessionEntry` / `SessionResolver.findScopedSessions` / `AgentExecutor` & `ProcessAgentExecutor` / `EnvironmentStore.homeURL` / `Tool` enum / `DelegateProcessBuilder` 作為間接監控項）；寫入 **2026-07-01 Go/No-Go review 日期** | 1-2 | T1-T4 | D11 / D15 / Gemini T10 |
| **T9** | 驗證與文件：build / executor regression tests / CHANGELOG / README 同步 | 2-3 | T1-T8 | Codex R2 R8 |

**總估：21.5-31.5h**（落在 Codex 18-27h 與 Gemini 20-33h 之間，接近後者上緣）。

---

## 下次討論指引

### 進度摘要

**Round 2 完成，討論達到共識（status: consensus）**。三方在 R1 已 agreed 短期不拆 repo、先 repo 內模組化後，R2 收斂至 15 項決策（D1-D15）與 9 個可執行任務（T1-T9，21.5-31.5h）。

**R2 的關鍵發現**：
1. **Codex 發現 package graph cycle**（D8）— Claude/Gemini R1 與 Claude R2 均未察覺 `OrreryCommand`/`MagiCommand`/`MCPServer` 現都在 `OrreryCore`，若 `OrreryMagi → OrreryCore` 則組裝點必須上移到 executable／integration layer。這是最重要的技術修正。
2. **Codex 發現 L10n plugin 硬編碼**（D9）— `L10nCodegenTool` 的 signatures 路徑寫死在 `Sources/OrreryCore/Resources/Localization/l10n-signatures.json`，且 plugin 只對 `OrreryCore` 生效，locale key set 要求完全一致。Claude R2 的「分檔 1-2h」不實；Gemini 的「B3.5 + plugin 改造」3-5h。採 Codex **L10n 不進 critical path** 的務實路線。
3. **`generateSummarizedVerdict` 也用 `DelegateProcessBuilder`**（D7）— Claude R2 T4 漏此 call site；Codex + Gemini 同時發現。
4. **`AgentExecutor` 協定寬度收斂**（D12）— 採中間版：cancellation/drain 進 executor（Codex 要求），`sessionId` 一級欄位（Codex）+ `metadata` forward-compat（Gemini），`Tool` 參數維持（短期 pragmatism）。
5. **Phase 3 三條明文觸發條件**（D13）+ **2026-07-01 Go/No-Go 錨點**（D15）。

### 建議的下一步

討論已 **ready for `/orrery:spec`**。建議流程：

1. ✅ 將本檔 feed 給 `/orrery:spec` 產出結構化實作 spec（對齊 `docs/discussions/2026-04-17-magi-spec-pipeline.md` 規劃）
2. 依 spec 產出 task 檔到 `docs/tasks/2026-04-17-magi-extraction.md` + `docs/tasks/registry/2026-04-17-magi-extraction.json`
3. 按 T1 → T9 順序執行；每個 ticket 完成後更新 CHANGELOG
4. 2026-07-01 依 D15 做 Go/No-Go review；屆時依 Magi API 穩定度、Phase 3 觸發條件達成度（D13）、2026 Q3 品類窗口（Q8）做拆 repo 決策

### 如果要開 R3（非必要）

若下列任一問題在實作前仍需收斂，才值得開 R3：
- **Q11**: `AgentExecutor.Result` 的 `metadata` 欄位 Phase 1 要不要先加？（5-10 分鐘可決；建議直接在 spec 內決）
- **Q12**: D8 組裝點放 `orrery` executable 還是新 integration target？（實作時決；不需討論）

否則**建議直接進 spec 階段**，不開 R3。

### 參考資料（給後續 spec 使用）

- 本檔：`docs/discussions/2026-04-17-magi-extraction.md`（全部 R1 + R2 紀錄）
- D1-D15 決策表（上方「決策紀錄」段）
- T1-T9 最終合併任務清單（上方）
- R1 列出的 Magi 相關檔案
- R2 新發現的關鍵檔案：
  - `Plugins/L10nCodegenTool/main.swift:59-62, 73-83, 109-132`（L10n 限制）
  - `Plugins/L10nCodegen/plugin.swift:7-15`（plugin 硬編碼 OrreryCore）
  - `Sources/OrreryCore/Commands/OrreryCommand.swift:8-37`（command 組裝點）
  - `Sources/OrreryCore/MCP/MCPServer.swift:4-59, 128-267`（MCP 組裝點）
  - `Sources/OrreryCore/Magi/MagiOrchestrator.swift:193-259`（第二個 `DelegateProcessBuilder` call site）
  - `Sources/OrreryCore/Magi/MagiAgentRunner.swift:52-58, 115-123`（session-id diff 邏輯）
