# Orrery

<p align="center">
  <img src="../assets/icon-1024x1024.png" alt="Orrery" width="256" height="256" />
</p>

[English](../README.md)

**Orrery 是 AI 工具的 runtime 環境管理工具。**

讓你在各自隔離的環境中執行 Claude Code、Codex CLI、Gemini CLI — 每個環境有獨立帳號與憑證 — 同時在切換帳號時保留完整的對話連續性。

> CLI 指令為小寫 `orrery`，產品名稱則大寫為 **Orrery**。

---

## 🧠 為什麼需要 Orrery？

使用 AI CLI 工具的日常往往很混亂：

- 切換帳號會打斷你的情境
- 對話歷史無法跨帳號保留
- 工具之間無法協調任務

Orrery 以一個概念解決這些問題：

> **隔離、可組合的 AI 環境**

每個環境有自己的認證憑證與設定。但 session — 對話歷史與專案上下文 — **預設共享**，讓你切換帳號後能直接接續對話。

---

## 🧩 核心概念

### Environment（環境）

AI 工具的獨立執行空間：

- 獨立的帳號與憑證
- 每個工具各自獨立的設定
- Per-shell 生效 — 其他終端機視窗不受影響

### Session（對話）

對話會跨環境持續保存。從 `work` 切到 `personal`，session 仍在 — `claude --resume` 可在切換帳號後接續同一個對話。

### MCP Delegation（委派）

在執行中的 session 內，將任務指派給特定環境。讓一個 Claude instance 可以委派工作給另一個跑在不同帳號下的 instance。

---

## 🧠 系統模型

Orrery 為 AI 工具引入了結構化的 runtime 模型：

- **Environment** → 隔離身份（帳號、憑證、設定）
- **Session** → 代表連續性（對話、上下文、記憶）
- **Delegation (MCP)** → 讓環境之間可以協調

這樣的設計分離讓你可以：

- 隔離身份，同時不失去上下文
- 跨帳號工作流程，不需重複設定
- 多 agent 協作，邊界明確

傳統工具的類比：

- `virtualenv` 隔離依賴套件
- `nvm` 隔離 runtime 版本

Orrery 把這個概念延伸到：

> **AI 的身份、上下文與協調**

---

## 🎯 使用情境

- 管理多個 AI 帳號（工作 / 個人 / 客戶）
- 同時跑多條 AI 工作流程，憑證互不干擾
- 建構跨環境的多 agent 系統
- 在不影響主帳號的前提下安全實驗

---

## 系統需求

- macOS 13+ 或 Linux
- bash 或 zsh

---

## 安裝

### 原生安裝（macOS、Linux、WSL）— 推薦

```bash
curl -fsSL https://offskylab.github.io/Orrery/install.sh | bash
```

自動偵測 OS/arch、下載對應的 release binary，安裝到 `/usr/local/bin/orrery`。同一個指令也能就地升級。

### Homebrew（macOS）

```bash
brew install OffskyLab/orrery/orrery
```

### Windows

Windows 上的 Claude Code 跑在 WSL 裡。請先以系統管理員身份開啟 PowerShell 啟用 WSL：

```powershell
wsl --install
```

接著在 WSL shell 裡執行上面的原生安裝指令。

### 從原始碼編譯

需要 Swift 6.0+。

```bash
git clone https://github.com/OffskyLab/Orrery.git
cd Orrery
swift build -c release
cp .build/release/orrery-bin /usr/local/bin/orrery-bin
orrery-bin setup   # 在 rc 檔寫入 `orrery` shell function
```

### Shell 整合

安裝後執行一次：

```bash
orrery setup
source ~/.orrery/activate.sh
```

`orrery setup` 會產生 `~/.orrery/activate.sh`、寫入 rc 檔（`~/.zshrc` 或 `~/.bashrc`），並將現有的工具設定移入 Orrery 管理。新開的 shell 會自動載入。

### 從 APT 遷移（Linux，v2.3.x 或更早）

如果你之前用 APT（`apt install orrery`）安裝 v2.3.x 或更早版本，`orrery update` 可能會回報 `already the newest version (2.3.x)` — APT repo 已不再更新，而且舊版的 update 流程沒有先跑 `apt update`。只要跑一次原生安裝指令就能完成遷移：

```bash
curl -fsSL https://offskylab.github.io/Orrery/install.sh | bash
```

這會移除 APT 管理的舊 binary、安裝新的 `orrery-bin`，並把 `orrery update` 切到原生安裝流程，之後的升級都會自動走新路徑。你可以順手清掉已失效的 APT 設定：

```bash
sudo rm /etc/apt/sources.list.d/orrery.list
sudo apt update
```

---

## 快速開始

