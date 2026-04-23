---
topic: "Orrery 新增 MCP tool 來實作 orrery_spec 產出的 spec"
status: consensus
created: "2026-04-18"
updated: "2026-04-18"
participants:
  - Claude (Opus 4.6)
  - Codex (GPT-5.4)
  - Gemini
facilitator: Claude
rounds_completed: 2
magi_runs:
  - R1: BFEBC206-C084-4479-8D9C-089BEE33F3AA
  - R2: 0B70FACB-5A92-4356-B65D-FD9815CB356E
---

# Orrery 新增 MCP tool 來實作 orrery_spec 產出的 spec

## 議題定義

### 背景

- `orrery spec` / `orrery_spec` MCP tool 已完成（2026-04-17 整合），可把討論 MD 轉成結構化 spec（範例見 `docs/tasks/2026-04-17-magi-extraction.md`）。
- 目前 spec→實作這一段仍仰賴 `pickup` skill（本地 Claude Code 執行）；此為 local-only、非產品化、無法跨 agent 或 MCP client 使用。
- 使用者希望新增**第二個 orrery MCP tool** 來實作 orrery_spec 產出的 spec，形成「discuss → spec → implement」完整閉環，與現有 orrery 基礎設施（`delegate` / `sessions` / `magi`）整合。

### 目標

1. 評估「新增 MCP tool 來實作 spec」的可行性與設計方向。
2. 明確 tool 的**職責邊界**、**input/output 契約**、**安全模型**。
3. 定位與現有 `pickup` skill、`delegate` / `sessions` / `magi` 的關係。
4. 產出可 feed 給 `/orrery:spec` 的最終共識，作為實作 spec 的輸入。

### 範圍

**討論內**：
- Tool 的介面設計（input/output schema、單一 vs 分階段 tools）
- 實作策略（一次到位 vs 分階段 vs scaffolding-only）
- 與 pickup skill / delegate / sessions / magi 的整合
- Sandbox 與破壞半徑控管
- 失敗處理與回滾語意
- Magi review 整合時機
- Swift target 歸屬與 Package.swift 重構時機
- MVP 範圍

**討論外**：
- orrery_spec 自身內部設計（已另有討論）
- Magi extraction 實作細節（已另有討論）
- pickup skill 的保留/廢棄時機（只決定方向，不定具體版號）

### 約束

- 不改變現有 `orrery_spec` 的 input/output 契約
- 必須複用現有 `orrery delegate` / `sessions` 基礎設施，不另起執行通道
- 與已決議的 Magi extraction 架構一致（獨立 target + `ProcessAgentExecutor`）
- MVP 不得包含「自動 git commit」等破壞性行為；破壞半徑限縮 working directory

### 子議題（R1）

1. 新增 MCP tool 實作 orrery_spec 產出的 spec 是否可行／合理？
2. 職責邊界與 input/output 設計（spec 路徑進 → ？出）
3. 實作策略：一次到位 vs plan/implement/verify 分階段 vs 僅 scaffolding
4. 與現有 pickup skill / delegate / sessions / magi 的關係
5. MCP 表面設計：單一 tool vs 分階段子 tools
6. 可行性、風險、MVP 範圍建議

### 子議題（R2 — R1 延伸）

- **Q1**：session_id 在 plan/implement/verify 三階段的傳遞契約
- **Q2**：verify 階段 sandbox 邊界（dry-run / --execute scope / 破壞半徑）
- **Q3**：composite `orrery_spec_run` 的失敗中止與回滾語意
- **Q4**：`--review` flag 觸發 Magi review 的時機與結果整合
- **Q5**：pickup skill 與新 MCP tool 並行期 UX 邊界
- **Q6**：`OrrerySpec` 獨立 target 的 Package.swift 重構細節

---

## 討論紀錄

### Round 1 — 2026-04-18

**原始紀錄**：Magi Run ID `BFEBC206-C084-4479-8D9C-089BEE33F3AA` / `~/.orrery/magi/BFEBC206-....json`

#### Claude (Opus 4.6) — Verifier 角度

讀完 `docs/tasks/2026-04-17-magi-extraction.md`（具體範例）+ `docs/discussions/2026-04-17-magi-spec-pipeline.md`（上游脈絡）。

