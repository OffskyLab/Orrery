# Localization keys — translator notes

Context for every key in `en.json`. Keys are grouped by namespace (the prefix
before the first dot). Placeholders in `{curly}` come from
`l10n-signatures.json` and must appear verbatim in every locale.

When a key has Bool/Optional branches (e.g. `memory.migrationDone.isolated` +
`memory.migrationDone.shared`), both sub-keys are documented together.

---

## account — top-level account commands (v3: promoted from `orrery account X` to `orrery X`)

| Key | Context |
| --- | --- |
| `account.abstract` | Legacy root-command help (kept for compatibility; in v3 there is no top-level `orrery account` — commands are promoted to top-level). |
| `account.addAbstract` | Command help for `orrery add`. |
| `account.addCreated` | Success after adding an account. `{tool}` = tool name; `{name}` = display name. |
| `account.addDuplicateName` | Validation error when adding an account whose display name already exists for the same tool. `{name}` = display name; `{tool}` = tool name. |
| `account.addEmptyName` | Validation error when an empty name is entered. |
| `account.addNameHelp` | Help text for the positional account name in `add`. |
| `account.flagClaudeHelp` | `--claude` flag help text for `add` (and other top-level account commands). |
| `account.flagCodexHelp` | `--codex` flag help text for `add` (and other top-level account commands). |
| `account.flagGeminiHelp` | `--gemini` flag help text for `add` (and other top-level account commands). |
| `account.addNamePrompt` | Interactive prompt asking the user to enter a display name. Trailing space is load-bearing. |
| `account.addToolsTooMany` | Error when more than one of `--claude`, `--codex`, `--gemini` is given. Flag names are literal identifiers — do not translate. |
| `account.addToolDefaultNotice` | Notice printed (to stderr) when `orrery add` runs with no tool flag and falls back to the Claude default. Flag names are literal identifiers — do not translate. |
| `account.listAbstract` | Command help for `orrery list`. |
| `account.listEmpty` | Shown when no accounts exist yet. Command `orrery add` is literal. |
| `account.listRow` | One row in the account list. `{marker}` = `●` for the account active in the current sandbox, `-` otherwise; `{name}` = display name; `{tail}` = pre-built padding + info suffix (e.g. `"  jiabao@..., team"`) or empty string. |
| `account.listSandboxHeader` | Header line printed by `orrery list` when inside a non-origin workspace. `{name}` = workspace name. |
| `account.listToolHeader` | Section header per tool in the list output. `{tool}` = tool name. |
| `account.removeAbstract` | Command help for `orrery remove`. |
| `account.removeAborted` | Printed when the user declines the batch-delete confirmation prompt (interactive multi-select path). |
| `account.removeConfirmBatch` | Confirmation prompt before batch-deleting the multi-select picker's selection. `{count}` = number of accounts selected. Trailing space is load-bearing (readLine prompt). |
| `account.removeForceHelp` | `--force` flag help text for `remove`; skips the batch confirmation prompt. |
| `account.removeMultiSelectTitle` | Title line shown above the interactive multi-select picker when `orrery remove` runs with no name argument. |
| `account.removeNameHelp` | Positional `name` argument help text for `remove`, distinct from the shared `account.nameSelectorHelp` because the argument is optional here (omit → multi-select). |
| `account.removeNoAccounts` | Shown when the multi-select picker has nothing to list (no accounts exist yet for the resolved tool). `{tool}` = tool name. |
| `account.removeNotFound` | Error when the requested account doesn't exist. `{name}` = display name; `{tool}` = tool name. |
| `account.removeNothingSelected` | Shown when the multi-select picker is confirmed with no items toggled on. |
| `account.removeRemoved` | Success after removing an account (single-target and per-item in the batch path). `{tool}` = tool name; `{name}` = display name. |
| `account.removeStillReferenced` | Error when the account is still pinned by one or more sandboxes. `{name}` = display name; `{envs}` = comma-joined sandbox names (placeholder retained for compat). |
| `account.showAbstract` | Command help for `orrery show`. |
| `account.showRowHeader` | Top-level header row when a tool has an account pinned (no longer nested under an "active sandbox" banner — each account carries its own workspace). `{tool}` = tool name; `{name}` = account display name. Followed by indented detail lines (Auth/Workspace/…). |
| `account.showRowUnpinned` | One row when a tool has no account pinned. `{tool}` = tool name. |
| `account.showFlagVerboseHelp` | Help text for the `-v`/`--verbose` flag on `orrery show`. |
| `account.showLabelAuth` | Indented label preceding the email/plan line under a tool's row. Pre-padded for column alignment. |
| `account.showAuthNone` | Value shown after `showLabelAuth` when neither email nor plan is known. |
| `account.showLabelWorkspace` | Indented label preceding the pinned content-workspace name. Pre-padded for column alignment. |
| `account.showLabelPath` | Indented label preceding the account's storage directory path. Verbose-only. Pre-padded for column alignment. |
| `account.showLabelWorkspacePath` | Nested one level deeper than `showLabelWorkspace`, directly under it — reads as "this workspace's path", not "Workspace Path" (avoid repeating the word "Workspace"). Verbose-only, claude only (other tools don't materialize a workspace dir yet). Pre-padded for column alignment. |
| `account.showLabelCreated` | Indented label preceding the account's creation date. Verbose-only. Pre-padded for column alignment. |
| `account.nameSelectorHelp` | `--name` option help text shared by `use` (and `remove`). |
| `account.useAbstract` | Command help for `orrery use`. |
| `account.useNotFound` | Error when the requested account doesn't exist. `{name}` = display name; `{tool}` = tool name. Flag `--{tool}` is literal. |
| `account.usePinned` | Success after pinning an account. `{tool}` = tool name; `{name}` = account display name; `{env}` = sandbox name (placeholder retained for compat). |
| `account.loginManualFallbackHint` | Warning shown when Claude is launched via the Swift `Process` fallback path (bypassing the shell function). `{tool}` = tool name. File path `~/.orrery/activate.sh` is literal — do not translate. |
| `account.loginReadyHint` | Hint printed by the shell function just before `command claude` is launched for account-add. `/exit` is a literal Claude command — do not translate. Purely informational: the `auth_success` hook installed by `_account-add-prepare` already finalizes the account as soon as login succeeds, so nothing actually depends on the user running `/exit`. |
| `account.addFinalized` | Success line printed by `_account-add-finalize` when no email or plan is available. `{tool}` = tool name; `{name}` = display name. |
| `account.addFinalizedWithInfo` | Success line printed by `_account-add-finalize` when email and/or plan are available. `{tool}` = tool name; `{name}` = display name; `{info}` = comma-joined email/plan string. |
## create — `orrery sandbox create` wizard

| Key | Context |
| --- | --- |
| `create.abstract` | One-line command help shown by `orrery sandbox create --help`. |
| `create.alreadyExists` | Error when the name already exists. `{name}` = user-supplied env name. |
| `create.askSetupTool` | Per-tool confirmation inside the wizard. `{tool}` = `claude` / `codex` / `gemini`. |
| `create.cloneFrom` | Option label in the clone picker. `{name}` = source environment name. |
| `create.cloneHelp` | `--clone` flag help text. |
| `create.cloneNone` | "Don't clone" option in the clone picker. |
| `create.clonePrompt` | Title for the clone picker (env-level clone, no tool context). |
| `create.clonePromptFor` | Title for the clone picker scoped to a specific tool. `{tool}` = tool name. |
| `create.cloned` | Success message after cloning. `{source}` = source env name. |
| `create.copyLoginCopied` | Status after copying login state. `{source}` = source env name. |
| `create.copyLoginFailed` | Shown when the source isn't logged in. `{source}` = source env name. |
| `create.copyLoginFrom` | Option label in the copy-login picker. `{label}` = source env name. |
| `create.copyLoginHelp` | Help text for the copy-login flag. |
| `create.copyLoginIndependent` | "Log in myself" option in the copy-login picker. |
| `create.copyLoginPrompt` | Title for the copy-login picker (env-level). |
| `create.copyLoginPromptFor` | Title for the copy-login picker scoped to a tool. `{tool}` = tool name. |
| `create.copyLoginStatus` | Post-wizard recap line when login state was copied. |
| `create.created` | Success message after environment creation. `{name}` = new env name. |
| `create.defaultDescription` | Description shown for the reserved `origin` environment. Also reused by `info` and `list` as the origin description. |
| `create.descriptionHelp` | `--description` flag help text. |
| `create.firstEnvCreated` | Shown when the user just created their first environment. `{name}` = new env name. Has literal newlines — preserve them. |
| `create.freshLoginStatus` | Recap line when the user chose to log in themselves. |
| `create.isolateMemoryHelp` | `--isolate-memory` flag help text. |
| `create.isolateSessionsHelp` | `--isolate-sessions` flag help text. |
| `create.memory.isolated` / `create.memory.shared` | Recap line. Bool branch on memory mode. |
| `create.memoryShareNo` | Option: isolate memory. |
| `create.memorySharePrompt` | Title for the memory-sharing picker. |
| `create.memoryShareYes` | Option: share memory. |
| `create.nameHelp` | Positional `name` argument help text. |
| `create.noToolSelected` | Recap when the user skipped all tools. |
| `create.queryingLoginStatus` | Shown while querying each tool's login status. Trailing `…` intentional. |
| `create.reservedName` | Error when the user tries to create `origin`. |
| `create.sessionShareNo` | Option: isolate sessions. |
| `create.sessionSharePrompt` | Title for the session-sharing picker (env-level). |
| `create.sessionSharePromptFor` | Title for the session-sharing picker scoped to a tool. `{tool}` = tool name. |
| `create.sessionShareYes` | Option: share sessions. |
| `create.sessions.isolated` / `create.sessions.shared` | Recap line. Bool branch on session mode. |
| `create.setupToolNo` | Skip-setup option label. |
| `create.setupToolYes` | Add-and-setup option label. |
| `create.toolHelp` | `--tool` flag help text. Tool names (`claude`, `codex`, `gemini`) are literal identifiers — do not translate. |
| `create.tools` | Recap line listing selected tools. `{list}` = comma-joined names. |
| `create.unknownTool` | Error for an unknown `--tool` value. `{raw}` = user input. Keep tool names literal. |
| `create.wizardTitle` | Title for the initial tool picker. |

## currentAccount — `orrery current`

| Key | Context |
| --- | --- |
| `currentAccount.abstract` | Command help. Reuses `account.showRowHeader` / `account.showRowUnpinned` for its per-tool output lines — see the `account` section above. |

## delegate — `orrery delegate`

| Key | Context |
| --- | --- |
| `delegate.abstract` | Command help. |
| `delegate.accountHelp` | `--account` flag help. |
| `delegate.promptHelp` | Positional `prompt` argument help. |

## delete — `orrery delete`

| Key | Context |
| --- | --- |
| `delete.aborted` | Shown when the user says "no" to the confirmation. |
| `delete.abstract` | Command help. |
| `delete.confirm` | Single-env confirmation. `{name}` = env name. Ends with `[y/N] ` prompt suffix — keep trailing space. |
| `delete.confirmBatch` | Multi-env confirmation. `{count}` = number selected. |
| `delete.deleted` | Success message. `{name}` = env name. |
| `delete.forceHelp` | `--force` flag help. |
| `delete.multiSelectTitle` | Title for the multi-select picker. |
| `delete.nameHelp` | Positional `name` argument help. |
| `delete.noEnvs` | Shown when no deletable envs exist. |
| `delete.nothingSelected` | Shown when the user finishes the multi-select with no items. |
| `delete.reservedName` | Error when trying to delete `origin`. |


## export / unexport — shell integration internals

| Key | Context |
| --- | --- |
| `export.abstract` | Hidden command — called by the shell function. Marked as internal in help. |
| `unexport.abstract` | Hidden command — called when switching away. |

## info — `orrery info`

| Key | Context |
| --- | --- |
| `info.abstract` | Command help. |
| `info.defaultInfo` | Full block printed for `orrery info origin`. Has literal `\n`. Preserve indentation. |
| `info.labelCreated` / `info.labelDescription` / `info.labelEnvVars` / `info.labelID` / `info.labelLastUsed` / `info.labelMemoryMode` / `info.labelMemoryPath` / `info.labelName` / `info.labelPath` / `info.labelSessionMode` / `info.labelTools` | Field labels. **Trailing spaces are padding** — keep them intact so columns align. Label text should be fixed-width in the target language (add spaces as needed). |
| `info.modeIsolated` / `info.modeShared` | Value for Memory/Sessions rows. |
| `info.nameHelp` | Positional arg help. |
| `info.noActive` | Error when neither name nor active env is available. |
| `info.none` | Placeholder when a field is empty (e.g. no env vars). |

## init — `orrery init`

| Key | Context |
| --- | --- |
| `init.abstract` | Command help. Contains literal `eval "$(orrery init)"` — do not translate the command. |

## list — `orrery list`

| Key | Context |
| --- | --- |
| `list.abstract` | Command help. |
| `list.empty` | Currently unused (origin is always listed, so the list is never empty). Retained for compatibility. |
| `list.header` | Currently unused (list now uses multi-line layout). Retained for compatibility. |
| `list.pinnedHeader` | Sub-heading under each `<workspace>: <path>` line, introducing the accounts pinned to it. Only printed when at least one account of that tool has `workspace == <name>`. |

## mCPServerCmd / mCPSetup — MCP server commands

| Key | Context |
| --- | --- |
| `mCPServerCmd.abstract` | `orrery mcp-server` command help (parent of MCP stdio server). |
| `mCPSetup.abstract` | `orrery mcp` parent command help. |
| `mCPSetup.setupAbstract` | `orrery mcp setup` command help. |
| `mCPSetup.success` | Printed after successful setup. References slash commands `/orrery:delegate` etc. — keep them literal. |
| `mCPSetup.wroteSettings` | Printed while writing settings. `{path}` = settings file path. Ends with `\n`. |

## pin — `orrery pin`

| Key | Context |
| --- | --- |
| `pin.abstract` | Command help. |
| `pin.flagWorkspaceHelp` | `--workspace` flag help text. |
| `pin.argAccountHelp` | Positional `<account>` argument help. |
| `pin.errorAccountNotFound` | Error when the named account isn't in the pool. `{name}` = account name; `{tool}` = tool name. |
| `pin.errorWorkspaceNotFound` | Error when the workspace doesn't exist. `{name}` = workspace name. |
| `pin.success` | Success message after pinning. `{account}` = account name; `{workspace}` = workspace name. |

## memory — `orrery memory`

| Key | Context |
| --- | --- |
| `memory.aborted` | Shown when the user declines a memory action. |
| `memory.abstract` | Parent command help. |
| `memory.actionExport` / `memory.actionInfo` / `memory.actionIsolate` / `memory.actionShare` / `memory.actionStorage` | Menu labels for the interactive memory prompt. |
| `memory.alreadyIsolated` / `memory.alreadyShared` | No-op messages when the env is already in the requested mode. |
| `memory.discardConfirm` | Confirm prompt before discarding memory. `⚠️` emoji intentional. Trailing `[y/N] ` has a trailing space. |
| `memory.exportAbstract` | `memory export` sub-command help. |
| `memory.exported` | Success message. `{path}` = output file path. |
| `memory.infoAbstract` | `memory info` sub-command help. |
| `memory.isolateAbstract` | `memory isolate` sub-command help. |
| `memory.migrationDiscardToIsolated` | Migration option: start fresh isolated memory. |
| `memory.migrationDiscardToShared` | Migration option: discard isolated, use shared only (destructive — warning emoji retained). |
| `memory.migrationDone.isolated` / `memory.migrationDone.shared` | Success after migration. Bool branch on target mode. `{envName}`. |
| `memory.migrationMergeToIsolated` | Migration option: copy shared → isolated. |
| `memory.migrationMergeToShared` | Migration option: merge isolated → shared. |
| `memory.migrationPrompt` | Title for the migration choice picker. |
| `memory.migrationWarning` | Multi-line banner before migration. `{from}`, `{to}` are mode labels. Preserve `\n    ` indentation so alignment holds. |
| `memory.noActiveEnv` | Error when no active env. |
| `memory.noMemory` | Shown for `memory info` when memory file doesn't exist. |
| `memory.outputHelp` | `--output` flag help. |
| `memory.settingsPrompt` | Title for the memory-settings interactive menu. |
| `memory.shareAbstract` | `memory share` sub-command help. |
| `memory.statusExists.absent` / `memory.statusExists.present` | Optional-branch on file existence. `{size}` = bytes. |
| `memory.statusMode.isolated` / `memory.statusMode.shared` | Status row. Bool branch. |
| `memory.statusPath` | Status row: path to memory file. `{path}`. |
| `memory.storageAbstract` | `memory storage` sub-command help. |
| `memory.storageCopied` | Success after copying memory to a new storage path. |
| `memory.storageCopyNo` / `memory.storageCopyYes` | Copy-prompt options. |
| `memory.storageCopyPrompt` | Asked when the new path has no memory yet. |
| `memory.storageNotDirectory` | Error: target path is a file. `{path}`. |
| `memory.storagePathHelp` | Positional arg help for `memory storage <path>`. |
| `memory.storageReset` | Success after `--reset`. |
| `memory.storageResetHelp` | `--reset` flag help. |
| `memory.storageSet` | Success after setting a custom path. `{path}`. |
| `memory.storageStatus.custom` / `memory.storageStatus.default` | Status row. Optional-branch on whether the path is customized. `{path}`. |

## orrery — root command

| Key | Context |
| --- | --- |
| `orrery.abstract` | Help text for the `orrery` root command. |

## rename — `orrery rename`

| Key | Context |
| --- | --- |
| `rename.abstract` | Command help. |
| `rename.nameHelp` | Positional `old name` help. |
| `rename.newNameHelp` | Positional `new name` help. |
| `rename.renamed` | Success message. `{old}`, `{new}`. |
| `rename.reservedName` | Error when trying to rename `origin`. |

## run — `orrery run`

| Key | Context |
| --- | --- |
| `run.abstract` | Command help. |
| `run.accountHelp` | `--account` flag help. |
| `run.commandHelp` | Positional `command…` arg help. |
| `run.noCommand` | Error when no command followed. Contains literal example `orrery run -a work claude --resume <id>`. |

## sessions — `orrery sessions`

| Key | Context |
| --- | --- |
| `sessions.abstract` | Command help. |
| `sessions.noSessions` | Shown when no sessions exist for the project. |

## phantom — `/orrery:phantom` trigger commands

| Key | Context |
| --- | --- |
| `phantom.accountTriggerAbstract` | Help text for `orrery phantom`. Shown in `--help` for the subcommand. Mentions `--session` — the command can target any supervised session, not just the current one. |
| `phantom.notUnderPhantom` | Error when no live registry entry can be found and there is no legacy fallback either. References `orrery setup` — keep literal. |
| `phantom.claudeNotFound` | Error when the claude process can't be located in the process tree. |
| `phantom.signalFailed` | Error when SIGTERM delivery fails. |
| `phantom.switchingAccount` | Printed when switching to a named account with a known session. `{account}` = account display name; `{session}` = first 8 chars of session id. |
| `phantom.switchingAccountNoSession` | Printed when switching to an account with no active session. `{account}` = account display name. |
| `phantom.sessionSelectorHelp` | Help text for `orrery phantom --session`. Shown in `--help` for the subcommand. |
| `phantom.ambiguousHeader` | First line of the error printed when more than one supervised session is live and none can be disambiguated by cwd. |
| `phantom.ambiguousHint` | Last line of that same error, telling the user how to pick one with `--session`. |
| `phantom.legacySupervisor` | Notice (stderr) printed when falling back to the pre-registry single global sentinel, because the shell integration predates `orrery setup`'s registry support. |
| `phantom.sessionNotFound` | Error when an explicit `--session <number|id>` matches no live entry. `{selector}` = the raw value the user passed. Distinct from `phantom.notUnderPhantom`, which is only for "no sessions at all." |

## show — `orrery show` supervised-session listing

| Key | Context |
| --- | --- |
| `show.supervisedHeader` | Header line printed above the list of live supervised (phantom) sessions in `orrery show`, only when at least one is running. Distinct from the `account.show*` keys, which cover the rest of `orrery show`'s per-tool account output. |

## setup — `orrery setup` (shell integration install)

| Key | Context |
| --- | --- |
| `setup.abstract` | Command help. Contains literal `eval "$(orrery setup)"`. |
| `setup.addedTo` | Success: appended to rc file. `{path}`. Trailing `\n`. |
| `setup.alreadyPresent` | Skipped: integration already in rc. `{path}`. |
| `setup.failedToWrite` | Write error. `{path}`, `{error}`. |
| `setup.migratedRc` | Shown when an old `eval` line was migrated to `source`. `{path}`. |
| `setup.shellHelp` | `--shell` flag help. Shell names `bash`/`zsh` are literal. |
| `setup.unsupportedShell` | Error for an unknown shell value. `{shell}`. Supported list stays literal. |
| `setup.wroteActivate` | Success: wrote the activate script. `{path}`. |

## toolFlag — `--tool` flag enum descriptions

Shown by ArgumentParser as part of auto-generated help.

| Key | Context |
| --- | --- |
| `toolFlag.claude` / `toolFlag.codex` / `toolFlag.gemini` | Vendor descriptions. The `(default)` marker on `claude` is meaningful — keep it. |

## toolSetup — tool install/login interactive flow

| Key | Context |
| --- | --- |
| `toolSetup.installNow` | Prompt: install the tool? `[Y/n] ` suffix — preserve trailing space. |
| `toolSetup.installed` | Success marker. `✓` intentional. `{tool}` = tool name. |
| `toolSetup.installing` | Progress line. `{tool}`, `{cmd}`. Trailing `\n`. |
| `toolSetup.loginNow` | Prompt: log in? `[Y/n] `. |
| `toolSetup.notInstalled` | Status line. `{tool}`. |
| `toolSetup.skipping` | Shown on "no" to install. `{tool}`. |
| `toolSetup.skippingLogin` | Shown on "no" to login. `{tool}`. |

## update — `orrery update`

| Key | Context |
| --- | --- |
| `update.abstract` | Command help. |
| `update.notice` | One-line "update available" banner. `{current}`, `{latest}`. Keep the trailing `run: orrery update` hint literal. |
| `update.unsupportedPlatform` | Error on non-supported OS. URL kept literal. |
| `update.upgrading` | Progress line. |

## workspace — `orrery workspace` command family

| Key | Context |
| --- | --- |
| `workspace.abstract` | Root command help for `orrery workspace`. |

---

## Conventions for translators

- **Tool names** (`claude`, `codex`, `gemini`), **command names** (`orrery`,
  `orrery sandbox create`, …), **shell names** (`bash`, `zsh`), and **URLs** are
  identifiers — never translate them.
- **`[Y/n]` / `[y/N]`** conventions should be preserved as-is; the parser
  reads these characters.
- **Trailing whitespace** in prompt strings is load-bearing (separates prompt
  from user input) — keep it.
- **`\n`** inside values is a literal line break in the terminal output —
  preserve placement so multi-line layouts still align.
- **Emoji** (`⚠️`, `✓`) is intentional UI; keep unless it violates the target
  locale's conventions.