```bash
# 建立環境（預設共享 session）
orrery create work --description "工作帳號"
orrery create personal --description "個人帳號"

# 互動式加入工具
orrery tools add -e work
orrery tools add -e personal

# 切換環境 — 對話歷史自動保留
orrery use work
claude                    # 開始對話
orrery use personal
claude --resume           # 無縫接續同一個 session

# 停用並返回原始系統設定
orrery use origin
```

---

## `origin` 環境

`origin` 是 Orrery 的保留名稱，代表你原始的系統環境。切換到 `origin` 等同離開 Orrery 管理 — 所有 Orrery 環境變數清除，工具回到系統全域設定，就像 Orrery 不存在一樣。

```bash
orrery use origin     # 返回系統設定
orrery deactivate     # 同上
```

### Origin 接管

`orrery setup` 會自動將現有的工具設定（`~/.claude/`、`~/.codex/`、`~/.gemini/`）移入 Orrery 的儲存空間（`~/.orrery/origin/`），並在原位建立 symlink。你的資料完整保留，只是搬進 Orrery 的管理範圍，方便同步與備份。

隨時可以還原：

```bash
orrery origin release           # 還原所有工具至原始位置
orrery origin release --claude  # 只還原 Claude
orrery origin status            # 查看目前狀態
```

完整移除 Orrery：

```bash
orrery uninstall    # 還原所有已接管的設定 + 移除 shell 整合
```

---

## Session 共享

預設所有環境共享 session 資料：

- 從 `work` 切到 `personal` → Claude 對話仍在
- 切換帳號後 `claude --resume` 可接續同一個 session
- 各環境仍有**獨立的認證憑證**

共享機制是把工具的 session 目錄（`projects/`、`sessions/`、`session-env/`）symlink 到 `~/.orrery/shared/`。

需要完全隔離 session 時（例如合規要求）：

```bash
orrery create secure-env --isolate-sessions
```

---

## 指令

### 環境管理

| 指令 | 說明 |
|---|---|
| `orrery create <name>` | 建立新環境（預設共享 session） |
| `orrery create <name> --clone <source>` | 從現有環境複製工具與環境變數 |
| `orrery create <name> --isolate-sessions` | 建立並完全隔離 session 的環境 |
| `orrery delete <name>` | 刪除環境 |
| `orrery rename <old> <new>` | 重新命名環境 |
| `orrery list` | 列出所有環境 |
| `orrery info [name]` | 顯示環境詳細資訊 |

### 切換

> 需要 shell 整合（`orrery setup`）

| 指令 | 說明 |
|---|---|
| `orrery use <name>` | 在當前 shell 啟用環境 |
| `orrery deactivate` | 停用並返回 origin |
| `orrery current` | 顯示目前啟用的環境名稱 |

### 設定

| 指令 | 說明 |
|---|---|
| `orrery tools add [-e <name>]` | 透過 wizard 加入工具 |
| `orrery tools remove [-e <name>]` | 移除工具 |
| `orrery set env <KEY> <VALUE> [-e <name>]` | 設定環境變數 |
| `orrery unset env <KEY> [-e <name>]` | 移除環境變數 |
| `orrery which <tool>` | 顯示工具的設定目錄路徑 |

### Session 管理

| 指令 | 說明 |
|---|---|
| `orrery sessions` | 列出當前專案的所有 session |
| `orrery resume [index]` | 接續 session（無 index 則開啟互動選單） |

### 跨工具

| 指令 | 說明 |
|---|---|
| `orrery run -e <name> <command>` | 在指定環境中執行指令 |
| `orrery delegate -e <name> "prompt"` | 委派任務給其他環境的 AI 工具 |
| `orrery delegate --resume <id\|index> "prompt"` | 接續工具原生 session（UUID、短前綴、或 `orrery sessions` 中的編號） |
| `orrery delegate --session [<name>]` | 開啟託管 session 選單（或 resume 指定的 mapping） |
| `orrery magi "<topic>"` | 啟動多模型討論並達成共識 |
| `orrery spec <discussion.md>` | 從討論報告產出結構化的實作規格 |
| `orrery spec-run --mode {verify\|implement\|status} <spec.md>` | 驗證 spec、交給 delegate agent 實作、或查詢實作狀態 |

### 多模型討論（Magi）

靈感來自《新世紀福音戰士》的 MAGI 系統——三台超級電腦各自獨立判斷後達成多數決。`orrery magi` 讓多個 AI 模型針對同一議題互相對話、反駁，經過多輪討論後產出結構化的共識報告。

```bash
# 所有已安裝的 tool 參與，3 輪討論（預設）
orrery magi "新 API 該用 REST 還是 GraphQL？"

# 只讓 Claude + Codex 參與，1 輪
orrery magi --claude --codex --rounds 1 "tabs vs spaces"

# 多個子議題（分號分隔）
orrery magi "效能考量; 開發體驗; 維護成本"

# 將報告存檔
orrery magi --output report.md "該不該遷移到 Swift 6？"
```

