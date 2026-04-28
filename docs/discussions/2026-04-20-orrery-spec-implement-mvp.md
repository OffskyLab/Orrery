---
topic: "Orrery Spec Implement MCP Tool MVP 設計"
status: consensus
created: "2026-04-20"
updated: "2026-04-20"
participants:
  - Claude (Opus 4.6)
  - Codex (GPT-5.4)
  - Gemini (via cc-gemini-plugin R2；R1 CLI 走 gemini-3.1-pro-preview 遇 HTTP 429 無內容)
facilitator: Claude
rounds_completed: 2
magi_runs:
  - R1-attempt-1: "956277CB-D0E3-42B5-A742-EEF6368A43FF"
  - R1-retry: "0D1EF2A5-F28E-48CE-83C3-9DC67B4EDE49"
  - R2-gemini-plugin: "cc-gemini-plugin:gemini-agent（2026-04-20 分開跑，繞過 CLI 配額限制）"
---

# Orrery Spec Implement MCP Tool MVP 設計

## 議題定義

### 背景

- `orrery_spec_verify` MVP 已完成（2026-04-19，見 `docs/tasks/2026-04-18-orrery-spec-mcp-tool.md`）。
- 依 D15 的 MVP 釋出順序：`verify` → **`implement`** → `plan` → composite `run`。
- 本討論針對 `implement` phase 的特有問題，不重辯 D1-D17 已鎖定的架構決策。
- 從 `docs/discussions/2026-04-18-orrery-spec-mcp-tool.md` 繼承：session 混合模型（D9）、分階段子 tools（D5）、MCP 無狀態（D6）、stop-and-report（D11）、MVP 不 auto-commit（D16）、檔案放 `Sources/OrreryCore/Spec/`（D17）。

### 目標

1. 針對 `implement` 特有的 6 個問題（I1–I6）達成至少 majority 共識。
2. 產出可 feed 給 `/orrery:spec` 的共識報告，作為 implement spec 的輸入。
3. 識別需要使用者裁決的開放問題。

### 範圍

**討論內**：
- I1 Prompt 設計（傳給 delegate agent 的內容）
- I2 Plan → Implement 連續性（無 plan session 時的 fallback）
- I3 進度回報模型（block vs early-return + poll）
- I4 Diff 審查閘門（是否內部 self-check / output 豐富度）
- I5 失敗處理（retry budget / 例外）
- I6 並行 delegate（MVP 做不做 / 介面是否預留）

**討論外**：
- D1-D17 所有已鎖定決策
- Plan phase 與 composite `run` 的設計（屬後續 MVP）
- verify phase 的修改

### 約束

- 繼承 `docs/discussions/2026-04-18-orrery-spec-mcp-tool.md` 的全部決策 D1–D17
- `implement` phase 必須建在既有 `delegate + sessions` 之上，透過 `DelegateProcessBuilder` / `SessionResolver` 呼叫 claude-code subprocess
- D11 stop-and-report、D16 不 auto git commit 不可打破
- 延續 verify MVP 的 output schema 穩定性原則（error case 亦需完整 schema、Optional 顯式 encode 為 null）
- Phase 1 新檔案集中於 `Sources/OrreryCore/Spec/`（D17）

### 子議題

- [ ] **I1** Prompt 設計：送給 delegate agent 的 prompt 應包含 spec 的哪些段落？
- [ ] **I2** Plan → Implement 連續性：無 plan session 時 implement 如何行為？
- [ ] **I3** 進度回報：5-60 分鐘任務如何與 MCP client 60-120s timeout 共存？
- [ ] **I4** Diff 審查閘門：要不要在 implement 內部跑自我檢查？output payload 豐富度？
- [ ] **I5** 失敗處理：retry budget 與例外情境？
- [ ] **I6** 並行 delegate：MVP 做不做？介面是否預留？

---

## 討論紀錄

### Round 1 — 2026-04-20

**原始紀錄**：Magi Run `0D1EF2A5-F28E-48CE-83C3-9DC67B4EDE49`（`~/.orrery/magi/`）
**先前失敗嘗試**：`956277CB-D0E3-42B5-A742-EEF6368A43FF`（Codex raw output fallback、Gemini 429）

#### Claude (Opus 4.6)

**整體立場**：implement 應該保持「**produces code**」的 lean 層級，不吞掉 plan/verify 的職責邊界。善用 delegate agent 已有的 Read/Edit/Bash/Grep 能力，避免 orchestrator 內灌太多 schema 與邏輯。

**Positions**：

