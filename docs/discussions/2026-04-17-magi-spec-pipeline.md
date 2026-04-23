# 討論：Magi 討論結果 → Spec 自動化管線

**日期**：2026-04-17
**參與者**：Claude (Verifier), Codex (Pragmatist), Gemini (Strategist)
**Magi Run ID**：2202BC21-7F22-42A8-9D71-2C8AA67D4F6A

## 背景

目前 `/write-spec` 是本地 skill，只有本機能用。需要將「討論 → spec」的能力產品化到 Orrery CLI 中，讓所有使用者都能用。

## 共識

### 1. 子命令設計 [全數同意]

- 建立獨立的 `orrery spec` 子命令，接受任意 Markdown 輸入（不限 magi 產出）
- `orrery magi --spec` 作為 convenience wrapper，內部先跑 magi 再呼叫 spec
- 兩者解耦，各自職責單純

### 2. 轉換策略：需要中間結構化層 [全數同意]

流程：共識報告 markdown → 結構化 extraction (IR) → spec render

中間層提高可驗證性與除錯性，不可跳過直接端到端生成。

### 3. Spec 格式內建為預設 [全數同意]

8 段 contract-first 格式作為 opinionated default。

## 使用者決策（分歧解決）

### IR 可見性 → Internal（Codex 方案）

- IR 為 internal，預設不暴露給使用者
- 透過 `--debug` 或 `--emit-brief` 選擇性輸出
- 理由：信任 LLM 的萃取能力，不需要多一個人工檢查步驟

### 格式可配置 → 平台路線（混合方案）

- 內建 profiles 作為預設選項（如 `default`, `minimal` 等）
- 同時支援自訂 template，使用者可加入自己的 template 到系統中
- 選用時透過參數指定對應的 template
- 理由：定位為平台，既有主見又有彈性

### 雙模型 Review → Opt-in（Codex 方案）

- 預設單模型生成 spec
- `--review` flag opt-in 觸發第二個模型做驗證
- 理由：大多時候單模型夠好，重要 spec 才需要額外 review，節省成本與時間

## Open Questions（待 spec 階段細化）

- 中間 IR 的 JSON schema 設計
- 內建 profiles 有哪些？各自差異？
- 自訂 template 的存放路徑與格式規範
- `orrery spec` 除了 magi 報告還需支援哪些輸入格式
- `--review` 時由哪個模型做 review、review 的輸出格式

## 依賴

- `2026-04-16-magi-mcp-slash-command`（已完成）
- `2026-04-16-magi-roles-and-spec-pipeline`（角色機制，進行中）
