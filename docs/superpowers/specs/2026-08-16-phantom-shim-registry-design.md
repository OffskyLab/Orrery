# Phantom 免 `orrery run`：supervisor loop 移入 `claude()` shim + per-supervisor sentinel + registry

日期:2026-08-16
狀態:設計待實作
階段:Phase 1(claude only);Phase 2 抽 framework 支援三工具,見文末

## 背景 / 目標

現在 in-place 切帳號(`orrery phantom <name>`)只有在 claude 是用 `orrery run claude` 啟動時才能用。直接打 `claude` 就會得到:

```
Error: Not running under phantom supervision. Launch claude with 'orrery run claude' ...
```

原因是 supervisor loop 寫在 `orrery()` shell function 的 `run)` 分支裡(`ShellFunctionGenerator.swift:86-118`),而 `orrery phantom` 靠 loop 匯出的 `ORRERY_PHANTOM_SHELL_PID` 環境變數判斷「有沒有 supervisor 可以重啟我」。

**目標:讓裸 `claude` 預設就被 supervise**,使用者不必記得加 `orrery run`。

### 為什麼不用 XPC / tmux(已評估,不採用)

- **XPC** 不是行程探索 API,是連到已在 launchd 註冊的 service;claude 沒有註冊端點。而且 launchd 起的行程**沒有 controlling terminal**,對 TUI 無用。真要枚舉行程用 `sysctl KERN_PROC` 即可(現有 `readProcessInfo` 已在用),不需要特權。
- **tmux** 能買到「終端機關掉 session 還在」與「supervisor 可從外部定址」,但代價是新硬依賴(macOS 預設無)、scrollback/滑鼠行為改變、true color 需另設。而「可從外部定址」用 registry 檔就能達成,零依賴。`respawn-pane` 另有 pane root 被替換的生命週期問題。結論:tmux 留待日後選配,不進本設計。

### 這個改動會放大兩個既有缺陷,必須一併修

A 的本質是讓「同時開多個 claude」從刻意行為變成日常,以下兩個既有問題會隨之浮現:

1. **sentinel 是全域單一檔案** — `PhantomSupport.swift:50` 是 `~/.orrery/.phantom-sentinel`,shell 端亦同。兩個 claude 同時跑,A 寫的 sentinel 會被 B 的 loop 讀走,B 於是套用 A 的目標帳號並 `--resume` 到 A 的對話。**必須改成 per-supervisor。**
2. **session id 是猜的** — `findCurrentClaudeSessionId()`(`PhantomSupport.swift:97`)掃 `projects/<cwd-key>/` 中 mtime 最新的 `.jsonl`。同一專案有兩個 claude 時,它回答的是「最近寫過的是誰」,而正確答案是「這個 claude 正在寫的是誰」。**改用 `SessionStart` hook 取得權威值。**

## 範圍

全部在 orrery repo。Phase 1 只做 claude。

**會動到:**

- `Sources/OrreryCore/Shell/ShellFunctionGenerator.swift` — `claude()` shim 接手 loop;`orrery run` 的 claude 分支退化
- `Sources/OrreryCore/Commands/PhantomSupport.swift` — sentinel 路徑、claude pid 解析、session id 來源
- `Sources/OrreryCore/Commands/PhantomAccountTriggerCommand.swift` — 定址改走 registry,加消歧義
- `Sources/OrreryCore/Commands/PrepareClaudeLaunchCommand.swift` — 多裝一個 `SessionStart` hook
- `Sources/OrreryCore/Commands/ShowCommand.swift` — 列出存活的 supervised session
- `Sources/OrreryCore/Commands/UninstallCommand.swift` — 清理 `~/.orrery/phantom/`
- 新增:`PhantomRegistry`(registry 讀寫 + 存活判定)、`_phantom-begin` / `_phantom-next` / `_phantom-end` 三個內部 subcommand、`OrreryClaudeSessionHookCommand`(SessionStart/SessionEnd hook 端點)

**不動:** 憑證 materialize / syncBack、workspace / pin 的語意、`orrery use` 的行為。

## 詳細設計

### 1. shell / Swift 的邊界

**限制:loop 必須留在 shell。** shell 直接 fork/exec claude,controlling TTY 自然繼承;換成 Swift 當 parent 就要自己接 PTY(`ShellFunctionGenerator.swift:36-38` 的既有註解已載明)。

**原則:`ShellFunctionGenerator` 產出的內容會被寫進使用者的 `~/.zshrc`,是版本化契約。** 那裡的 bug 需要使用者重跑 `orrery setup` 才會修正,舊 code 會在他們的 rc 檔裡繼續跑。因此 shell 只保留最小骨架,所有會變動的邏輯放在 `orrery-bin` 後面(可測試、改版免重裝)。