**整體立場**：支持，但要設邊界。extraction spec 本身結構極強（介面合約、改動檔案表、步驟、失敗路徑、驗收標準 + 12 條可執行指令），已接近「machine-executable runbook」。tool 的核心價值是**模板化的 delegate + verify 迴圈**，不是取代 coding agent。

**Positions**：
- **1**（新增 MCP tool）：agree — extraction spec 已接近 machine-executable runbook，產品化合理；tool 的核心價值是模板化的 delegate+verify 迴圈
- **2**（input/output）：conditional — input: `{spec_path, tool, mode, resume_session_id, timeout}`；output 必含 `session_id + phase + verification + summary_markdown`。硬約束：tool 不直接 mutate repo，透過 `ProcessAgentExecutor` 走 delegate subprocess，MCP server 無狀態
- **3**（策略）：agree — 分階段最符合 spec 結構（步驟→改動檔案→驗收標準 三段式天然對應 plan/implement/verify）。一次到位 prompt 過長且 verify 被省略；scaffolding-only 價值低
- **4**（關係整合）：conditional — 建在 delegate + sessions 之上（複用 `ProcessAgentExecutor`、一級 `session_id` 回傳以便 verify 失敗 resume）；magi 降級為 opt-in `--review`；pickup 降為 local preview，MCP 為 canonical
- **5**（表面設計）：agree — 三個 sub-tools（plan/implement/verify）+ 一個 composite（run）。verify 需可獨立重跑；單一 mode-parameter 表達力不足
- **6**（MVP）：conditional — MVP 第一步只做 `orrery_spec_verify`（風險最低、對 extraction spec 立即有用）；再加 implement、plan、run。風險：spec 品質變異 / shell 執行安全 / 成本失控 / 與 pickup 重疊。架構：比照 Magi extraction 放獨立 `OrrerySpec` target

#### Codex (GPT-5.4)

**原始 raw output 為空（parsed fallback）**；立場透過 Final Verdict 綜合呈現，與 Claude/Gemini 方向一致，特別強調：
- tool 作為 orchestrator，針對 spec 中「互不相依步驟」自動產生 `orrery delegate` 併發執行
- 預設 dry-run + `--execute` flag
- 強制 timeout + token budget
- MVP 不自動 git commit

#### Gemini

**整體立場**：高透明度、分階段、**將控制權交還給 MCP client**。LLM 處理長步驟容易產生幻覺或在首個編譯錯誤崩潰；大型重構最忌諱「黑箱一次性」。

**Positions**：
- **1**（新增 MCP tool）：agree — orrery_spec 產出已具結構化（檔案清單、步驟、驗證指令），為自動化代理提供完美 ground truth
- **2**（input/output）：conditional — input: 檔案路徑；output 絕對不能只是成功/失敗字串，必須結構化 JSON（completed_steps、中繼狀態、具體錯誤），Client 可寫入 memory 避免迷失進度
- **3**（策略）：conditional — 強烈反對一次到位（以 Magi 模組拆分為例，`Package.swift` 依賴設錯產生 Cycle，後續修改全部徒勞）。每完成一個邏輯區塊觸發中繼驗證（`swift build`）
- **4**（關係整合）：conditional — 新工具定位為 Magi 下游執行者，吸收 pickup 最佳實踐；針對 spec 中「互不相依」步驟自動產生 `orrery delegate` 併發
- **5**（表面設計）：conditional — 分階段子 tools。單一 `execute_spec` 會讓 MCP Server 變成難以監控的 long-running process，易觸發 Client Timeout。暴露 `parse_spec` / `execute_spec_step` / `run_spec_verification` 等細粒度工具讓 Client 掌控 control flow，才符合 MCP 哲學
- **6**（MVP）：conditional — 可行性高。最大風險是 spec 內容過期或與 codebase 實際狀態脫節。MVP：解析 spec、執行單一步驟並回報 diff、執行測試指令。**絕不**包含自動 git commit

#### R1 Final Verdict（三方共識）

6/6 sub-topics **agreed**。核心共識：
- tool 消費 orrery_spec 結構化 spec 是合理產品化方向
- Input 以 spec 路徑為核心 + tool/mode/resume/timeout；Output 結構化 JSON
- 採 **plan/implement/verify 三階段**
- 建在 delegate + sessions 上，Magi 降為 opt-in review，pickup 降為 local preview
- **分階段子 tools**：`orrery_spec_plan` / `implement` / `verify` + composite `run`
- MVP 第一步 `verify`（不寫碼、風險最低）；架構放獨立 `OrrerySpec` target