| 選項 | 說明 |
|---|---|
| `--claude` / `--codex` / `--gemini` | 選擇參與的工具（預設：所有已安裝） |
| `--rounds <N>` | 最大討論輪數（預設：3） |
| `--output <path>` | 將 markdown 報告輸出至檔案 |
| `-e <name>` | 使用指定環境 |

至少需要 2 個已安裝的工具。每輪討論中，模型能看到自己前輪的完整推理過程，以及其他參與者的結構化立場摘要。最終共識採用確定性多數決：`agreed`（全數同意）、`majority`（≥2 同意）、`disputed`（≥2 反對）、`pending`（資料不足）。

討論紀錄以 JSON 格式存於 `~/.orrery/magi/`，可供日後查閱。

### Delegate Session 接續

`orrery delegate` 不只能新開 session，也能接續工具原生的對話歷史。

```bash
# 用 native session UUID 短前綴接續
orrery delegate -e work --resume 4f2c "繼續剛剛的 review"

# 用 `orrery sessions` 列出的編號接續
orrery delegate -e work --resume 1 "..."

# 開啟跨工具、跨環境的託管 session 選單
orrery delegate --session

# 直接接續指定名稱的 mapping（自動推導 tool）
orrery delegate --session-name api-redesign "遷移計畫怎麼安排？"
```

| 選項 | 說明 |
|---|---|
| `--resume <id\|index>` | 原生 session 接續 — UUID、短前綴、或 `orrery sessions` 中以 1 為基的編號 |
| `--session [<name>]` | 開啟託管 session 選單；給 `<name>` 則直接 resume 該 mapping |
| `--session-name <name>` | 直接 resume 指定名稱的 mapping（等價 `--session <name>`） |