- **I1 Prompt 設計**：conditional — 傳 **spec path + anchor pointers**（指引讀哪些 section：`介面合約 / 改動檔案 / 實作步驟 / 驗收標準`），由 delegate 自己 `Read` 檔案。
  - 拒絕「全 spec 內聯」：token 成本隨 spec 成長膨脹（500+ 行不罕見）。
  - 拒絕「結構化 extraction」：丟失 markdown fidelity + 增加 parser 維護成本，且違反 D1 的「orrery_spec 契約不變」範圍約束。
- **I2 Plan → Implement 無 plan session**：conditional — **(c) fresh session，spec 即 plan**。
  - spec 本身已是 machine-executable runbook（介面合約 + 改動檔案 + 步驟 + 驗收標準），**足夠作為 implement 的唯一脈絡**。
  - (a) hard error 是 paternalistic；(b) auto-plan 把 D4 phase 邊界糊掉、兩倍 LLM 成本。
  - plan phase 的存在意義是「在 spec 之上多做一層 deliberation」，不是 gatekeeper。
- **I3 進度回報**：conditional — **(b) early-return `session_id` + 新增 `orrery_spec_status` polling tool**。
  - (a) block 違反 MCP 60-120s timeout 實務、一定超時。
  - (c) SSE 在 MCP client 不普遍支援、infra 成本高。
  - (b) 最符合 D6 無狀態：delegate 跑 detached subprocess（orrery delegate 既有能力）、status tool 讀持久化 session JSON。
- **I4 Diff 審查閘門**：agree — **MVP 只回 `{session_id, diff_summary}`，不內部 auto-verify**。
  - auto-verify 違反 D5 phase separation；要 verify 用 composite `orrery_spec_run`。
  - implement = 「produces code + reports diff」的最小職責；保留 debuggability（verify 失敗時可獨立 inspect implement output）。
- **I5 失敗處理**：agree — **stop-and-report，no retry，no budget**（MVP）。
  - 延伸 D11 語意到 implement：`{session_id, phase_reached, failed_step, error_stderr, diff_summary}`。
  - 使用者透過 `--resume-session-id` 或手動 pivot；auto-retry 是 YAGNI until 有 evidence 失敗多為 transient。
  - 實際 implement 失敗多為 spec/code 語意不匹配，retry 只會 burn tokens。
- **I6 並行 delegate**：agree — **(a) MVP pure sequential，不預留介面擴充**。
  - independence 偵測需要 dependency graph — 目前沒有且 false positive 會 corrupt state。
  - 「預留介面」等於 premature abstraction。
  - 重新考慮的觸發條件：≥ 3 個真實 spec 顯示可量測的 sequentiality idle。

#### Codex (GPT-5.4)

**整體立場**：implement 要「**可長跑、可恢復、可觀測**」，但不吞掉 plan/verify 的明確邊界。把 implement 做成黑箱大一統會違反 D4/D5；過於極簡又會丟品質訊號。

**Positions**：

- **I1 Prompt 設計**：agree — **結構化 extraction** 作為 prompt 主體（非全 spec、非過瘦）。應包含：
  - 目標 / 非目標
  - 介面合約
  - 改動檔案表
  - 實作步驟
  - 驗收標準
  - 失敗路徑 / 安全約束
  - plan 摘要（若有）
  - spec_path（讓 delegate 需要時 Read 原文 disambig）
  - 拒絕全 spec：discussion 歷史、遷移說明、CHANGELOG 類內容稀釋實作指令、增加 token 成本、提高抓錯重點機率。
  - 拒絕過瘦 prompt：缺 acceptance + safety 會讓 delegate 不知道停止條件。
- **I2 Plan → Implement 無 plan session**：agree — **(b) implement 自跑 lightweight plan 再實作**。
  - 與 D9「有 plan session 就 resume」不衝突；這是「無 plan session」的 fallback。
  - 若 spec 結構不足以支撐 lightweight plan → fail fast 建議先跑 plan。
  - 兼顧 UX 與成功率；避免把可直接執行的 runbook **被迫**拆成兩次操作。
- **I3 進度回報**：agree — **(b) early-return session_id + 輪詢 status tool**。
  - blocking 幾乎不可用（MCP timeout）。
  - SSE 明顯提高 client/server 複雜度與相容性風險。
  - 最符合 D6 無狀態：第一次只回 session_id/phase/status，後續 `orrery_spec_status` 讀持久化 session/job 狀態。
- **I4 Diff 審查閘門**：conditional — 不支持 auto-verify（違反 D4/D5），**但 implement 也不應只回 diff**。MVP output 應為：
  ```
  {session_id, diff_summary, completed_steps, self_check_summary, touched_files, blocked_reason?}
  ```
  - delegate 可在實作過程做**輕量 self-check**（local `swift build` / 單 test 片段）以利自我修正。
  - authoritative gate 仍由 `orrery_spec_verify` 或 composite `run` 負責。
  - 純 diff 的品質訊號太弱；自動跑正式 verify 又會把兩 phase 合一。