**R1 遺留 Open Questions**：session_id 契約 / verify sandbox 邊界 / composite 失敗語意 / review 時機 / pickup 並行 UX / OrrerySpec target 時機 / token budget defaults / 互不相依步驟併發偵測。

---

### Round 2 — 2026-04-18

**原始紀錄**：Magi Run ID `0B70FACB-5A92-4356-B65D-FD9815CB356E`

聚焦 R1 6 個 Open Questions 的邊界細化。

#### Claude (Opus 4.6)

**Q1（session_id 契約）**：conditional — **混合模型**：plan create session_A → implement 預設 resume session_A（延續規劃脈絡）→ verify 一律 fresh session（避免 implementer 幻覺污染檢查）。composite 回傳 `{plan_session_id, impl_session_id, verify_session_id, phase_reached}`。失敗時回傳最新 `session_id` 供手動 resume 補修，tool 本身不自動重試。

**Q2（verify sandbox）**：conditional — **三層防禦**：
- L1：預設 dry-run 只印不跑
- L2：`--execute` 進 gated 模式，allowlist 前綴（`swift` / `grep` / `test` / `git diff|log` / `.build/debug/orrery`），blocklist（`rm` / `sudo` / `git push|reset --hard|commit|checkout|clean`）；`python3 -c` 走 AST lint
- L3：硬限制 — CWD 限 repo、每指令 60s、整體 10min、stdout 1MB

不在 allowlist → `skipped (policy)` 明確回報。比 Gemini 的「no auto git commit」更嚴，將 `reset/push/clean/checkout` 都列入 blocklist。

**Q3（composite 失敗語意）**：conditional — **Stop-and-report，絕不自動 rollback**。反對任何 `git stash/restore/reset --hard` 自動化 — 會吃掉 user 在同 tree 的其他變更，跟 MVP 不 auto-commit 原則同源。Output：`{phase_reached, failed_step, error_stderr, diff_summary (git diff --stat), sessions}`。Tool 可在 error message 建議 rollback 指令**但絕不執行**。

**Q4（--review 時機）**：conditional — **Only verify 之後、advisory 層級**。反對每階段 review（plan review 幫助小、implement review 與 verify 功能重疊、成本 3x）。Output 加 `review: {verdict, reasoning, flagged_items}`。關鍵：review 不覆蓋 verify 的 pass/fail — CLI/MCP 最終 exit code 看 verify（shell 執行結果為 authoritative），review 只提供語意判斷。

**Q5（pickup 並行 UX）**：conditional — **Canonical = MCP tool**；pickup 降為 local preview。不立即 deprecate，分三階段 CHANGELOG：當版（推薦 MCP、skill 保留）→ 兩個 release 後（`@deprecated` + MIGRATION.md）→ 第三個 release（移除）。硬約束：並行期兩者行為不得分叉，或讓 skill 變成 MCP tool 的 thin wrapper 共用 core 邏輯。

**Q6（OrrerySpec target 時機）**：conditional — **等 Magi extraction 完成再動**，不合併 PR。反對合併：scope 膨脹、Package.swift 改動交纏、review 成本暴增。反對提前：OrrerySpec MVP 只做薄薄的 verify，不急著拆 target。節奏：P1 完成 Magi extraction（建立 target pattern + `ProcessAgentExecutor` 樣板）→ P2 OrrerySpec 複製同 pattern → 若 MVP 需先出，可暫放 `Sources/orrery/`，**絕不塞 `OrreryCore`**。

#### Codex (GPT-5.4)

**原始 raw output 為空（parsed fallback）**；立場在 Final Verdict 綜合呈現，與 Gemini 方向高度一致。

#### Gemini

**Q1**：conditional — 首次啟動（plan/run）建立 `session_id` 並回傳 Client；後續階段由 Client 帶入 resume；失敗時 JSON 含 id + 錯誤詳情，交 Client 決定。確保 MCP Server 無狀態。（**未明示 verify 層級分離**）

**Q2**：conditional — 預設嚴格 dry-run + 白名單（`swift build` / `swift test` / `ls` 等唯讀/測試指令）；破壞性指令必須阻擋除非顯式 `--execute`。

**Q3**：conditional — Fail-fast 中止；**絕不自動 Rollback**（會抹除有價值的 debug 狀態）。保留 working directory 現狀、回報 diff + error log。