```sh
claude() {
  # 快速直通:已被 supervise(巢狀)、在 claude 的 Bash tool 內、或使用者明確關閉。
  # 這裡只讀環境變數,不做任何啟發式判斷 — 啟發式全在 _phantom-begin(見 3)。
  if [ -n "${ORRERY_PHANTOM_ID:-}" ] || [ -n "${CLAUDECODE:-}" ] \
     || [ -n "${ORRERY_NO_PHANTOM:-}" ]; then
    _orrery_claude_launch "$@"; return $?
  fi

  local _spec _args=("$@")
  _spec=$(command orrery-bin _phantom-begin --tool claude --supervisor-pid $$ -- "$@") || {
    _orrery_claude_launch "$@"; return $?    # Swift 判定不該 supervise
  }
  eval "$_spec"                              # export ORRERY_PHANTOM_ID / ORRERY_PHANTOM_DIR

  while true; do
    _orrery_claude_launch "${_args[@]}"
    local _next
    _next=$(command orrery-bin _phantom-next --id "$ORRERY_PHANTOM_ID") || break
    eval "set -- $_next"; _args=("$@")
  done

  command orrery-bin _phantom-end --id "$ORRERY_PHANTOM_ID"
  unset ORRERY_PHANTOM_ID ORRERY_PHANTOM_DIR
}
```

`_orrery_claude_launch` 是把**現行 `claude()` 的內容原封不動**抽出來的 helper — 三個分支(account dir / origin `--links-only` / 直通)、`_prepare-claude-launch`、`command claude "$@"`、`_capture-claude-exit` 都不變。抽出來的目的有二:

1. loop **每一輪**都必須重跑 prepare/capture(每次 relaunch 都可能換了 account dir)
2. 直通路徑與 supervise 路徑共用同一段啟動邏輯,不會分岔

**`--supervisor-pid $$` 不可省略。** `_phantom-begin` 是在 `$(...)` 命令替換中執行的,而命令替換會 fork subshell,因此 `getppid()` 取到的可能是隨即消失的 subshell 而非互動 shell。`$$` 在 bash/zsh 的 subshell 中仍為原始 shell 的 pid,必須由 shell 明確傳入(現行 loop 的 `export ORRERY_PHANTOM_SHELL_PID=$$` 同理)。

### 2. 三個 subcommand 的契約

| 指令 | 責任 | 輸出 / 結束碼 |
|---|---|---|
| `_phantom-begin --tool <t> --supervisor-pid <pid> -- <args...>` | 判定是否該 supervise;配 id、建 registry 目錄、寫 `meta.json` | 該 supervise → stdout 印可 `eval` 的 export 行,exit 0;不該 → exit 1(shell 直通) |
| `_phantom-next --id <id>` | 讀該 id 的 sentinel。無 → exit 1(跳出 loop)。有 → 套用 `orrery use`、解析新 session id、更新 `meta.json`、刪除 sentinel | 印出下一輪的 argv(已 shell-quote),exit 0 |
| `_phantom-end --id <id>` | 移除整個 `<id>/` 目錄 | exit 0(best-effort) |

`_phantom-next` 印出的 argv 一律是 `--resume <session-id>`,或 session id 不明時印空字串。使用者原本的旗標**不沿用**(可能含已失效的 `--resume`),與現行 loop 行為一致。

### 3. 哪些 `claude` 調用不該被 supervise

shell 只讀三個環境變數做快速直通(見 1),**所有啟發式判斷**都在 `_phantom-begin` 的 Swift 側(純函式、可測)。回傳「不該 supervise」的條件:

- `stdin` 或 `stdout` 不是 tty(非互動、被導管)
- 參數含 `-p` / `--print`(單發非互動模式)
- 第一個非旗標參數屬於非 session 子指令集合:`mcp`、`update`、`doctor`、`config`、`install`、`plugin`、`setup-token`、`migrate-installer`

集合寫成 Swift 常數,新增項目不需要使用者重跑 `orrery setup`。

### 4. Registry

```
~/.orrery/phantom/<supervisor-pid>/
    meta.json
    sentinel        # 原本的 shell-sourceable 格式,不再全域共用
```

id 用 supervisor pid。pid 會被作業系統回收,故 `meta.json` 另存 supervisor 的**行程啟動時間**(`kinfo_proc.kp_proc.p_starttime`;`readProcessInfo` 已在讀 `kinfo_proc`)。**存活判定 = `kill(pid,0)` 成功 且 啟動時間吻合** — 標準 pidfile 防回收做法,crash 遺留的目錄不會被誤認為新行程。