- **I5 失敗處理**：conditional — MVP stop-and-report + retry budget = 0，**但允許一個例外**：
  - **純 transport / subprocess-launch 失敗**（尚未建 session、尚未寫檔）→ 可 auto-retry **一次**。
  - 編譯錯 / agent 放棄 / timeout 等 terminal failure → 不 retry（語意失敗 retry 救不回，只會放大 working tree 混亂）。
  - 失敗時保留現場 + 回 `{session_id, failed_step, error_summary, diff_summary}`，手動 resume。
- **I6 並行 delegate**：agree — **(a) MVP 序列，但介面可預留擴充欄位**（`child_session_ids`、`execution_graph` 等）無 runtime behavior。
  - 現在缺可靠的 dependency/ownership 模型；implement 臨場猜「互不相依」風險高。
  - 並行預設會放大 repo 寫入衝突、進度追蹤、失敗歸因、resume 契約複雜度。
  - 並行應 predicated on **plan-phase declared** dependency + file ownership，不是 implement heuristics。
  - 與先前 Q12 open question 留到 M2+ 的立場一致。

#### Gemini

**無內容** — 本日兩次 attempts 均因 `gemini-3.1-pro-preview` HTTP 429 RESOURCE_EXHAUSTED 失敗（`"MCP issues detected. Run /mcp list for status."` 作為 stdout 頂端字串、無實質內容）。

**影響**：
- R1 Final Verdict 實質為 Claude + Codex 雙方共識
- Gemini 的長期生態 / optionality 觀點缺席 — 若後續 R2 配額恢復可補
- 無 blocker：雙方共識已涵蓋主要設計面、分歧 mapping 清楚

#### R1 Final Verdict（Claude + Codex 雙方共識）

**agreed**：
- **I3** 進度回報 → (b) early-return + 新 `orrery_spec_status` tool
- **I5** 失敗處理 → stop-and-report + retry budget 0（Codex 加一個 transport-fail 例外）
- **I6** 並行 delegate → MVP 序列（Claude 不預留欄位、Codex 建議預留 — 小分歧）

**有分歧需使用者裁決**：
- **I1** Prompt 設計細節：Claude anchor pointers vs Codex 結構化 extraction
- **I2** 無 plan session fallback：(c) fresh session（Claude）vs (b) lightweight plan（Codex）
- **I4** Implement output 豐富度：minimal `{session_id, diff_summary}`（Claude）vs richer + delegate self-check（Codex）

---

### Round 2 — 2026-04-20（Gemini via cc-gemini-plugin）

**背景**：R1 因 CLI 走 `gemini-3.1-pro-preview` 連兩次遇 HTTP 429 無內容。R2 改用 `cc-gemini-plugin:gemini-agent`（不同 infrastructure，不走直接 CLI API），成功取得 Gemini strategist 觀點。

#### Gemini（plugin，R2）

**整體立場**：DI1-DI3 都是穩健決策；U1-U3 分歧本質是「多付設計成本換未來 option」vs「YAGNI 守 MVP」的拉扯。**在 implement 這個 phase 上**值得多付結構化與可觀測性成本 — 因為 implement 是最接近「真 LLM 寫碼」的黑箱、也最可能被 heterogeneous agents 取代（未來換 aider/cursor-agent/self-tuned model 時介面越穩越好）。

**Positions**：

- **U1 Prompt 設計**：選**妥協版（keyed sections inline + spec_path fallback）**，偏 Codex 但採最窄解讀：
  - **必貼 prompt 主體**：`介面合約`（失去 → delegate 自發明 API）+ `驗收標準`（delegate 的 stop condition）
  - **靠 `Read`**：`改動檔案` / `實作步驟` / `失敗路徑` / `不改動的部分`
  - **Claude anchor pointers 的盲點**：實測 claude-code / codex CLI 第一步幾乎都會整檔 `Read`，等於把全 spec 塞進 context、只是延後一個 turn、多 1 round trip。
  - **Codex 全結構化的盲點**：parser 隨 spec template 演化而維護成本漲；但「介面合約」與「驗收標準」是 `/orrery:spec` 穩定契約的 heading，parser 風險最低。
  - **500+ 行 spec 永續性**：妥協版 prompt baseline 只隨兩段成長（不爆炸），其他段落膨脹不影響。
  - 建議新增 `SpecPromptExtractor.swift`，提供 `extractInterfaceContract` / `extractAcceptance`。
