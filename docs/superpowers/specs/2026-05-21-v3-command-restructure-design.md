# v3.0 命令結構重整設計

- **Date**: 2026-05-21
- **Status**: Draft
- **Author**: Grady Zhuo

## 1. Motivation

orrery v1 的設計把 env 當作核心抽象,所有操作都圍繞 env 設計(`orrery create / use / list / delete / info / rename ...`)。env 同時負責「帳號隔離 + memory/sessions 沙箱 + 環境變數容器」三件事。

v2.8.0(PR #11)把帳號從 env 拆出來變成獨立的 accounts pool。完成後實際使用上看到的事實是:**大部分使用者只需要帳號切換、不需要沙箱**——env 已經退化成「進階使用者才會碰的東西」。但目前的命令面仍以 env 為主、account 是 nested namespace(`orrery account *`),這個結構繼續鞏固了「env 是主、account 是附屬」的錯誤心智模型。

本 spec 把主從關係翻轉,作為 **v3.0 一次性 hard break**:

- **account 提到 top level**:`orrery add / list / show / use / remove` 直接操作帳號。
- **env 改名為 sandbox、降為 namespace**:`orrery sandbox create / use / list / ...`。
- 不再為退役的概念維護舊命令名;不留 alias。

「env」改名為「sandbox」是為了:(1)避免跟既有的 `orrery env set/unset`(env 變數操作)語意衝突;(2)更貼合這個概念現在的本質——一個「使用者進階場景才開的隔離空間」。

## 2. 設計目標

- **主要 mental model = account**:第一次裝 orrery 的人,只要 `orrery add` / `orrery use` / `orrery list` 就能完成「換帳號使用」這件事。不需要先理解 env 是什麼。
- **進階使用者用 sandbox**:需要 memory/sessions/env-var 隔離時才碰 `orrery sandbox *`。
- **命令名意義單一**:`orrery list` 永遠是 account list,`orrery sandbox list` 永遠是 sandbox list,不會有「`list` 看的是哪一個?」的不確定感。
- **無歷史包袱**:v3.0 一刀切,version 跳 3.0.0,CHANGELOG 附完整對照表;加幾條友善錯誤訊息(`Did you mean ...`)接住沒看 changelog 的使用者。

## 3. 命令對應表 (v2.8 → v3.0)

```
類別            v2.8 (現在)                          v3.0 (新)

# sandbox 管理 (原 env)
sandbox         orrery create <name>              →  orrery sandbox create <name>
sandbox         orrery use <name>                 →  orrery sandbox use <name>
sandbox         orrery list                       →  orrery sandbox list
sandbox         orrery delete <name>              →  orrery sandbox delete <name>
sandbox         orrery info <name>                →  orrery sandbox info <name>
sandbox         orrery rename <old> <new>         →  orrery sandbox rename <old> <new>
sandbox         orrery current                    →  orrery sandbox current
sandbox         orrery memory ...                 →  orrery sandbox memory ...
sandbox         orrery sync ...                   →  orrery sandbox sync ...
sandbox (內部)  orrery export <name>              →  orrery sandbox export <name>
sandbox (內部)  orrery unexport <name>            →  orrery sandbox unexport <name>

# env vars (原 orrery env set/unset,搬進 sandbox 並 verb 一體化)
sandbox env-var orrery env set <key> <value>      →  orrery sandbox set-env <key> <value>
sandbox env-var orrery env unset <key>            →  orrery sandbox unset-env <key>

# account 操作 → 提到 top level
account         orrery account add                →  orrery add
account         orrery account list               →  orrery list                ← 含意改變
account         orrery account show               →  orrery show
account         orrery account use --name <X>     →  orrery use <X>             ← 含意改變、positional
account         orrery account remove --name <X>  →  orrery remove <X>          ← positional

# 不動的正交動作
tool/session    orrery run / delegate / sessions / resume                       (不變)
install         orrery setup / init / install / uninstall / update / check-update  (不變)
mcp             orrery mcp setup / server                                       (不變)
plugin          orrery tools / third-party                                      (不變)

# 移除
                orrery auth                       →  ❌ 刪除(功能被 show / list 取代)
                orrery origin                     →  ❌ 刪除(takeover 自動跑、release 走 uninstall)
                orrery deactivate                 →  ❌ 刪除(改用 `orrery sandbox use origin`)
```

**規則細節**:

- `orrery use <name>` 預設 claude(同 v2.8 `account use`)。同名跨工具時(同一 `work` 名稱在 claude 跟 codex 都有)報錯並提示加 `--<tool>` 旗標。
- `orrery remove <name>` 同上規則。
- `orrery list` / `orrery show` / `orrery sandbox list` / `orrery sandbox current` 都不要求 tool 旗標(列出多工具的全部)。
- sandbox 的 `set-env` / `unset-env` 用 hyphenated verb 來避免 "env" 又當 namespace 又當 variable 名的二義性。`-e <sandbox-name>` 改為 `-s <sandbox-name>`(同步 namespace 改名)。

## 4. Shell function rework

shell 端在 v2.8 攔截了這幾個 case:`use`(env 切換、export 環境變數)、`deactivate`、`create`(後問是否切過去)、`account add`(claude TTY 沙箱)、`run`(phantom claude 迴圈)。

v3.0 重新對應:

| 舊攔截 | v3.0 攔截 | 為何 shell 還是要管 |
|---|---|---|
| `use <name>` | `sandbox use <name>` | 需要 `eval` orrery-bin 算出的 env-var exports + 設 `ORRERY_ACTIVE_ENV`(Swift 進程無法改父 shell 的環境) |
| `deactivate` | (移除) | 改用 `orrery sandbox use origin` |
| `create <name>` | `sandbox create <name>` | 創建完問使用者「切過去?」需要 shell 端 `read` + 條件呼叫 `sandbox use` |
| `account add` (claude) | `add` (claude case) | TTY foreground 需求一樣,只是入口從 `account)` 改成 `add)` |
| `run` | `run` | phantom claude 迴圈,內容不變(裡面的 `account use` 呼叫直接更名) |

新 shell function 大致結構:

```sh
orrery() {
  ...
  case "$cmd" in
    sandbox)
      case "${2:-}" in
        use)                      # sandbox use <name> — shell 端 export
          ...
          ;;
        create)                   # sandbox create <name> — shell 端 prompt 切換
          ...
          ;;
        *) command orrery-bin "$@" ;;       # list/delete/info/rename/current/memory/sync/set-env/unset-env/export/unexport
      esac
      ;;
    add)
      # claude TTY 路徑(原 account)案):_add-prepare → command claude → _add-finalize
      # 帶 --codex / --gemini / -h / --help 的 fall through 到 orrery-bin
      ...
      ;;
    run)
      # phantom claude 迴圈(內容沿用 v2.8,只是內呼叫的 account use 對應到新指令名)
      ...
      ;;
    *) command orrery-bin "$@" ;;
  esac
}
```

**重點**:`orrery use <account>`(新意 top-level)不需要 shell 端 export(account 切換只動 Keychain / pool symlink,不改 shell 環境變數),`use` 不再出現在 shell 端 case 中——只剩 `sandbox use` 需要 shell magic。

## 5. Slash command `/orrery:phantom`

`/orrery:phantom <args>` 由 Claude 在對話中解析 `$ARGUMENTS` 觸發。v3.0 把預設語意對齊 CLI(預設 account):

```
/orrery:phantom <name>            # 切 claude account(預設 — 因為 supervisor 本身是 claude session)
/orrery:phantom codex <name>      # 切 codex account(罕見,但允許)
/orrery:phantom gemini <name>     # 切 gemini account
/orrery:phantom sandbox <name>    # 切 sandbox(顯式 sandbox 關鍵字)
/orrery:phantom                   # 列出可用 account 與 sandbox,提示使用者
```

CLI 對應:`orrery-bin _phantom-trigger-account --<tool> --name <name>` / `orrery-bin _phantom-trigger-sandbox <name>`(原 `_phantom-trigger` 改名,跟 namespace 一致)。

## 6. 內部欄位 rename

phantom 之間 IPC 用的 sentinel(`~/.orrery/.phantom-sentinel`)欄位:

- `TARGET_ENV` → `TARGET_SANDBOX`
- `TARGET_ACCOUNT_TOOL` / `TARGET_ACCOUNT_NAME` 維持不變
- `SESSION_ID` 維持不變

`PhantomTriggerCommand` → `PhantomSandboxTriggerCommand`(內部命令名 `_phantom-trigger` → `_phantom-trigger-sandbox`,跟 `_phantom-trigger-account` 對稱)。

環境變數 `ORRERY_ACTIVE_ENV` 是 shell 出口、會被使用者 script 用到——**保留原名**(改名會破壞使用者既有的 `if [ "$ORRERY_ACTIVE_ENV" = ... ]` script)。內部 Swift code 的命名(e.g. `envName`)可改可不改;以可讀性為主。

## 7. 相容性 / 錯誤訊息 hint

v3.0 是 hard break,**不留 alias**。但加幾個友善的錯誤訊息,讓沒讀 changelog 的舊使用者快速找到對應:

- `orrery use foo`(現在是 account use):若找不到 account `foo`、**但有同名 sandbox**,印出 `No account 'foo'. Did you mean: orrery sandbox use foo?`
- `orrery list`:預設跑 account list(不報錯)。
- `orrery create <name>`(已不存在):ArgumentParser 的 "Unknown subcommand" 之外,加 hook 提示 `Did you mean: orrery sandbox create <name>?`。
- 同樣 hook 套用到 `delete / info / rename / memory / sync`。
- `orrery auth` / `orrery origin` / `orrery deactivate` → 印一行說明「v3.0 移除,改用 X」。

這些 hint 屬於 polish,加在頂層 command 的 dispatch error 處理裡;不需要 alias 機制。

## 8. 影響範圍 / 實作面

預估 commits 數 5-10 個邏輯單元(可拆 PR、也可單一大 PR)。

1. **新增 `SandboxCommand`**(取代 `EnvCommand`):把 v2.8 的 7 個 top-level env-related struct(`CreateCommand` / `UseCommand` / `ListCommand` / `DeleteCommand` / `InfoCommand` / `RenameCommand` / `CurrentCommand`)、再加 `MemoryCommand` / `SyncCommand` / `ExportCommand` / `UnexportCommand`、再加新的 `set-env` / `unset-env`,全部變成 SandboxCommand 的 subcommand。原本的 `EnvCommand`(env-var)刪除,語意搬入。
2. **account 提到 top level**:`AccountCommand` 父刪除;旗下 5 個 verb 變成 top-level command。其中 `UseCommand` 跟 `ListCommand` 因為名稱跟舊 env 命令衝突,要先把舊版改名 / 移走才能掛新版。
3. **刪除**:`AuthCommand`、`OriginCommand`、`DeactivateCommand`、`EnvCommand`、`AccountCommand`(父)、相關 L10n key 跟 test。
4. **Sentinel + phantom rename**:`TARGET_ENV` → `TARGET_SANDBOX`、`PhantomTriggerCommand` → `PhantomSandboxTriggerCommand`、`_phantom-trigger` → `_phantom-trigger-sandbox`,shell function 同步。
5. **Slash command markdown**:預設語意改成 account、加上 `sandbox` 關鍵字分支。
6. **`ShellFunctionGenerator` 重寫**:`sandbox)` / `add)` / `run)` 三個 case 完整重組;`use)` / `deactivate)` / `create)` / `account)` case 刪除。
7. **L10n audit**:所有用到 env 字眼的 user-facing key 重寫成 sandbox。`account.*` key 大多保留(對應 verb 沒變,只是不在 namespace 底下)。
8. **Tests**:大量重寫(命令名變了)。內部單元測試(adapter / store / migration)幾乎不動。
9. **CHANGELOG**:寫 v3.0 breaking change 區段、附完整對照表。
10. **版號**:`OrreryVersion.current` `2.8.x` → `3.0.0`(major bump),其他版號位置照 `CLAUDE.md` 規則同步。

## 9. Out of Scope

- 不動的正交命令:`run` / `delegate` / `sessions` / `resume` / `setup` / `init` / `install` / `uninstall` / `update` / `check-update` / `mcp` / `tools` / `third-party`。
- 不引入「account 父 namespace alias」(`orrery account add` 不能用、直接 `orrery add`)。
- 不引入「env namespace alias」(`orrery env create` 不能用、直接 `orrery sandbox create`)。
- 不重新設計 account / sandbox 的內部資料模型(只動命令 surface)。
- `ORRERY_ACTIVE_ENV` 環境變數**保留原名**,不改成 `ORRERY_ACTIVE_SANDBOX`(會破壞使用者既有 script)。

## 10. 開放問題

無。

---

## Migration Path

v3.0 是 hard break。從 v2.8 升級的使用者第一次跑 v3.0:

- 既有的 `~/.orrery/` 不需要再遷移(資料模型沒動,只是命令名變了)。
- CHANGELOG 第一行強調 breaking change、附完整對照表。
- 第一次跑 v3.0 時,如果偵測到使用者的 shell history 或某些 dotfile 含舊指令名,**不**自動改寫(風險高、難以全覆蓋);只靠錯誤訊息 hint 引導。
- Homebrew formula bump 同步。

## Versioning

照 `CLAUDE.md` Versioning Locations:

- `Sources/OrreryCore/Commands/OrreryCommand.swift` `version:` 欄位
- `Sources/OrreryCore/MCP/MCPServer.swift` `currentVersion()` 回傳值
- `Sources/OrreryCore/Version.swift` `OrreryVersion.current`
- `CHANGELOG.md`
- `docs/index.html` / `docs/zh_TW.html` 的 badge

版本 → `3.0.0`。