**Q4**：conditional — 為控制成本，Magi review **只在 verify 成功後觸發一次**；結果作為 `review_comments` 欄位整合進 output JSON，不干擾執行流。

**Q5**：conditional — pickup 定位人類互動式預覽工具；MCP tool 定位 agent 自動化標準介面。CHANGELOG 強調使用情境差異，待 MCP 成熟後再考慮廢棄 skill。

**Q6**：agree — 強調必須**分開 PR**，以降低一次性修改 `Package.swift` 帶來的構建失敗風險。

#### R2 Final Verdict

- **Q1 → majority**（Claude 混合模型 vs Gemini 單鏈）— 使用者裁決後確認採用**混合模型**（見 D9）
- **Q2–Q6 → 全部 agreed**

---

## 共識看板

| # | 子議題 | Claude | Codex | Gemini | 狀態 |
|---|--------|--------|-------|--------|------|
| R1-1 | 新增 MCP tool 實作 spec | agree | agree | agree | **agreed** |
| R1-2 | input/output 設計 | agree | agree | agree | **agreed** |
| R1-3 | plan/implement/verify 分階段 | agree | agree | agree | **agreed** |
| R1-4 | 與 delegate/sessions/magi/pickup 整合 | agree | agree | agree | **agreed** |
| R1-5 | 分階段子 tools + composite | agree | agree | agree | **agreed** |
| R1-6 | MVP 先做 verify | agree | agree | agree | **agreed** |
| R2-Q1 | session_id 契約（混合 vs 單鏈） | 混合 | 單鏈 | 單鏈 | **agreed**（使用者裁決採混合 — D9）|
| R2-Q2 | verify sandbox 三層防禦 | agree | agree | agree | **agreed** |
| R2-Q3 | composite stop-and-report，不 rollback | agree | agree | agree | **agreed** |
| R2-Q4 | `--review` verify 後一次、advisory | agree | agree | agree | **agreed** |
| R2-Q5 | pickup 3 階段遷移；MCP = canonical | agree | agree | agree | **agreed** |
| R2-Q6 | `OrrerySpec` target 等 Magi extraction 後、分開 PR | agree | agree | agree | **agreed** |

---

## 決策紀錄