- **U2 無 plan session fallback**：選 **(c) fresh session（Claude）+ 小護欄**：
  - 使用者心智成本：spec 本質就是 plan 成品；跑 lightweight plan 會讓使用者困惑「spec 到底是不是 plan」
  - Phase 邊界污染：lightweight plan 和真 `orrery_spec_plan` 邊界極難劃清（見 Q-impl-5）— 兩層 plan 是 antipattern
  - **小護欄**：implement 啟動靜態檢查 spec 必含 `介面合約 / 改動檔案 / 實作步驟 / 驗收標準` 四 heading；缺任一 → fail-fast + 建議「先跑 `orrery_spec_plan`」。這保留「spec 結構不足就別硬幹」的安全閥，又不引入中間態。
- **U3 Output 豐富度 + self-check**：**分拆處理** — Output 靠 Codex（richer），self-check 靠 Claude（禁止）：
  - **Richer output 靠 Codex**：composite `orrery_spec_run` 要把 implement output 餵 verify，minimal 會讓 verify 要重掃檔案；schema 穩定性沿用 verify MVP 的「完整 schema + null 顯式 encode」原則；pickup skill 替代需要 `touched_files`。
  - **禁止 delegate 內部 self-check 靠 Claude**：允許 = 把 verify 權偷偷挪到 implement、違反 D4/D5；sandbox 一致性災難（reuse `SpecSandboxPolicy` 對 dev loop 太窄，會污染 verify 安全模型；獨立 policy 兩套維護）。
  - **`completed_steps` / `touched_files` 改走 passive 訊號**：delegate 靠 prompt 要求在 stop 時輸出結構化 summary + 自動收集 `git diff --name-only`，不需真跑 build。
  - 建議 schema（顯式不含 `self_check_summary`）：
    ```
    {session_id, phase:"implement", status:"done|failed|aborted",
     started_at, completed_at,
     completed_steps: [], touched_files: [],
     diff_summary, blocked_reason, failed_step,
     child_session_ids, execution_graph,  // DI3 預留
     error}
    ```
- **Q-impl-1 `orrery_spec_status` tool schema**：
  - Input：`{session_id (required), include_log (default false), since_timestamp (optional)}`
  - Output：`{session_id, phase, status, started_at, updated_at, progress{current_step,total_steps}, last_error, result (full result when !running), log_tail}`
  - Polling cadence（寫入 tool description）：首次 2s → exponential backoff `min(30s, prev*1.5)` → 長跑 >5min 固定 30s
  - 狀態檔位於 `~/.orrery/spec-runs/{session_id}.json`（**新目錄**，不與 magi run 混合），沿用 magi append-on-update pattern 以重用 IO helpers
  - CLI 入口：`orrery spec-run --mode status --session-id <id>`
- **Q-impl-4 failed_step 資料來源**：選 **(a) progress jsonl + (c) touched_files** 混合，不選 (b) transcript parsing（fragile、跨 CLI 格式異動會壞）：
  - **(a) progress jsonl**：prompt 要求 delegate append 一行 JSON 到 `$ORRERY_SPEC_PROGRESS_LOG`（`~/.orrery/spec-runs/{id}.progress.jsonl`），格式：`{"ts":iso, "step":"step-3", "event":"start|done|skip", "note":...}`。靠 delegate 既有的 `Bash` / `Write`，不依賴 structured progress event。
  - **(c) touched_files**：orchestrator 自動跑 `git diff --name-only`（已在 verify MVP allowlist）填入。
  - **failed_step 推斷**：progress jsonl 最後一個 `event==start` 但無對應 `done` 的 step。
  - **fallback**：progress log 空/壞 → `failed_step=null` + stderr 標註，**不**讓整個 tool fail。
  - 建議新增 `SpecProgressLog.swift` + prompt 模板尾段靠環境變數注入路徑。
- **Q-impl-5 lightweight plan 關係（若 U2 採 Codex 才相關）**：U2 已選 (c)，此題降級回答「若未來真要加如何避免混淆」：
  - **必須 schema 相同**，只差觸發點
  - 加 `plan_source: "user-invoked | implicit-from-implement"` 讓下游可區分
  - **但這已是 design smell** — strong recommendation 是 U2 採 (c) + 靜態完整性檢查。

**策略性補充（R1 雙方都沒看到）**：

1. **Implement 是最可能被 heterogeneous agent 取代的 phase**：verify 穩定、plan 穩定，implement 是「真 coding agent」未來可能換 aider/cursor/self-tuned model。**prompt 介面越標準化（偏 Codex 方向）、wiring 越通用，換 engine 成本越低** — 這是 U1 偏向妥協版的深層 long-term 理由。
2. **Progress log 協議化的 option preservation 價值**：Q-impl-4 的 progress jsonl 若設為**開放協議**（任何 delegate agent 都能 append），未來 plan/verify 都能用同一個觀測管道，`orrery_spec_status` tool 成為統一入口。**現在零成本、未來大 option**。
3. **`child_session_ids` / `execution_graph` 預留（DI3）值得讚賞** — 實作時記得寫 encode/decode tests 確保未來加 runtime 行為時 wire compat 不破。

