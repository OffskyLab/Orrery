# Localization keys — translator notes

Context for every key in `en.json`. Keys are grouped by namespace (the prefix
before the first dot). Placeholders in `{curly}` come from
`l10n-signatures.json` and must appear verbatim in every locale.

When a key has Bool/Optional branches (e.g. `memory.migrationDone.isolated` +
`memory.migrationDone.shared`), both sub-keys are documented together.

---

## create — `orrery create` wizard

| Key | Context |
| --- | --- |
| `create.abstract` | One-line command help shown by `orrery create --help`. |
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

## current — `orrery current`

| Key | Context |
| --- | --- |
| `current.abstract` | Command help. |
| `current.noActive` | Printed when no env is active. |

## delegate — `orrery delegate`

| Key | Context |
| --- | --- |
| `delegate.abstract` | Command help. |
| `delegate.envHelp` | `--env` flag help. |
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

## envVar — `orrery config` (env-var configuration)

| Key | Context |
| --- | --- |
| `envVar.abstract` | Parent command help. |
| `envVar.defaultNotSupported` | Error when targeting `origin`. |
| `envVar.envHelp` | `--env` flag help. |
| `envVar.noActive` | Error: no active env and `--env` not given. |
| `envVar.set` | Success: variable set. `{key}`, `{envName}`. |
| `envVar.setAbstract` | `set` sub-command help. |
| `envVar.unset` | Success: variable removed. `{key}`, `{envName}`. |
| `envVar.unsetAbstract` | `unset` sub-command help. |

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
| `list.empty` | Shown when no envs exist. Contains literal command `orrery create <name>`. |
| `list.header` | Currently unused (list now uses multi-line layout). Retained for compatibility. |

## mCPServerCmd / mCPSetup — MCP server commands

| Key | Context |
| --- | --- |
| `mCPServerCmd.abstract` | `orrery mcp-server` command help (parent of MCP stdio server). |
| `mCPSetup.abstract` | `orrery mcp` parent command help. |
| `mCPSetup.setupAbstract` | `orrery mcp setup` command help. |
| `mCPSetup.success` | Printed after successful setup. References slash commands `/orrery:delegate` etc. — keep them literal. |
| `mCPSetup.wroteSettings` | Printed while writing settings. `{path}` = settings file path. Ends with `\n`. |

## memory — `orrery memory`

| Key | Context |
| --- | --- |
| `memory.aborted` | Shown when the user declines a memory action. |
| `memory.abstract` | Parent command help. |
| `memory.actionExport` / `memory.actionInfo` / `memory.actionIsolate` / `memory.actionShare` / `memory.actionStorage` | Menu labels for the interactive memory prompt. |
| `memory.alreadyIsolated` / `memory.alreadyShared` | No-op messages when the env is already in the requested mode. |
| `memory.defaultNotSupported` | Error when operating on `origin`. |
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

## resume — `orrery resume`

| Key | Context |
| --- | --- |
| `resume.abstract` | Command help. |
| `resume.indexOutOfRange` | Error. `{index}` = requested; `{count}` = available. |
| `resume.noIndex` | Error when the user omitted the index. References `orrery sessions` — keep literal. |

## run — `orrery run`

| Key | Context |
| --- | --- |
| `run.abstract` | Command help. |
| `run.commandHelp` | Positional `command…` arg help. |
| `run.envHelp` | `--env` flag help. |
| `run.noCommand` | Error when no command followed. Contains literal example `orrery run -e work claude --resume <id>`. |

## sessions — `orrery sessions`

| Key | Context |
| --- | --- |
| `sessions.abstract` | Command help. |
| `sessions.noSessions` | Shown when no sessions exist for the project. |

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

## tools — `orrery tools`

| Key | Context |
| --- | --- |
| `tools.abstract` | Parent command help. |
| `tools.addAbstract` | `tools add` sub-command help. |
| `tools.addWizardTitle` | Title for the tool-add picker. `{envName}`. |
| `tools.added` | Success. `{tool}`. |
| `tools.defaultNotSupported` | Error when operating on `origin`. References `orrery create <name>` — literal. |
| `tools.envHelp` | `--env` flag help. |
| `tools.noActive` | Error: no active env. |
| `tools.noToolsToAdd` | Shown when every supported tool is already configured. `{envName}`. |
| `tools.noToolsToRemove` | Shown when the env has zero tools. `{envName}`. |
| `tools.removeAbstract` | `tools remove` sub-command help. |
| `tools.removeWizardTitle` | Title for the tool-remove picker. `{envName}`. |
| `tools.removed` | Success. `{tool}`. |

## update — `orrery update`

| Key | Context |
| --- | --- |
| `update.abstract` | Command help. |
| `update.notice` | One-line "update available" banner. `{current}`, `{latest}`. Keep the trailing `run: orrery update` hint literal. |
| `update.unsupportedPlatform` | Error on non-supported OS. URL kept literal. |
| `update.upgrading` | Progress line. |

## use — `orrery use`

| Key | Context |
| --- | --- |
| `use.abstract` | Command help. |
| `use.nameHelp` | Positional `name` help. |
| `use.needsShellIntegration` | Error when shell integration isn't installed. References `orrery setup` — keep literal. Has `\n`. |
| `use.switchedToOrigin` | Shown when switching back to `origin`. References `orrery use <name>` — literal. |

## which — `orrery which`

| Key | Context |
| --- | --- |
| `which.abstract` | Command help. |
| `which.noActive` | Error: no active env. |
| `which.toolHelp` | Positional `tool` help. Tool names literal. |
| `which.unknownTool` | Error for unrecognized tool. `{tool}`. |

---

## Conventions for translators

- **Tool names** (`claude`, `codex`, `gemini`), **command names** (`orrery`,
  `orrery create`, …), **shell names** (`bash`, `zsh`), and **URLs** are
  identifiers — never translate them.
- **`[Y/n]` / `[y/N]`** conventions should be preserved as-is; the parser
  reads these characters.
- **Trailing whitespace** in prompt strings is load-bearing (separates prompt
  from user input) — keep it.
- **`\n`** inside values is a literal line break in the terminal output —
  preserve placement so multi-line layouts still align.
- **Emoji** (`⚠️`, `✓`) is intentional UI; keep unless it violates the target
  locale's conventions.