| # | 決定 | 達成日期 | 依據 Round | 備註 |
|---|------|---------|-----------|------|
| D1 | **新增 MCP tool 產品化 spec 實作**，消費 `orrery_spec` 產出的結構化 spec（已接近 machine-executable runbook）| 2026-04-18 | R1 | 三方一致。 |
| D2 | **Input schema**：`{spec_path, tool?, mode, resume_session_id?, timeout?}`（`mode ∈ {plan, implement, verify, run}`）| 2026-04-18 | R1+R2 | 硬約束：tool 不直接 mutate repo。 |
| D3 | **Output schema（結構化 JSON）**：`{session_id, phase, completed_steps, verification: {checklist, test_results}, summary_markdown, stderr, diff_summary?, sessions?, review?}`。`session_id` 為一級欄位 | 2026-04-18 | R1+R2 | Client 可寫入 memory 避免迷失進度。 |
| D4 | **實作策略：plan/implement/verify 三階段**。spec 的「步驟→改動檔案→驗收標準」三段式結構天然對應 | 2026-04-18 | R1 | 每階段完成後觸發中繼驗證（如 `swift build`）；反對一次到位與僅 scaffolding。 |
| D5 | **MCP 表面設計：分階段子 tools + composite**：`orrery_spec_plan` / `orrery_spec_implement` / `orrery_spec_verify` + `orrery_spec_run`（composite 串跑三階段、失敗中止）| 2026-04-18 | R1 | verify 需可獨立重跑（人工 implement 後只跑驗收）；MCP schema 以分開最清楚。 |
| D6 | **架構**：建在 `delegate + sessions` 之上，複用 `ProcessAgentExecutor`；MCP server 保持無狀態，session 生命週期由 Client 驅動 | 2026-04-18 | R1+R2 | 對齊 Magi extraction D12（`AgentExecutor` protocol）。 |
| D7 | **Magi 降級為 opt-in `--review`**；pickup skill 降級為 offline/local preview；MCP tool 為 canonical 自動化介面 | 2026-04-18 | R1 | 對齊 `2026-04-17-magi-spec-pipeline.md` 的 `--review` opt-in 決策。 |
| D8 | **架構位置**：`OrrerySpec` 為**獨立 Swift library target**；不塞 `OrreryCore` | 2026-04-18 | R1+R2 | 比照 Magi extraction D4/D10 pattern。 |
| D9 | **Q1 使用者裁決：session_id 採混合模型** — `plan` 建立 session_A → `implement` 預設 resume session_A（延續規劃脈絡）→ `verify` **一律 fresh session**（外部檢查員，避免 implementer 幻覺污染）。`run` composite 回傳 `{plan_session_id, impl_session_id, verify_session_id, phase_reached}` | 2026-04-18 | R2+使用者 | 2026-04-18 使用者明確選擇混合模型。失敗時回傳最新 session_id 供手動 resume；tool 不自動重試。 |
| D10 | **Q2 verify sandbox 三層防禦**：(L1) 預設 dry-run 只印不跑；(L2) `--execute` 進 gated 模式，allowlist（`swift build/test` / `grep` / `test` / `git diff\|log` / `echo` / `cat` / `.build/debug/orrery`）+ blocklist（`rm` / `sudo` / `git push\|reset --hard\|commit\|checkout\|clean` / 管線到 `sh\|bash -c`），`python3 -c` 僅允許 AST lint 過關；(L3) 硬限制：CWD 限 repo、單指令 60s、整體 10min、stdout 1MB。不在 allowlist → `skipped (policy)` 明確回報 | 2026-04-18 | R2 | 三方 agreed。Claude 版本比 Gemini 嚴（加 `reset/push/clean/checkout` 到 blocklist）。 |
| D11 | **Q3 composite 失敗語意：Stop-and-report，絕不自動 rollback**。反對任何 `git stash/restore/reset --hard` 自動化（會吃掉 user 同 tree 其他變更）。Tool 可在 error message 建議 rollback 指令**但不自動執行** | 2026-04-18 | R2 | Fail-fast；output 含 `diff_summary (git diff --stat)`。 |
| D12 | **Q4 `--review` 觸發：verify 後一次、advisory 層級**。不覆蓋 verify 的 pass/fail；CLI/MCP 最終 exit code 以 verify 為 authoritative，review 僅提供語意判斷。Output 加 `review: {verdict, reasoning, flagged_items}` | 2026-04-18 | R2 | 反對每階段 review（成本 3x、plan review 幫助小、implement/verify 重疊）。 |
| D13 | **Q5 pickup 3 階段 CHANGELOG 遷移**：當版（推薦 MCP、skill 保留）→ +2 releases（`@deprecated` + MIGRATION.md）→ +3 releases（移除）。並行期兩者行為**不得分叉**；建議 skill 變為 MCP tool 的 thin wrapper 共用 core 邏輯 | 2026-04-18 | R2 | Canonical = MCP tool；pickup 降為 offline/local preview。 |
| D14 | **Q6 `OrrerySpec` target 時機**：等 Magi extraction 完成後再動，**分開 PR**（不合併）。若 MVP verify 需先出，可暫放 `Sources/orrery/` executable target，**絕不塞進 `OrreryCore`** | 2026-04-18 | R2 | 節奏：P1 Magi extraction（立 target pattern） → P2 OrrerySpec 複製 pattern。 |
| D15 | **MVP 第一步：只做 `orrery_spec_verify`**（不寫碼、風險最低、對現有 extraction spec 立即有用）。依序加 `implement` → `plan` → composite `run` | 2026-04-18 | R1+R2 | 對齊 D10 sandbox 設計（verify 預設 dry-run 天然安全）。 |
| D16 | **MVP 硬約束**：spec 必須含驗收標準段落；不包含自動 git commit；每呼叫強制 timeout + token budget；錯誤回報 diff 交人類審查 | 2026-04-18 | R1+R2 | 破壞半徑限縮於 working directory。 |
| D17 | **修訂 D14：任務順序 + MVP 位置**。原 D14「等 Magi extraction 完成後再動」取消。**新順序**：Phase 1 = Spec MVP（本 spec）先做、Phase 2 = Magi extraction 後做。Phase 1 的 Swift 實作檔**暫放 `Sources/OrreryCore/Spec/`**（與既有 `SpecCommand.swift` 同目錄），**不**新開 target、**不**動 `Package.swift`。Phase 2 動 `Package.swift` 時一次性處理：(1) 建 `OrreryMagi` + `OrrerySpec` targets；(2) 同時批次搬遷 `Sources/OrreryCore/Magi/*` 與 `Sources/OrreryCore/Spec/*`；(3) 解 D8 package graph cycle（組裝點上移到 executable target）。**Phase 1 硬約束**：新增檔案必須集中 `Sources/OrreryCore/Spec/`，不散落 `OrreryCore` 其他子目錄，以利 Phase 2 批次搬遷 | 2026-04-19 | 使用者指示 | 使用者 2026-04-19 要求 Spec 優先、Magi 延後。方案 (a)「暫放 `Sources/orrery/`」需先解 Package graph cycle（= 執行 Magi extraction 的 D8），違背「Spec 先做」意圖；方案 (b)「現在建 `OrrerySpec` target」同撞 D8；方案 (c) 延續既有 `OrreryCore/Spec/` pattern 最省事，搬家成本延後到 Phase 2 批次處理。 |