**Gemini 修訂後的 Ticket 清單（可直接 feed 給 `/orrery:spec`）**：

| ID | 描述 | 估時 | 依賴 |
|----|------|-----:|------|
| T1 | `SpecAcceptanceParser` 擴充靜態 spec 完整性檢查（檢 4 heading 齊全） | 0.5d | — |
| T2 | `SpecPromptExtractor.swift`：`extractInterfaceContract` + `extractAcceptance` | 0.5d | T1 |
| T3 | `SpecProgressLog.swift`：jsonl append/read/failed_step 推斷 + tests | 1d | — |
| T4 | `SpecRunStateStore.swift`：`~/.orrery/spec-runs/{id}.json` 讀寫 | 1d | — |
| T5 | `SpecImplementRunner.swift`：組 prompt、呼叫 `DelegateProcessBuilder`、detached subprocess、寫 state + progress log 路徑注入 | 2d | T2, T3, T4 |
| T6 | `SpecRunResult` 擴充 implement 欄位 | 0.5d | — |
| T7 | `SpecRunCommand` 加 `--mode implement` 分支 + `--watch`（debug 用同步 block） | 1d | T5, T6 |
| T8 | `orrery_spec_status` MCP tool + CLI `spec-run --mode status` | 1.5d | T4 |
| T9 | `orrery_spec_implement` MCP tool 定義（early-return + DI1） | 0.5d | T7 |
| T10 | Transport-launch fail retry 例外（DI2）封裝在 `SpecImplementRunner` | 0.5d | T5 |
| T11 | `MCPSetupCommand` 寫入 `/orrery:spec-implement` + `/orrery:spec-status` slash | 0.5d | T9, T8 |
| T12 | Localization 三語 + l10n-signatures | 0.5d | T7-T11 |
| T13 | Tests：`SpecProgressLogTests` / `SpecImplementRunnerTests` / `SpecRunStatusTests` / `SpecImplementCommandTests` | 2d | T3-T10 |
| T14 | CHANGELOG + pickup D13 階段二遷移公告 | 0.5d | 全部 |

**總估時**：~12.5 工作日（單人），5-7d 核心 wiring + 3-4d tests + 1d docs。**關鍵路徑**：T3 → T4 → T5 → T7 → T9。

**小結（Gemini）**：implement MVP 的黃金切線是「prompt 靠介面合約+驗收標準雙核心 inline（U1 妥協）、spec 即 plan 不引入中間層（U2 Claude）、output 豐富但禁止內部 self-check（U3 分拆）」。加上 Q-impl-4 的 progress jsonl 開放協議，整個 spec 閉環的 long-term option 空間才真正打開。

---

## 共識看板

| # | 子議題 | Claude | Codex | Gemini (R2 plugin) | 狀態 |
|---|--------|--------|-------|-------|------|
| I1 | Prompt 設計 | anchor pointers + spec_path | 結構化 extraction + spec_path | **妥協版**：介面合約+驗收標準必 inline、其他靠 Read | **agreed 妥協版**（採 Gemini 窄解讀版 Codex 方案）|
| I2 | 無 plan session fallback | (c) fresh session（spec 即 plan）| (b) lightweight plan 再實作 | **(c) fresh + 靜態完整性檢查**作安全閥 | **agreed (c)**（2-1 共識 + 採 Gemini 安全閥）|
| I3 | 進度回報 | (b) early-return + poll | (b) early-return + poll | 同（提供完整 schema + polling cadence） | **agreed** |
| I4 Output | Implement output 豐富度 | minimal `{session_id, diff_summary}` | richer payload | **richer**（但去掉 `self_check_summary`） | **agreed richer**（2-1 with Gemini-adjusted schema）|
| I4 Self-check | delegate 內部 self-check | **禁止** | 允許輕量 build/test | **禁止**（sandbox 污染論點） | **agreed 禁止**（2-1；Gemini 與 Claude 同陣線）|
| I5 | 失敗處理 retry | 0 retry | 0 retry + transport-launch 例外 | 同 Codex | **agreed** |
| I6 | 並行 delegate + 欄位預留 | MVP 序列；不預留 | MVP 序列；預留擴充欄位 | 認可預留 DI3 | **agreed**（MVP 序列 + 預留欄位）|
| Q-impl-1 | status tool schema | — | — | 提供完整 input/output + polling cadence | **agreed**（採 Gemini 方案）|
| Q-impl-4 | failed_step 資料來源 | — | — | progress jsonl + git diff --name-only 混合 | **agreed**（採 Gemini 方案）|
| Q-impl-5 | lightweight plan ↔ real plan | — | — | U2 已選 (c)，本題 moot；若未來加需 schema 相同 + plan_source 欄位 | **deferred / moot** |

