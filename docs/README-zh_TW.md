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

從 **account（帳號）** 開始 — 多數人這層就夠了。只有當特定情境需要完全隔離的設定空間時，才需要動到 **sandbox**。

### Account（帳號）

工具的**身份**：Orrery 用來登入的憑證。帳號集中在共享 pool 中，註冊一次即可隨時切換，用 `orrery use` 切。這是你日常會碰的層。

### Sandbox（沙盒）_（進階）_

可選的**隔離層**：獨立的 memory、sessions、env vars，蓋在 account 之上。多數人從來不需要 — 客戶或專案需要獨立設定空間時再用。`orrery enter` 進入、`orrery exit` 離開。

### Session（對話）

代表**連續性**：對話歷史與專案 context。預設跨帳號切換時保留共享 — 切完帳號後 `claude --resume` 就能接續。

### Phantom 模式

`orrery run claude` 啟動 Claude 時會帶著一個 phantom supervisor。在那個 Claude session 裡，`/orrery:phantom` slash command 可以**不結束對話**就切換帳號或 sandbox — Claude 退出後 supervisor 帶著新設定與 `--resume` 把它叫回來。詳見下方 [Phantom 模式](#phantom-模式) 。

### MCP Delegation（委派）

在執行中的 session 內，將任務指派給特定帳號或 sandbox。讓一個 Claude instance 可以委派工作給另一個跑在不同身份下的 instance。

---

## 🧠 系統模型

Orrery 為 AI 工具引入了結構化的 runtime 模型：

- **Account** → 隔離身份（每個工具的憑證）
- **Sandbox** _（可選）_ → 隔離設定（memory、sessions、env vars）
- **Session** → 代表連續性（對話、上下文、記憶）
- **Phantom** → session 中切換而不打斷對話
- **Delegation (MCP)** → 讓帳號與 sandbox 之間可以協調

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
# 把帳號註冊到共享 pool（每個帳號做一次）
orrery add --claude --name work
orrery add --claude --name personal

# 切換目前的 Claude 帳號 — pin 是 per-shell 的
orrery use work --claude    # 也可只打 `orrery use work`（預設工具是 claude）
claude                       # 用 'work' 帳號開始對話

# 切到另一個帳號 — session 預設共享
orrery use personal --claude
claude --resume              # 無縫接續同一個 session
```

<p align="center">
  <img src="../assets/demo/use.gif" alt="orrery use 切換 Claude 帳號" width="640" />
</p>

---

## Phantom 模式

用 `orrery run claude` 啟動 Claude，會有一個 supervisor 在旁邊守著。在那個 Claude 裡，`orrery mcp setup` 安裝的 `/orrery:phantom` slash command 可以**不重啟對話**直接換 account 或 sandbox：

```text
/orrery:phantom personal           # 把 claude 帳號切到 'personal'
/orrery:phantom codex work         # 切 codex 帳號
/orrery:phantom sandbox client-a   # 切到 sandbox
```

Claude 退出後 supervisor 帶著新的 account/sandbox 與 `--resume` 把它叫回來，對話無感接續。

<p align="center">
  <img src="../assets/demo/phatom.gif" alt="/orrery:phantom session 中切帳號示範" width="640" />
</p>

Phantom 是 `orrery run claude` 的**預設**模式。若要關掉（單次執行、不帶 supervisor）：

```bash
orrery run --non-phantom claude
```

非 Claude 工具一律單次執行：

```bash
orrery run codex             # 在目前 pin 的 codex 帳號下單次執行
orrery run npm install       # 在目前 sandbox 內跑任意指令
```

---

## Sandboxes _（可選）_

Sandbox 是完整的設定隔離層：獨立的 memory、sessions、env vars，以及各工具的 config dir。當客戶或專案需要自己一塊牆內空間時用得到。如果只需要切帳號，可以完全跳過 sandbox。

```bash
orrery sandbox create client-a     # 互動式 wizard：選工具、memory 模式、clone 來源
orrery sandbox list                # 列出所有 sandbox
orrery sandbox info client-a       # 詳細狀態（工具、帳號、env vars、memory）

orrery enter client-a              # 進入 sandbox（per-shell）
claude                              # 使用 sandbox 內 pin 的帳號與設定
orrery exit                         # 返回 origin
```

<p align="center">
  <img src="../assets/demo/sandbox-create.gif" alt="orrery sandbox create wizard" width="480" />
  <img src="../assets/demo/sandbox-enter.gif" alt="orrery enter sandbox" width="480" />
</p>

Sandbox 級的 env vars 用 `orrery sandbox set-env` / `unset-env`：

```bash
orrery sandbox set-env API_BASE https://staging.example.com --sandbox client-a
orrery sandbox unset-env API_BASE --sandbox client-a
```

---

## `origin` 基準

`origin` 是你的預設設定 — 在進入任何 sandbox 前的狀態。第一次 `orrery setup` 時，現有的工具設定（`~/.claude/`、`~/.codex/`、`~/.gemini/`）會被移入 `~/.orrery/origin/`，原位變成 symlink。你的資料完整保留，只是搬進 Orrery 的管理範圍。

```bash
orrery exit                  # 從任一 sandbox 返回 origin
orrery sandbox info origin   # 查看 origin 狀態（memory、sessions、tools）
```

`orrery enter origin` 會被拒絕並指引到 `exit`：origin 是「沒進 sandbox」的狀態，不是一個 sandbox。

完整移除 Orrery（釋放所有設定 + 移除 shell 整合）：

```bash
orrery uninstall
```

---

## Session 共享

預設所有 sandbox 共享 session 資料：

- 從 `work` 切到 `personal` → Claude 對話仍在
- 切換帳號後 `claude --resume` 可接續同一個 session
- 各 sandbox 仍有**獨立的認證憑證**

共享機制是把工具的 session 目錄（`projects/`、`sessions/`、`session-env/`）symlink 到 `~/.orrery/shared/`。

需要在 sandbox 內完全隔離 session 時（例如合規要求），在 `orrery sandbox create` wizard 中選 **isolate**，或之後用 `orrery sandbox memory isolate` / `share` 切換。

---

## 指令

### 環境管理

### Accounts

| 指令 | 說明 |
|---|---|
| `orrery add [--claude\|--codex\|--gemini] --name <name>` | 註冊新帳號到 pool（並執行該工具的 login flow） |
| `orrery list [--claude\|--codex\|--gemini]` | 列出帳號（依工具過濾或全部） |
| `orrery show` | 顯示目前 pin 的帳號與啟用中的 sandbox |
| `orrery use [--claude\|--codex\|--gemini] <name>` | 將指定帳號 pin 為該工具的當前帳號（預設工具：claude） |
| `orrery remove [--claude\|--codex\|--gemini] <name>` | 從 pool 移除帳號 |

### Sandboxes

| 指令 | 說明 |
|---|---|
| `orrery sandbox create <name>` | 互動式 wizard 建立 sandbox |
| `orrery sandbox list` | 列出所有 sandbox |
| `orrery sandbox info [name]` | 顯示 sandbox 詳細資訊 |
| `orrery sandbox delete <name>` | 刪除 sandbox |
| `orrery sandbox rename <old> <new>` | 重新命名 sandbox |
| `orrery sandbox set-env <KEY> <VALUE> [-s <name>]` | 設定 sandbox 等級的 env var |
| `orrery sandbox unset-env <KEY> [-s <name>]` | 移除 sandbox 等級的 env var |
| `orrery sandbox current` | 顯示目前 sandbox 名稱（或 `origin`） |
| `orrery sandbox memory {isolate\|share\|info\|storage\|export}` | 管理 memory 模式與儲存 |
| `orrery sandbox sync ...` | sandbox 同步相關操作 |

### Sandbox 狀態（per-shell）

> 需要 shell 整合（`orrery setup`）

| 指令 | 說明 |
|---|---|
| `orrery enter <name>` | 在當前 shell 進入 sandbox |
| `orrery exit` | 返回 origin |

### 設定

| 指令 | 說明 |
|---|---|
| `orrery tools add [-e <name>]` | 透過 wizard 在 sandbox 中加入工具 |
| `orrery tools remove [-e <name>]` | 從 sandbox 移除工具 |
| `orrery which <tool>` | 顯示工具的設定目錄路徑 |

### Session 管理

| 指令 | 說明 |
|---|---|
| `orrery sessions [--claude\|--codex\|--gemini]` | 列出當前專案的所有 session |
| `orrery resume [--claude\|--codex\|--gemini] [index]` | 接續 session（無 index 則開啟互動選單） |

### 跨工具

| 指令 | 說明 |
|---|---|
| `orrery run [-e <name>] claude` | 透過 phantom supervisor 啟動 Claude（預設）— 啟用 `/orrery:phantom` |
| `orrery run --non-phantom claude` | 單次執行 Claude（無 supervisor） |
| `orrery run [-e <name>] <command>` | 在指定（或當前）sandbox 內執行任意指令 |
| `orrery delegate -e <name> "prompt"` | 委派任務給其他 sandbox 的 AI 工具 |
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
| `-e <name>` | 使用指定 sandbox |

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

### Shell 整合

| 指令 | 說明 |
|---|---|
| `orrery setup` | 安裝 shell 整合（冪等）— 第一次執行會把工具設定移入 `~/.orrery/origin/` |
| `orrery update` | 更新 Orrery 至最新版本 |
| `orrery uninstall` | 還原所有已接管的設定並移除 shell 整合 |

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
| `orrery_list` | 列出 accounts 與 sandboxes |
| `orrery_sessions` | 列出當前專案的 session |
| `orrery_current` | 查看當前 sandbox（或 `origin`） |
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

**Sidecar 缺失或版本不符的處理：**

- **MCP 路徑**——優雅降級。若 `orrery-magi` 不存在，`orrery-bin mcp-server` 仍會啟動並暴露上面 7 個內建工具；4 個 sidecar 工具不會註冊，stderr 會印出安裝提示。若 sidecar 較舊（v1.0.0，沒有 `features.multi_tool_schema`），會 fallback 到 legacy single-schema 路徑，sidecar 那組裡只有 `orrery_magi` 會註冊。
- **CLI 路徑**——hard-fail 並提示安裝。`orrery magi` / `orrery spec` / `orrery spec-run` 一律需要一個可解析的 v1.1.0+ sidecar；找不到就印安裝提示並 exit non-zero。（`install.sh` 和 Homebrew 都鎖了相容版本，所以這只會發生在手動降版的情況。）

**`orrery mcp setup` 寫入的 slash commands**（在跑過 mcp setup 的專案中可用）：

| Slash 指令 | 對應功能 |
|---|---|
| `/orrery:delegate` | `orrery_delegate` MCP 工具（含環境提示） |
| `/orrery:sessions` | `orrery sessions` |
| `/orrery:resume` | `orrery resume <index>` |
| `/orrery:phantom` | 不離開 session 切換 account / sandbox — 詳見上方 [Phantom 模式](#phantom-模式) |
| `/orrery:magi` | `orrery_magi`（含 `/grill-me` pre-flight 提示，給產品/scope 議題用） |
| `/orrery:spec` | `orrery_spec` |
| `/orrery:spec-verify` | `orrery_spec_verify` |
| `/orrery:spec-implement` | `orrery_spec_implement` |
| `/orrery:spec-status` | `orrery_spec_status` |

**共享記憶**：所有 AI 工具讀寫同一份 `MEMORY.md`。Claude 儲存的知識，Codex 和 Gemini 也能存取，反之亦然。

**外部記憶儲存**：可將記憶重導向到任意目錄，例如 Obsidian vault：

```bash
orrery sandbox memory storage ~/Documents/my-wiki/orrery
orrery sandbox memory storage --reset   # 還原預設路徑
```

---

## P2P 記憶同步

透過 [orrery-sync](https://github.com/OffskyLab/orrery-sync) 在多台機器或團隊成員之間即時同步專案記憶。

```bash
# 桌機
orrery sandbox sync daemon --port 9527

# 筆電（透過 Bonjour 自動探索）
orrery sandbox sync daemon --port 9528
```

跨網路同步時，在 VPS 上執行 rendezvous server：

```bash
orrery sandbox sync daemon --port 9527 --rendezvous rv.example.com:9600
```

只有專案記憶會同步 — session 保留在本機。記憶變更以無衝突片段追蹤，由 AI agent 在 session 開始時整合。

| 指令 | 說明 |
|---|---|
| `orrery sandbox sync daemon` | 啟動同步 daemon |
| `orrery sandbox sync status` | 顯示 daemon 與 peer 狀態 |
| `orrery sandbox sync team create <name>` | 建立新團隊 |
| `orrery sandbox sync team invite` | 產生邀請碼 |
| `orrery sandbox sync team join <code>` | 加入團隊 |

---

## 儲存結構

```
~/.orrery/
  current                  # 目前啟用的 sandbox 名稱（空 / 未設定 = origin）
  origin/                  # 原始工具設定（orrery setup 接管後）
    claude/                #   ~/.claude/ 的 symlink 指向此處
    codex/
    gemini/
  accounts/                # 共享帳號 pool
    claude/
      <uuid>/              #   每個註冊的 Claude 帳號一個目錄
    codex/
    gemini/
  shared/                  # 跨 sandbox 共享的 session 資料
    claude/
      projects/            #   各專案的對話歷史
      sessions/            #   session 中繼資料
  envs/                    # sandbox 儲存（on-disk 目錄名沿用 v2）
    <UUID>/
      env.json             #   中繼資料：工具、pin 的帳號、環境變數
      claude/              #   啟用此 sandbox 時 CLAUDE_CONFIG_DIR 指向此處
        .claude.json       #   pin 的帳號被 materialize 的憑證
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