```json
{
  "schema": 1,
  "supervisor_pid": 51234,
  "supervisor_started_at": 1755300000.123,
  "tool": "claude",
  "tty": "/dev/ttys004",
  "cwd": "/Users/gradyzhuo/Dropbox/Work/OpenSource/orrery",
  "workspace": "origin",
  "account": "work",
  "session_id": "abc-123",
  "session_id_source": "hook",
  "updated_at": 1755300042.0
}
```

`session_id_source` 為 `hook`(權威)或 `probe`(mtime 探測退路)。

**清理:** 任何一次讀取 registry 時,順手刪除判定為死亡的 entry。不需要獨立的 GC 流程。`orrery uninstall` 移除整個 `~/.orrery/phantom/`。

### 5. 不儲存 claude 的 pid

claude 每輪都換一個,存了就得同步維護,且 `_phantom-begin` 執行時 claude 尚未啟動。改為**從 supervisor 往下找** — 這是現有 `resolveClaudePid` 的鏡像,可複用同一組 `readProcessInfo` 與 comm 判斷。supervisor 的 loop 是前景執行 claude,同一時間只有一個相關子行程,往下找是穩定的。

從 claude 內部觸發時仍走現有的**往上走**路徑(更短、已測過);往下找只用於 out-of-band。

`meta.json` 的 `tty` 欄位保留一條交叉驗證的路(對該 tty 做 `tcgetpgrp()` 取得當下前景 process group),**本階段不實作**,欄位先留著。

### 6. Session id:`SessionStart` / `SessionEnd` hook

沿用既有機制安裝,不新建生命週期:

- `SettingsJSONPatcher`(`SettingsJSONPatcher.swift:145` 已處理 hook-matcher 比對)保證 idempotent + additive,不會產生重複項,也不動使用者自己的 hook。
- `ClaudeAuthSuccessHookInstaller` 已是「對 account dir 的 settings.json 裝 hook」的範本。
- `PrepareClaudeLaunchCommand` **每次啟動**都對當前 account dir 執行,所以「換帳號後要重新 patch」自動成立。

新增 `SessionStart` hook,command 指向 `orrery-bin _claude-session-hook`。該 hook:

1. 從 stdin 讀 hook 輸入 JSON,取 `session_id`
2. 從自身環境讀 `ORRERY_PHANTOM_ID`(由 shim export,經 claude 繼承而來)
3. 寫入對應 registry entry 的 `session_id`,並將 `session_id_source` 設為 `hook`

`source` 為 `resume` / `clear` 時同樣會觸發,因此使用者在 claude 內 `/clear` 或切換對話時 registry 會跟著更新 — 這是 mtime 探測法無法涵蓋的情況。

`SessionEnd` hook 一併安裝,僅用於提早把 entry 標記結束。

> **不得依賴 `SessionEnd`。** phantom 是以 **SIGTERM** 終止 claude,`SessionEnd` 在 SIGTERM 下是否觸發**未經驗證**。憑證 sync-back 因此**維持在 shell 側**(loop 內 `command claude` 返回後執行 `_capture-claude-exit`,不論 claude 如何結束都會執行)。`SessionEnd` 只是最佳化,不是正確性的一環。

**架構原則(直接約束 Phase 2):hook 只提升準確度,永遠不是切換機制的必要條件。** process 層機制(loop + sentinel + registry)必須自身即可運作;session id 有 hook 就用權威值,沒有就退回探測。新增一個 AI tool 的門檻因此是「能不能找到它的 session 檔」,而非「它有沒有 hook」。

### 7. `orrery phantom` 的定址與消歧義

`ORRERY_PHANTOM_SHELL_PID` 不再是必要條件,改以 registry 為準:

| 情境 | 行為 |
|---|---|
| 環境有 `ORRERY_PHANTOM_ID`(從 claude 內部觸發) | 直接使用該 entry;**零歧義,等同現行行為** |
| 無,但存活 entry 中 cwd 相符者恰好一個 | 使用該 entry |
| 無 / 多個相符 | 列出候選(tool、account、cwd、session 前 8 碼、tty);stdin 是 tty 則互動選擇,否則報錯並要求 `--session <n\|id>` |

其餘流程不變:寫 sentinel(現在寫進該 entry 的目錄)、SIGTERM claude、由 supervisor 套用 pin 變更。**不在此處變更 pin** — 現有註解(`PhantomAccountTriggerCommand.swift:17-24`)已說明原因:sync-back 會把舊 claude 的 live token 寫進新帳號。

### 8. `orrery run claude`