---

## 決策紀錄

| # | 決定 | 達成日期 | 依據 Round | 備註 |
|---|------|---------|-----------|------|
| DI1 | **I3 進度回報**：採 early-return + `orrery_spec_status` polling tool。第一次 tool call 回 `{session_id, phase:"running", status, started_at, plan_session_id?}`；delegate detached；狀態讀持久化 session/job JSON | 2026-04-20 | R1 | 雙方 agreed；對齊 D6 MCP 無狀態。 |
| DI2 | **I5 失敗處理 MVP**：stop-and-report，retry budget = 0，**唯一例外**：純 transport / subprocess-launch 失敗（尚未寫入任何檔案）可 auto-retry 一次 | 2026-04-20 | R1 | 雙方 agreed；Codex 的 transport 例外被採納（零風險）。 |
| DI3 | **I6 並行 delegate MVP**：MVP 純序列；**預留擴充欄位** `child_session_ids` / `execution_graph`（僅 schema，無 runtime behaviour）；觸發並行實作的條件為 plan phase 能明確標註 dependency + file ownership | 2026-04-20 | R1 | 採 Codex 中間方案（Claude 本來 YAGNI 不預留，但欄位預留幾近零成本且避免未來 breaking change）。 |
| **DI4** | **U1 Prompt 設計**：採**妥協版** — `prompt` 主體**必 inline**：`介面合約` + `驗收標準`兩段全文；`改動檔案` / `實作步驟` / `失敗路徑` / `不改動的部分` 走 `spec_path` + `Read` 指示。新增 `SpecPromptExtractor.swift` 提供 `extractInterfaceContract` / `extractAcceptance` | 2026-04-20 | R2 Gemini | Claude/Codex 的分歧由 Gemini strategist 角度的「delegate 會整檔 Read」與「parser 風險最低集中在兩段穩定 heading」收斂 |
| **DI5** | **U2 無 plan session fallback**：採 **(c) fresh session** — spec 即 plan。**小護欄**：implement 啟動靜態檢查 spec 必含 `介面合約 / 改動檔案 / 實作步驟 / 驗收標準` 四 heading；缺任一 → fail-fast 建議先跑 `orrery_spec_plan`；檢查 reuse T1 擴充的 `SpecAcceptanceParser` | 2026-04-20 | R2 | 2-1 共識（Claude + Gemini vs Codex）；Gemini 借 Codex 的 fail-fast 精神加安全閥 |
| **DI6** | **U3 Output 豐富度 + delegate self-check**：分拆決議：(1) **Output 採 richer**（`{session_id, phase:"implement", status, started_at, completed_at, completed_steps[], touched_files[], diff_summary, blocked_reason, failed_step, child_session_ids, execution_graph, error}`）；(2) **禁止 delegate 內部 self-check**（不跑 `swift build / test`、不 reuse `SpecSandboxPolicy`）；`completed_steps` / `touched_files` 走 **passive 訊號**（delegate prompt 自報 + orchestrator 跑 `git diff --name-only` 自動填）| 2026-04-20 | R2 | Output 豐富度 2-1（Codex + Gemini），self-check 2-1（Claude + Gemini）；Gemini 的「sandbox 污染論點」決定分拆 |
| **DI7** | **`orrery_spec_status` tool schema**：input `{session_id, include_log?, since_timestamp?}`；output `{session_id, phase, status, started_at, updated_at, progress{current_step,total_steps}, last_error, result (full when !running), log_tail}`；polling cadence 2s → exponential backoff `min(30s, prev*1.5)` → >5min 固定 30s，寫入 tool description | 2026-04-20 | R2 Gemini | 解 Q-impl-1；狀態檔走 `~/.orrery/spec-runs/{id}.json` 新目錄 |
| **DI8** | **failed_step / touched_files 資料來源**：混合方案 — (a) progress jsonl（`~/.orrery/spec-runs/{id}.progress.jsonl`，prompt 要求 delegate 每 step 邊界 append JSON：`{ts, step, event: start\|done\|skip, note}`）+ (c) `git diff --name-only` 自動收集 touched_files。failed_step 推斷：progress jsonl 最後一個 `start` 無對應 `done` 的 step；fallback：log 空/壞 → `failed_step=null` + stderr 標註、**不**讓 tool fail。拒絕 (b) transcript parsing（fragile、跨 CLI 格式異動會壞）| 2026-04-20 | R2 Gemini | 解 Q-impl-4；新增 `SpecProgressLog.swift` + 環境變數 `$ORRERY_SPEC_PROGRESS_LOG` 注入 delegate |
| **DI9** | **不實作 lightweight plan**（U2 已選 (c)，Q-impl-5 moot）— 若未來真要加，硬約束：schema 必須等於 `orrery_spec_plan`、加 `plan_source: "user-invoked \| implicit-from-implement"` 欄位供下游區分；但 Gemini 強 recommendation 不加（design smell）| 2026-04-20 | R2 Gemini | 預防性硬約束，避免未來無意中累積 design debt |