具名 mapping 存於 `~/.orrery/sessions/mappings.json`，可透過 [orrery-sync](https://github.com/OffskyLab/orrery-sync) 跨機器同步。三個 flag 互斥。

### Spec Pipeline（規格流水線）

把多模型討論轉成可實作程式碼的三階段流程，跟 `orrery magi` 自然銜接：discuss → spec → verify → implement → poll。

```bash
# 1. 討論問題並輸出共識報告
orrery magi --output discussion.md "REST 該不該換成 GraphQL？"

# 2. 從討論產出結構化規格
orrery spec discussion.md --output spec.md

# 3. Dry-run 驗收條件（沙盒安全）
orrery spec-run --mode verify spec.md

# 4. 交給 delegate agent 在 detached 子程序實作
orrery spec-run --mode implement spec.md
# → 立即回傳 session_id；delegate 在背景持續執行

# 5. 輪詢直到完成
orrery spec-run --mode status --session-id <id>
```

| Mode | 行為 |
|---|---|
| `verify` | 解析 `## 驗收標準` + `## 介面合約` 並執行驗收命令。預設 dry-run；`--execute` 真的執行；`--strict-policy` 在 policy_blocked 時失敗。受沙盒政策保護（每命令 60s、整體 600s、單命令 stdout 1MB）。 |
| `implement` | 在 detached 子程序中啟動 delegate agent，依 spec 的 `## 介面合約` / `## 改動檔案` / `## 實作步驟` / `## 驗收標準` 寫程式。立即回傳 `session_id` + `status: "running"`；wrapper shell 處理逾時、log 重導向與終結。 |
| `status` | 讀 `~/.orrery/spec-runs/{id}.json` 持久化狀態，回傳 `status` + `progress`；終態時含完整結果。`--include-log` 附上 progress jsonl 尾端、`--since-timestamp` 做增量輪詢。 |

四個必要小節（`介面合約` / `改動檔案` / `實作步驟` / `驗收標準`）會在啟動子程序前先做靜態檢查，格式錯的 spec 會直接被擋下。

### Origin 管理

| 指令 | 說明 |
|---|---|
| `orrery origin status` | 顯示哪些工具由 Orrery 管理 |
| `orrery origin takeover` | 將工具設定移入 Orrery 儲存空間 |
| `orrery origin release` | 將工具設定還原至原始位置 |
| `orrery uninstall` | 移除 shell 整合並還原所有已接管的設定 |

### Shell 整合

| 指令 | 說明 |
|---|---|
| `orrery setup` | 安裝 shell 整合（冪等） |
| `orrery update` | 更新 Orrery 至最新版本 |

---

## MCP 整合

Orrery 透過 [MCP](https://modelcontextprotocol.io/) 整合 Claude Code、Codex CLI 和 Gemini CLI。

```bash
orrery mcp setup
```

一行指令註冊 MCP server 並安裝 slash commands。

**內建 MCP 工具**（由 `orrery-bin` in-process 處理）：

| 工具 | 說明 |
|---|---|
| `orrery_delegate` | 委派任務給其他帳號的 AI 工具 |
| `orrery_list` | 列出所有環境 |
| `orrery_sessions` | 列出當前專案的 session |
| `orrery_current` | 查看目前啟用的環境 |
| `orrery_memory_read` | 讀取共享專案記憶 |
| `orrery_memory_write` | 寫入共享專案記憶 |
| `orrery_spec_status` | 輪詢 `orrery_spec_implement` session 狀態（直接讀本機 state file） |

**Sidecar MCP 工具**（裝了選用的 `orrery-magi` sidecar 才會註冊；`install.sh` 與 Homebrew 會自動裝）：

| 工具 | 說明 |
|---|---|
| `orrery_magi` | 多模型討論 → consensus 報告 |
| `orrery_spec` | 從討論產出 spec |
| `orrery_spec_verify` | 驗證 spec 的驗收條件 |
| `orrery_spec_implement` | 將 spec 交給 detached delegate agent 實作 |

當 sidecar 不存在或版本較舊時會優雅降級——`orrery_magi` 透過 single-schema fallback 仍可使用，spec 系列工具則不會註冊。

**`orrery mcp setup` 寫入的 slash commands**（在跑過 mcp setup 的專案中可用）：

| Slash 指令 | 對應功能 |
|---|---|
| `/orrery:delegate` | `orrery_delegate` MCP 工具（含環境提示） |
| `/orrery:sessions` | `orrery sessions` |
| `/orrery:resume` | `orrery resume <index>` |
| `/orrery:phantom` | `_phantom-trigger`，不離開 session 切換環境 |
| `/orrery:magi` | `orrery_magi`（含 `/grill-me` pre-flight 提示，給產品/scope 議題用） |
| `/orrery:spec` | `orrery_spec` |
| `/orrery:spec-verify` | `orrery_spec_verify` |
| `/orrery:spec-implement` | `orrery_spec_implement` |
| `/orrery:spec-status` | `orrery_spec_status` |

**共享記憶**：所有 AI 工具讀寫同一份 `MEMORY.md`。Claude 儲存的知識，Codex 和 Gemini 也能存取，反之亦然。

**外部記憶儲存**：可將記憶重導向到任意目錄，例如 Obsidian vault：

```bash
orrery memory storage ~/Documents/my-wiki/orrery
orrery memory storage --reset   # 還原預設路徑
```

---

## P2P 記憶同步

透過 [orrery-sync](https://github.com/OffskyLab/orrery-sync) 在多台機器或團隊成員之間即時同步專案記憶。

```bash
# 桌機
orrery sync daemon --port 9527

# 筆電（透過 Bonjour 自動探索）
orrery sync daemon --port 9528
```

跨網路同步時，在 VPS 上執行 rendezvous server：

```bash
orrery sync daemon --port 9527 --rendezvous rv.example.com:9600
```

只有專案記憶會同步 — session 保留在本機。記憶變更以無衝突片段追蹤，由 AI agent 在 session 開始時整合。

| 指令 | 說明 |
|---|---|
| `orrery sync daemon` | 啟動同步 daemon |
| `orrery sync status` | 顯示 daemon 與 peer 狀態 |
| `orrery sync team create <name>` | 建立新團隊 |
| `orrery sync team invite` | 產生邀請碼 |
| `orrery sync team join <code>` | 加入團隊 |

---

## 儲存結構

```
~/.orrery/
  current                  # 目前啟用的環境名稱
  origin/                  # 原始工具設定（orrery setup 接管後）
    claude/                #   ~/.claude/ 的 symlink 指向此處
    codex/
    gemini/
  shared/                  # 跨環境共享的 session 資料
    claude/
      projects/            #   各專案的對話歷史
      sessions/            #   session 中繼資料
  envs/
    <UUID>/
      env.json             #   中繼資料：工具、環境變數、時間戳
      claude/              #   CLAUDE_CONFIG_DIR 指向此處
        .claude.json       #   認證憑證（各環境獨立）
        projects/  →  ~/.orrery/shared/claude/projects
        sessions/  →  ~/.orrery/shared/claude/sessions
      codex/               #   CODEX_CONFIG_DIR 指向此處
```

設定 `ORRERY_HOME` 環境變數可使用自訂路徑。

---

## 🚀 願景

> **AI 原生工作流程的「virtualenv」**

隨著 AI 工具成為核心基礎設施，團隊需要和開發環境一樣的隔離性、可攜性與可組合性。Orrery 把這層能力帶到 AI 這一層。

---

## 授權

Apache 2.0