---

## 開放問題

**R1+R2 已解**（✅）：
- ✅ R1 的全部 6 個子議題
- ✅ Q1 session 契約（使用者裁決混合模型 — D9）
- ✅ Q2–Q6 全部

**R2 後新開放問題**（留實作期決定）：

- **(Q7)** Failed phase 是否仍允許觸發 `--review` 作 diagnostic？還是只在 verify pass 後 review？
- **(Q8)** Allowlist `python3 -c` 的 AST lint 具體實作方案與維護責任
- **(Q9)** Composite `run` 的整體 10min timeout 是否可被 `--timeout` 覆寫？覆寫上限？
- **(Q10)** Pickup skill 若收斂為 MCP tool thin wrapper，本地 preview 的**離線能力**如何保留？（pickup 目前可在沒有 MCP server 的環境用）
- **(Q11)** OrrerySpec MVP 暫放 `Sources/orrery/` 的話，測試 target 依賴如何宣告？
- **(Q12)** Spec 中「互不相依步驟」的自動偵測規則（是否併發 delegate）— R1 Gemini 提及，R2 未定案，留給 M2 以後
- **(Q13)** `token_budget` 超限的預設行為（警告 vs 中止）

---

## 下次討論指引

### 進度摘要

**R1 + R2 完成，討論達成完整共識**（status: consensus）。

- R1 達成 6 個 agreed，留下 6 個 Open Questions
- R2 針對 6 個 Open Questions 細化，5 個 agreed、1 個 majority（Q1 session 契約有 Claude vs Gemini 分歧）
- **使用者 2026-04-18 裁決 Q1 採混合模型**（D9），所有 R1+R2 議題均達 agreed
- 產出 16 項決策（D1–D16）+ 13 個 follow-up open questions（Q7–Q13 留實作期）

### 建議下一步

討論已 **ready for `/orrery:spec`**。建議流程：

1. ✅ 執行 `/orrery:spec docs/discussions/2026-04-18-orrery-spec-mcp-tool.md` 產出結構化 spec
2. 將 spec 排在 Magi extraction（`docs/tasks/2026-04-17-magi-extraction.md`）**之後**執行（D14 約束）
3. MVP 第一步：實作 `orrery_spec_verify`（D15）
4. 依序：`verify` → `implement` → `plan` → composite `run`
5. pickup skill CHANGELOG 遷移（D13）於 `orrery_spec_verify` 釋出當版同步宣告

### 參考資料

- 本檔（全部 R1+R2 紀錄）
- D1-D16 決策表
- 上游討論：`docs/discussions/2026-04-17-magi-spec-pipeline.md`
- 實作 pattern 參考：`docs/tasks/2026-04-17-magi-extraction.md`（Magi extraction spec）
- 原始 Magi runs：
  - R1: `~/.orrery/magi/BFEBC206-C084-4479-8D9C-089BEE33F3AA.json`
  - R2: `~/.orrery/magi/0B70FACB-5A92-4356-B65D-FD9815CB356E.json`

### 注意事項

- spec 實作時若發現 D1–D16 有實作困難，應回本討論補 R3 或新增 follow-up 決策，不要在 spec 實作中默默偏離
- pickup skill 的 UX 邊界（D13）需要 UX 文件同步更新；spec 實作時一併規劃
- Q7–Q13 follow-up 問題進入實作前需先定案；建議實作 `verify` MVP 時優先處理 Q8（AST lint）、Q9（timeout 覆寫）、Q13（token budget）