---

## 開放問題

### R1 後需使用者裁決（✅ 全部 R2 解決）

- ✅ **(U1)** I1 Prompt 設計細節 — DI4 採妥協版（介面合約 + 驗收標準 inline、其他 Read）
- ✅ **(U2)** I2 無 plan session fallback — DI5 採 (c) fresh + 靜態完整性檢查安全閥
- ✅ **(U3)** I4 Implement output — DI6 分拆：richer output + 禁止 self-check

### R2 可深化（✅ 多數解決）

- ✅ **(Q-impl-1)** `orrery_spec_status` tool schema — DI7
- ✅ **(Q-impl-2)** delegate 內部 self-check sandbox 邊界 — DI6 禁止 self-check，此題 moot
- ✅ **(Q-impl-3)** 結構化 extraction 具體欄位 — DI4 明定兩段（介面合約 + 驗收標準）
- ✅ **(Q-impl-4)** `failed_step` 資料來源 — DI8 progress jsonl + touched_files 混合
- ✅ **(Q-impl-5)** lightweight plan ↔ real plan — DI9 不實作 + 未來硬約束
- ✅ **(Q-impl-6)** `spec-runs/` 目錄格式 — DI7 明定 `~/.orrery/spec-runs/{id}.json` 新目錄

### R3（若需要）仍開放

- **(Q-impl-7)** `token_budget` 預設值與超限行為 — 繼承 `2026-04-18` Q13，仍待定（不 blocker）
- **(Q-impl-8)** Prompt 模板具體措辭（`SpecPromptExtractor` 裡的頭尾指示文字、progress log 注入訊息等）— 實作期自然會迭代，非 discussion-level 議題
- **(Q-impl-9)** Detached subprocess 的進程管理細節（PID 持久化？OS 重啟後孤兒 process 如何清理？）— 可能屬於 Magi extraction 之後才細究的 infra 問題

### 繼承舊 discussion 的 open questions

- **(Q10, Q12, Q13 from `2026-04-18-orrery-spec-mcp-tool.md`)**
  - Q10 pickup skill offline preview 能力 — 本討論不涉
  - Q12 互不相依步驟併發偵測 — 已被 DI3 部分處理（schema reserve，runtime defer）
  - Q13 token_budget 超限行為 — 繼承為 Q-impl-7，實作 implement MVP 時需決定預設值

---

## 下次討論指引

### 進度摘要

**R1+R2 達成完整共識（status: consensus）**。R1 因 Gemini CLI HTTP 429 僅 Claude/Codex 雙方；R2 改走 `cc-gemini-plugin:gemini-agent` 成功補上 Gemini strategist 觀點，三個 disputed 議題（U1/U2/U3）全數解決，並同步解掉 R2 的深化問題（Q-impl-1 到 Q-impl-5）。

**最終設計結論**：「prompt 靠介面合約+驗收標準雙核心 inline（U1 妥協）、spec 即 plan 不引入中間層（U2 Claude）、output 豐富但禁止內部 self-check（U3 分拆）」— 加 Q-impl-4 progress jsonl 開放協議，整個 spec 閉環的 long-term option 空間已打開。

共產出 **9 項決策**（DI1-DI9）+ **Gemini 的 14-ticket 任務清單**（~12.5 工作日）。

### 下一步建議

討論已 **ready for `/orrery:spec`**：

1. 執行 `swift run orrery spec docs/discussions/2026-04-20-orrery-spec-implement-mvp.md --output docs/tasks/2026-04-20-orrery-spec-implement-mvp.md`
2. 產出的 spec 可直接拿 Gemini 14-ticket 清單作為「改動檔案 + 實作步驟」的骨架
3. 建立 registry entry（`docs/tasks/registry/2026-04-20-orrery-spec-implement-mvp.json`）
4. 依 T1 → T14 順序實作

### 閱讀建議

- 本檔 R1 記錄
- `docs/discussions/2026-04-18-orrery-spec-mcp-tool.md` D1-D17（繼承基礎）
- `docs/tasks/2026-04-18-orrery-spec-mcp-tool.md`（verify MVP 的實作 pattern）
- `Sources/OrreryCore/Spec/SpecVerifyRunner.swift`（process drain、timeout、结果組裝 pattern 可直接套用）
- `Sources/OrreryCore/Helpers/DelegateProcessBuilder.swift`（implement 要用的核心）
- `Sources/OrreryCore/Helpers/SessionResolver.swift`（session diff 邏輯）