`run)` 分支對 claude 退化為呼叫 shell function `claude "$@"`,行為等價。不遞迴:loop 內用的是 `command claude`。不印任何提示(使用者選定)。其他指令的 `run` 行為完全不變。

### 9. `orrery show`

新增一段列出存活的 supervised session:tool、account、workspace、cwd、session 前 8 碼。這是 registry 的副產品,與切換功能無關。

## 相容性 / 升級

**已在 rc 檔中的舊 shell function 是主要風險。** 使用者更新了 `orrery-bin` 但尚未重跑 `orrery setup` 時:舊的 `orrery run claude` loop 仍讀全域 `~/.orrery/.phantom-sentinel`,而新的 `orrery phantom` 會寫 per-supervisor sentinel → 切換靜默失效。

處置:`orrery phantom` 偵測到 `ORRERY_PHANTOM_SHELL_PID` 有值**但 registry 中找不到對應 entry** 時,判定為 legacy supervisor,**同時寫入舊的全域 sentinel 路徑**以維持可用,並印一行提示建議重跑 `orrery setup`。此相容分支標註移除版本。

`~/.orrery/.phantom-sentinel` 若存在,於 `_phantom-begin` 首次執行時刪除(舊格式殘留)。

## 測試策略

**可單元測試(Swift,佔絕大多數):**

- `_phantom-begin` 的「是否該 supervise」判定 — 純函式,輸入 argv + tty 旗標,涵蓋 `-p`、子指令集合、非 tty
- registry 讀寫、`meta.json` 編解碼、schema 版本
- 存活判定 — 注入 pid/starttime lookup,涵蓋 pid 回收(pid 存活但 starttime 不符 → 判定為死)
- stale entry 清理
- 消歧義選擇 — 輸入候選集合 + cwd + 環境,斷言選中哪一個或要求明確指定
- `_phantom-next` 的 argv 產生與 shell quoting
- 往下找 claude pid — 沿用 `resolveClaudePid` 既有的注入式 lookup 測試模式
- hook 輸入 JSON 解析 → 寫入正確 entry

**需整合測試:** shell function 的 loop 骨架(以假的 `claude` 可執行檔驅動,驗證 sentinel → relaunch → argv 傳遞)。

**需手動驗證(無法自動化):** SIGTERM 下 `SessionEnd` 是否觸發;實際 claude 的 `SessionStart` 輸入 JSON 欄位。

**回歸重點:** 同一 cwd 開兩個 claude,切換其中一個,斷言另一個不受影響(這正是本設計要修的競態)。

## 風險與未決

1. **`SessionEnd` 在 SIGTERM 下的行為未驗證。** 設計已不依賴它,影響限於「entry 稍晚才被清掉」,由存活判定兜底。
2. **origin 帳號的 hook 安裝路徑。** `PrepareClaudeLaunchCommand` 在 origin 走 `--links-only` 分支(`ShellFunctionGenerator.swift:272-279` 對應處),需確認該分支是否也會 patch `~/.claude/settings.json`。若否,origin 下的 session id 會退回 `probe`。**實作時必須確認**,功能不會壞,但準確度會降級。
3. **`eval "$_spec"` 的注入面。** 輸出由 Swift 產生且僅含固定鍵名 + 已 quote 的值,不含使用者輸入;`_phantom-next` 的 argv 則含 session id(來源為檔名/hook,需 quote)。兩處都必須走同一個 shell-quote helper。
4. **`_phantom-begin` 失敗時必須靜默直通。** 任何錯誤都不能阻擋 claude 啟動 — 使用者寧可失去 phantom,也不能無法開 claude。

## Phase 2 前瞻(不在本階段實作)

把 phantom 機制抽成獨立的 SPM target(比照 `OrreryThirdParty` / `OrreryAccountKit` 的慣例,test-first),三個工具共用。

本設計已為此鋪路:`_phantom-begin` / `_phantom-next` / `_phantom-end` 除 `--tool` 外不含任何 claude 專屬語意,因此 `codex()` / `gemini()` 的 shim 是同一段骨架換個 `--tool`;工具差異(session 檔位置、resume 參數、gemini 的 `HOME` override)收斂在 framework 內的 protocol conformance。

已知可複用:`SessionResolver.swift:44-49` 已具備三工具的 session 探索(claude `projects/<key>/*.jsonl`、codex `sessions/**/rollout-*.jsonl`、gemini `tmp/<hash>/chats/checkpoint-*.json`)。

Phase 2 待查:codex / gemini 各自的 resume CLI 參數;兩者是否有對等的 hook 機制(若無,依第 6 節的架構原則退回探測即可)。