### 注意事項

- R2 若重開：聚焦 U1/U2/U3 + Q-impl-1 到 Q-impl-6；**不**捲回 D1-D17 或 I3/I5/I6 已 agreed 部分
- Gemini 配額問題若持續，考慮 R2 改 Codex-only 深化或使用者直接裁決
- implement spec 的寫法可直接繼承 verify spec 的 8 段結構 + CodingKeys pattern

---

## R2 歷史附錄：Gemini CLI 配額問題與 plugin 繞路

**2026-04-20 紀錄**：R1 透過 `orrery magi` CLI 執行時，`gemini-3.1-pro-preview` 連兩次遇 HTTP 429 `"No capacity available on the server"`。本為等待配額恢復的計畫，但改試 `cc-gemini-plugin:gemini-agent` subagent 後發現它走不同 infrastructure、**沒有配額問題**，遂直接在 R2 跑通 Gemini strategist 觀點。**操作提示**：日後 `orrery magi` 遇到類似 Gemini CLI 配額問題，可改用 Claude Code 的 gemini plugin agent 作為替代路徑。

（原「R2 Ready-to-Run」指示已過期，改留作 reference）

### ~~R2 Ready-to-Run 命令（已由 plugin 路徑替代）~~

**狀態**：2026-04-20 多次 probe 均失敗（`gemini-3.1-pro-preview` 回 `No capacity available on the server, Max attempts reached`）— 為**伺服器容量**問題而非個人配額，等待時間不可預測（分鐘級到小時級）。

**先決條件**：
- `gemini -p "ping"` 能正常回話（非 429）
- 或決定放棄等 Gemini、直接走 Codex-only R2（見下）

**當配額恢復，直接執行以下命令即可接續 R2**（只需貼到 terminal）：

```bash
swift run orrery magi \
  --resume 0D1EF2A5-F28E-48CE-83C3-9DC67B4EDE49 \
  --rounds 1 \
  --output /tmp/magi-impl-r2.md \
  "R2 — 深化 R1 Open Questions（請先讀 docs/discussions/2026-04-20-orrery-spec-implement-mvp.md 了解 R1 共識 DI1-DI3 與三個 disputed 議題 U1/U2/U3）; U1: I1 Prompt 設計分歧 — Claude 主張 anchor pointers（只給 spec_path + 指引段落讓 delegate 自己 Read）vs Codex 主張結構化 extraction（key sections 貼進 prompt 並保留 spec_path fallback）。妥協方案是否成立、具體欄位清單為何; U2: I2 無 plan session fallback 分歧 — Claude (c) fresh session spec 即 plan vs Codex (b) implement 自跑 lightweight plan 再實作。具體 trigger 規則（spec 缺什麼段落該 fail-fast、lightweight plan 如何與真 plan phase 區分）; U3: I4 output 豐富度分歧 — Claude minimal {session_id, diff_summary} vs Codex richer {...+ completed_steps, self_check_summary, touched_files} + 允許 delegate 內部輕量 swift build／test self-correction。具體 sandbox 邊界（是否 reuse SpecSandboxPolicy）與 token 成本估算; Q-impl-1: orrery_spec_status polling tool 的 input／output schema 與 polling cadence 建議; Q-impl-4: failed_step 的資料來源 — claude-code subprocess 沒 structured progress event，delegate 如何通報卡在哪步？靠 prompt 要求 delegate 寫 progress log 到 session 檔？; Q-impl-5: 若採 Codex U2 lightweight plan，它與 orrery_spec_plan phase 的差異與 output 是否一致"
```

**備選方案（不等 Gemini）**：

```bash
# Codex-only R2：只拿 Codex 對 U1/U2/U3 + Q-impl 的進一步立場
swift run orrery magi --codex \
  --resume 0D1EF2A5-F28E-48CE-83C3-9DC67B4EDE49 \
  --rounds 1 \
  --output /tmp/magi-impl-r2-codex.md \
  "<same topic as above>"
```

或**使用者直接裁決**：不開 R2，直接寫三個決策到 DI4-DI6，然後 `/orrery:spec`。

**在 R2 完成後、進 spec 前**：
1. 把 R2 結果整合進本討論檔（新增 Round 2 段 + 更新共識看板 + DI4-DIn）
2. 判斷是否還有 disputed → 決定或再開 R3
3. 執行：
   ```bash
   swift run orrery spec \
     docs/discussions/2026-04-20-orrery-spec-implement-mvp.md \
     --output docs/tasks/2026-04-20-orrery-spec-implement-mvp.md
   ```
4. 建立 registry entry 並進入 pickup 流程
