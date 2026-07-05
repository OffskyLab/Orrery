# Changelog

## v3.1.2 - 2026-07-05

### Fixed

- **Statusline runtime state (`cc-statusline/`) is now kept per-account** instead
  of being shared to the workspace. v3.1.1's launch-time linker pooled it across
  accounts pinned to the same workspace; it is now on the deny-list. Accounts
  already shared by 3.1.1 self-heal on the next `claude` launch — the workspace
  symlink is converted back to a per-account directory (the workspace copy is
  left untouched; removing a symlink never deletes data). `statusline.js` and the
  `settings.json` `statusLine` key were already per-account.

## v3.1.1 - 2026-07-04

### Added

- **Account config dirs now share *every* non-private folder with the pinned
  workspace, not a fixed list.** At launch, a deny-list linker moves each
  shareable top-level account dir into the workspace and symlinks it, so folders
  Claude adds over time (e.g. `skills`, `plugins`) are shared automatically
  across accounts on the same workspace — no code change needed. Only per-account
  state stays local: top-level files, dot-prefixed entries, and `backups/` +
  `cache/`. Merges are a union with the workspace winning; account-side conflicts
  are preserved under `backups/premerge-<timestamp>/`.

### Fixed

- Merge existence checks are now lstat-aware, so a dangling symlink in the
  workspace no longer aborts the merge (previously it failed permanently and
  never self-healed).
- The linker converts a directory to a symlink only after it fully drains, so a
  file written by a concurrently running session is never deleted; a non-empty
  remnant is left in place with a warning instead.
- `prepareDirectory` never relocates a real data directory into `backups/`, and
  now surfaces link warnings instead of silently succeeding.

## v3.1.0 - 2026-06-30

First stable v3.1 release. Per-account configuration directories: every Claude
account has its own `CLAUDE_CONFIG_DIR`, so switching accounts is a per-shell
environment change instead of a global keychain swap — no more cross-terminal
drift or mixed identity/plan displays. Workspaces hold the shared
session/memory/agents/commands/todos folders that account dirs symlink into, and
`~/.claude` points at the origin account dir so a bare `claude` at origin reads
the same config as `orrery use origin`. Third-party add-ons (e.g. `statusline`)
install into the account dir. See the rc.1–rc.14 entries below for the full set
of fixes folded into this release.

## v3.1.0-rc.14 - 2026-06-30

### Fixed

- **`orrery install` / `orrery thirdparty uninstall` now say "account" with the
  account name**, not "env 'origin'". Add-ons land in the account dir, so the
  confirmation now names the claude account (resolved from the active
  `CLAUDE_CONFIG_DIR`, else the env's pinned account).

## v3.1.0-rc.13 - 2026-06-30

### Fixed

- **`orrery install` no longer hangs.** `git` was run with an open stdin and the
  user's environment, so a fresh machine (or one with a `url.insteadOf`
  https→ssh rewrite and no `known_hosts` entry) could leave git/ssh blocked on an
  interactive prompt forever. `install` now runs git non-interactively
  (`GIT_TERMINAL_PROMPT=0`, ssh `BatchMode`, detached stdin) and drains its output
  without deadlocking, so it succeeds or fails fast with the git error.

## v3.1.0-rc.12 - 2026-06-30

### Fixed

- **`~/.claude` pointing at the origin account dir is now an ongoing invariant,
  not a one-shot migration.** Pointing `~/.claude` at the workspace is legacy
  behaviour; v3.1 wants it on the origin account dir (so bare `claude` at origin
  reads the same settings/statusline as `orrery use origin`). The repoint used to
  live inside a flag-guarded migration, so an install that still had `~/.claude`
  on the old workspace target stayed stuck once the flag was set. Now it self-heals
  on every `orrery` command. The origin takeover also recognises an account-dir
  `~/.claude` as managed, so it no longer tries to reclaim a repointed link.

## v3.1.0-rc.11 - 2026-06-30

### Fixed

- **`orrery list` shows the origin account as the active default again, and
  upgraded/3.0.4-damaged installs self-repair.** On installs upgraded through a
  3.0.4-damaged state, the origin workspace had lost its account pins (its
  `workspace.json` was missing), so `orrery list` showed no active default for any
  tool and `~/.claude` never got repointed at the origin account dir. Two changes:
  - `orrery list` now resolves the origin default active account from the config
    dir claude actually uses — `CLAUDE_CONFIG_DIR`, else `~/.claude` — instead of
    leaving it blank.
  - A one-time repair re-pins the pool account named `origin` to the origin
    workspace for each tool (recreating `workspace.json`), then re-runs the
    account-dir settings consolidation and the `~/.claude` repoint. Runs once
    automatically on the next `orrery` command.

## v3.1.0-rc.10 - 2026-06-30

### Fixed

- **Origin now reads the same account dir as `orrery use origin`, so statusline and
  settings are consistent.** The origin takeover captured your real `settings.json`
  (permissions, hooks, env, plugins) into the workspace, but Claude reads settings
  from the account dir (`CLAUDE_CONFIG_DIR`) — so add-ons installed into the origin
  account dir (rc.9) never showed for a bare `claude` at origin, which read the
  workspace instead. A one-time migration now:
  - folds each pinned workspace's `settings.json` into the account dir's
    `settings.json` (your values win; the workspace's `statusLine` is not inherited
    since it is per-account, owned by `orrery install`)
  - repoints `~/.claude` at the origin account dir, but only when it is the
    takeover-managed symlink into the workspace (never touches a real directory or a
    foreign symlink target)

  Result: bare `claude` at origin and `orrery use origin` read the same account dir;
  the workspace is left holding only the shared session/memory folders that account
  dirs symlink into. Runs automatically once on your next `orrery` command.

## v3.1.0-rc.9 - 2026-06-30

### Fixed

- **Third-party add-ons (e.g. `statusline`) now install into the account dir, not
  the workspace.** Claude reads `settings.json` and the statusline script only from
  `CLAUDE_CONFIG_DIR` (the account dir) — those are real files there, while only
  `projects`/`memory`/`agents`/`commands`/`todos` symlink to the shared workspace.
  Installing into the workspace was therefore invisible to Claude and the statusline
  never appeared. `orrery install` now targets the active account dir (the live
  `CLAUDE_CONFIG_DIR` exported by `orrery use`, else the claude account pinned to the
  env, origin by default). Add-ons are now per-account: run `orrery install <id>`
  while the target account is active. Existing installs in the workspace are orphaned
  and can be removed manually.

## v3.1.0-rc.8 - 2026-06-26

> Supersedes the withdrawn rc.5–rc.7 (those carried mis-targeted fixes that did
> not address the real root causes). rc.8 is the first build that fixes both the
> onboarding-loss and stale-email issues at their source.

### Fixed

- **`orrery add` no longer drops you back into the welcome/onboarding screen.**
  Root cause: `_account-add-finalize` imported only the keychain credential and
  then deleted the login staging dir, discarding the `.claude.json` Claude wrote
  during the session (`hasCompletedOnboarding`, onboarding flags, full
  `oauthAccount`). The account's identity file was seeded from the keychain
  alone, so every onboarding field was lost and `orrery use <name>` re-ran
  onboarding. finalize now captures that staging `.claude.json` (same split
  mechanism as `_capture-claude-exit`) into the identity + shared stores, keeping
  the keychain credential overlaid so tokens stay fresh. A newly added account is
  immediately usable — no welcome screen, no re-login.

- **`orrery list` now shows each Claude account's real current login.** The email
  and plan came from the `metadata.json` cache, which drifts: newer Claude
  versions stopped writing `oauthAccount.emailAddress` anywhere the pool refresh
  could re-derive it, so an account re-logged from one identity to another kept
  showing the old one. `list` now reads from the authoritative source —
  `claude-identity.json` (`oauthAccount.emailAddress` / `subscriptionType`),
  refreshed by `_capture-claude-exit` after every session — falling back to the
  live `CLAUDE_CONFIG_DIR` for the active account and the metadata cache only as a
  last resort. Logging out/in inside Claude is now reflected in `orrery list` with
  no manual step.

## v3.1.0-rc.4 - 2026-06-24

### Fixed

- **`orrery list` now correctly shows the active Claude account** after `orrery use`. 
  In v3.1, Claude account selection is handled by the shell function via 
  `CLAUDE_CONFIG_DIR`, but `list` was only reading from workspace metadata. 
  Now reads the account ID from the live `CLAUDE_CONFIG_DIR` and uses ISO8601 
  date decoding for metadata.json.

- **`orrery list` now reflects `/login` changes immediately**. Previously, 
  `list` read email/plan from the orrery pool's keychain copy (which doesn't 
  update when you `/login` in Claude Code). Now reads from the live 
  `CLAUDE_CONFIG_DIR` for active accounts, falling back to cached metadata 
  if unavailable.

### Added

- **Local testing installation scripts** for deploying development builds to 
  other machines:
  - `scripts/package-local.sh` — build and package release binary as tarball
  - `scripts/install-local.sh` — install from local tarball
  - `scripts/README.md` — usage instructions

## v3.1.0-rc.1 - 2026-05-28

**Release candidate.** Inviting real-world feedback on the v3.1 architecture
before tagging v3.1.0 final. Strongly recommend backing up `~/.orrery/`
before upgrading — migration is one-way (see "Known limitations" below).

### Changed — architectural rework

- **Each Claude account now has its own `CLAUDE_CONFIG_DIR`.** Pre-v3.1,
  switching accounts meant overwriting the active keychain item and
  `oauthAccount` in a shared config dir. That was the root cause of the
  identity/plan drift bug (e.g. `gradyzhuo@gmail.com, team` displays where
  email and plan came from different accounts), `/login` poisoning of pool
  slots, and mid-session `/status` flapping when another shell ran
  `orrery use`. v3.1 gives every claude account its own dir at
  `~/.orrery/accounts/claude/<id>/`; switching is just an env-var change.

- **Workspace content is shared via symlinks.** Each account dir contains
  symlinks for `projects/`, `memory/`, `agents/`, `commands/`, `todos/`
  pointing at a per-workspace `claude-workspace/` dir
  (`~/.orrery/envs/<workspace>/claude-workspace/`). Multiple accounts
  pinned to the same workspace see the same session/memory data.

- **`orrery use` no longer swaps keychain items.** The shell function
  exports `CLAUDE_CONFIG_DIR=<account-dir>` in the current shell. Running
  claude sessions in other terminals are unaffected — exactly the property
  v3.0.x couldn't deliver.

- **`claude` is now a shell-function wrapper** that merges the per-account
  identity store and the per-workspace shared store into `.claude.json` at
  launch, then splits the post-session state back into the two stores on
  exit. Identity and shared state stay physically separate; no more
  mixed-source displays. Plain `claude` invocations without
  `CLAUDE_CONFIG_DIR` set continue to work unchanged (legacy passthrough).

- **`orrery workspace` replaces `orrery sandbox`** as the user-facing
  vocabulary. `orrery sandbox` is removed from `--help`; existing scripts
  that referenced it must switch. `--workspace` / `-w` flag aliases were
  added to `set-env` / `unset-env` alongside the older `--sandbox` / `-s`
  (both work).

### Added — new commands

- `orrery pin <account> --workspace <name>` — pin an account to a workspace
  (sets its symlinks). Default workspace: `origin`.
- `orrery migrate-to-v3.1` — manually re-run the v3.1 account-layout
  migration. Idempotent. Useful for the rare case where an account was
  added before the auto-migration flag was written.
- `orrery workspace …` — alias for the (now-removed-from-public) `orrery
  sandbox …` command set.

### Migration

- **Auto-runs on first invocation** after upgrade. Existing pool accounts
  get their v3.1 dir + symlinks + `claude-identity.json` seeded
  automatically. Flag-guarded so subsequent invocations are no-ops.
- **Non-destructive.** Existing v3.0.4 keychain items, `oauthAccount.json`
  snapshots, and `metadata.json` files remain in place. If something goes
  wrong, the user can recover by removing the v3.1 additions (`rm -rf
  accounts/claude/<id>/{projects,memory,agents,commands,todos,claude-identity.json}`)
  and downgrading the binary.

### Removed

- `KeychainCredentialAdapter` — the macOS claude `materialize` / `syncBack`
  pair. Claude no longer needs binary-side credential copies; the per-account
  dir + shell wrapper handle everything.
- `ClaudeOAuthSnapshot` — v3.0.4's per-pool `oauthAccount.json` snapshot,
  superseded by per-account `claude-identity.json`.
- `ToolAuth.liveActiveInfo` — v3.0.3's live-read shim for display. v3.1
  reads stored `Account.email` / `plan` directly (refreshed by capture).
- `orrery sandbox` from `--help` — `orrery workspace` is the canonical entry.

### Known limitations

- **Origin's existing `~/.claude/projects/` session content is NOT migrated**
  into the new workspace-shared dir. v3.1 sessions start fresh inside each
  workspace; old sessions remain accessible via direct `~/.claude` use but
  won't appear under `orrery use origin && claude --resume`. A future plan
  will address this.
- **Migration is one-way.** No `migrate-back-to-v3.0.4`. Downgrading the
  binary alone leaves v3.1 layout files in place that may confuse a v3.0.4
  binary. Back up `~/.orrery/` before upgrading if you want a clean
  rollback path.
- **`EnvironmentStore.loadOriginConfig` reads production-path data** even
  when `ORRERY_HOME` is set to a non-default location. Pre-existing v3.0.x
  bug, not introduced by v3.1, but may surface with side-by-side test
  installs.
- **`ClaudeJsonMerge` field categorization is hardcoded.** New top-level
  keys claude adds in future versions default to per-account (conservative).
  Will need updates as claude evolves.

## v3.0.4 - 2026-05-27

### Fixed

- **`orrery list` / `orrery show` no longer mix email and plan from different
  identities.** Claude's login state lives in two places — the keychain
  credential (token + plan) and `.claude.json`'s `oauthAccount` (email + org
  info). `KeychainCredentialAdapter` only synced the keychain side; the
  `oauthAccount` block in the active `.claude.json` was left pointing at the
  previously-active identity. Every `orrery use` drifted the two sources apart,
  producing displays like `gradyzhuo+team` where the email was from one account
  and the plan from another, and `refreshInfo` then cached the mixed pair into
  pool metadata.

  The pool now stores an `oauthAccount.json` snapshot alongside the
  credential. `prepareMaterialize` writes it into the active `.claude.json`
  (preserving other top-level keys) so both stores describe the same
  identity. `prepareSyncBack` and `AccountLoginFlow.importFrom` capture
  fresh snapshots from the active / staging `.claude.json`. `Account.refreshInfo`
  reads email from the pool snapshot (no longer from active `.claude.json`),
  eliminating the cross-source mixing.

  Includes a one-shot backfill: for existing pool slots without snapshots,
  best-effort capture from any referencing env's `.claude.json` and re-derive
  cached email/plan. Slots with no referencing env stay un-snapshotted until
  the user touches them once — pin to a sandbox and `enter` / `exit` (or any
  `orrery use` cycle) and the post-materialize active state becomes the
  snapshot.

## v3.0.3 - 2026-05-27

### Fixed

- **`orrery list` / `orrery show` no longer go stale after a `/login`.** The
  active pin's `email` / `plan` are now read live from the active config
  dir (Claude: `.claude.json` for the canonical email + the active Keychain
  item for plan), instead of from the pool-side stored fields that only
  refreshed on `orrery run claude` sync-back. Out-of-band credential changes
  — `/login` inside Claude Code, manual edits — show up immediately on the
  next `list` / `show`. Non-active rows still use stored fields (cheap).

## v3.0.2 - 2026-05-22

### Fixed

- **Phantom switching works again.** `/orrery:phantom <account>` failed with
  `claudeNotFound` on every Bun-native Claude Code install: the supervised
  process was matched by an exact comm of `claude`, but the Bun-compiled
  binary runs as `claude.exe`. The match now accepts `claude` with any
  extension. The phantom supervisor loop also tried to apply an account
  switch with the removed v2-era `orrery account use` — corrected to the
  v3 top-level `orrery use`. When the claude process can't be located, the
  failure now prints the walked process ancestry for diagnosis.

### Changed

- **Minimum macOS is now 15 (Sequoia).** The deployment target moved up from
  macOS 13 so the codebase can adopt the standard-library `Mutex` from
  `Synchronization` (cross-platform, unlike the Apple-only `os` lock).
- **All Objective-C bridge types removed.** `NSString`, `NSLock`,
  `NSRegularExpression` / `NSRange`, `NSUserName()`, and `ObjCBool` are
  replaced with native Swift — `URL` path APIs, Swift `Regex`, `Mutex`, and
  `URL.resourceValues`.

## v3.0.1 - 2026-05-22

### Changed

- **`orrery list` shows the active context.** When a non-origin sandbox is
  active, `orrery list` prints a `sandbox: <name>` header. Within each tool
  group, the account pinned for the current sandbox is marked with a `●`
  bullet; the rest keep `-`. Origin prints no sandbox header (origin is the
  absence of a sandbox). The pins are read from the active env's config — the
  same source `orrery show` uses.

## v3.0.0 - 2026-05-22

### Breaking — command surface restructured

The CLI is reshaped around the v3 mental model: **accounts** and **sandboxes** are two independent layers, and **origin** is a *state* (no sandbox active), not a sandbox name.

- **Account commands promoted to top level.** `orrery account add/list/show/use/remove` becomes `orrery add/list/show/use/remove`. The bare `orrery use <name>` is now the **account** switcher (was the sandbox switcher in v2).
- **Sandbox subgroup formed.** Per-sandbox CRUD and tooling moves under `orrery sandbox <verb>`: `set-env`, `unset-env`, `create`, `list`, `delete`, `info`, `rename`, `current`, `memory`, `sync`, `export`, `unexport`.
- **`orrery enter <sandbox>` / `orrery exit`** are the new sandbox state verbs:
  - `orrery enter <sandbox>` — opt into a sandbox.
  - `orrery exit` — return to origin. `orrery enter origin` is rejected and points the user at `exit` (origin is the absence-of-sandbox state, not a sandbox to enter).
  - Transparent switch: `enter X` while in sandbox Y unexports Y, exports X, no need to `exit` first.
- **`orrery deactivate` removed** — replaced by `orrery exit`.
- **`orrery use <env>` (v2 sandbox switch) removed** — see migration table below.
- **`orrery sandbox use` removed entirely** — was a brief stepping stone during v3 dev; `enter`/`exit` are the only sandbox state verbs.
- **`orrery auth ...` removed** — credentials are managed via the account pool (`orrery add/list/show/remove`).
- **`orrery origin status/release` removed** — `orrery uninstall` is the supported way to release.
- **`/orrery:phantom` slash command** now treats a bare name as an **account** switch; sandbox switches use the explicit `sandbox` keyword (e.g. `/orrery:phantom sandbox <name>`). The phantom-supervisor loop in the generated shell function translates `TARGET_SANDBOX=origin` to `orrery exit`, other values to `orrery enter $TARGET_SANDBOX` — the sentinel format is unchanged.

### Migration table

| v2 | v3 |
|---|---|
| `orrery account add` | `orrery add` |
| `orrery account list` | `orrery list` |
| `orrery account show` | `orrery show` |
| `orrery account use` | `orrery use` |
| `orrery account remove` | `orrery remove` |
| `orrery use <sandbox>` | `orrery enter <sandbox>` |
| `orrery deactivate` | `orrery exit` |
| `orrery create <name>` | `orrery sandbox create <name>` |
| `orrery delete <name>` | `orrery sandbox delete <name>` |
| `orrery rename <old> <new>` | `orrery sandbox rename <old> <new>` |
| `orrery list` (envs) | `orrery sandbox list` |
| `orrery info [name]` | `orrery sandbox info [name]` |
| `orrery current` | `orrery sandbox current` |
| `orrery env set <K> <V>` | `orrery sandbox set-env <K> <V>` |
| `orrery env unset <K>` | `orrery sandbox unset-env <K>` |
| `orrery memory <op>` | `orrery sandbox memory <op>` |
| `orrery sync <op>` | `orrery sandbox sync <op>` |
| `orrery auth store` | (removed; use `orrery show` or `orrery list`) |
| `orrery origin status` | (removed; `orrery sandbox info origin` shows origin state) |
| `orrery origin release` | `orrery uninstall` |

### Internal / housekeeping

- **`PhantomTriggerCommand` renamed** to `PhantomSandboxTriggerCommand`; sentinel field `TARGET_ENV` renamed to `TARGET_SANDBOX`.
- **`AuthCommand` and `OriginCommand` removed.** Dead-code branches that checked for `origin release` were pruned from `OriginTakeoverBootstrap`.
- **L10n keys** renamed `use.*` → `enter.*` / `exit.*`; three new keys (`enter.cannotEnterOrigin`, `exit.abstract`, `exit.alreadyAtOrigin`). Hint strings across `en` / `zh-Hant` / `ja` updated in lockstep.
- **`SandboxCommand.Use`** Swift stub removed; the shell function's `sandbox)/use)` dispatch arm is gone too.
- **Tests:** 243 passing across 61 suites. `ShellFunctionGeneratorTests` and `PhantomTriggerTests` updated with negative assertions guarding against any return of `orrery sandbox use`.

## v2.8.0 - 2026-05-20

### Added

- **Accounts pool — switch AI tool accounts without managing environments.**
  Tool credentials (Claude / Codex / Gemini) now live in a shared pool at
  `~/.orrery/accounts/<tool>/<id>/`, decoupled from environments. New users who
  only need to rotate between accounts no longer have to learn the environment
  model.
- **`orrery account` command family:**
  - `orrery account add [--claude|--codex|--gemini] --name <name>` — register a
    new account and run the tool's login flow.
  - `orrery account list [--claude|--codex|--gemini]` — list accounts in the pool.
  - `orrery account show` — show which account each tool has pinned in the
    active environment.
  - `orrery account use [--tool] --name <name>` — pin an account to the active
    environment (origin by default).
  - `orrery account remove [--tool] --name <name>` — remove an account; blocked
    if any environment still references it.
- **`/orrery:phantom account <tool> <name>`** — switch a tool's account
  mid-conversation inside a phantom-supervised Claude session, without leaving
  the current environment.
- `Account` now records `email` and `plan` directly on the model, displayed by
  `orrery account list` and `orrery account show` without re-reading credentials
  each time. These fields are populated automatically when an account is added,
  migrated, or synced back after use. A one-time backfill populates them for
  accounts created before this change.

### Changed

- `orrery account add --claude` now spawns Claude through the orrery shell
  function so the REPL gets a proper foreground TTY process group; the Claude
  onboarding wizard guides login naturally. codex/gemini account-add continue
  to use the Swift `Process` path (their login subcommands are browser-based
  and do not need TTY foreground).
- Environments now reference accounts by id (`OrreryEnvironment.accounts`)
  rather than owning credentials directly.
- Account switching (`orrery account use`) now materializes credentials
  immediately — it syncs the previously pinned account's credentials back into
  the pool, then places the newly pinned account's credentials into the slot the
  tool reads. A plain `claude` / `codex` / `gemini` invocation therefore uses the
  switched account; `orrery run` is no longer required for account switching.
- Credentials refreshed by a tool are synced back into the accounts pool when
  switching away from an account, so macOS Claude account switching stays valid
  across token rotations.

### Migration

- On first run, orrery automatically migrates existing per-environment
  credentials into the accounts pool (deduplicating shared credentials). A full
  backup of `~/.orrery/` is taken first, to `~/.orrery-backup-<timestamp>/`.
- If you run phantom-supervised Claude sessions, exit them before the first run
  of v2.8.0 so the migration is not disturbed.

## v2.7.0 - 2026-04-29

### Architecture

- **Spec runtime moved to `orrery-magi` v1.1.0; `orrery-bin` is now a thin
  forwarder.** `orrery magi`, `orrery spec`, `orrery spec-run`, and the hidden
  `orrery _spec-finalize` shim still work exactly as before, but `main.swift`
  now intercepts those entrypoints and execs `orrery-magi` transparently. The
  spec generator, implement runner, verify runner, prompt builder, acceptance
  parser, sandbox policy, and template/profile/progress helpers all live in
  the sidecar. `install.sh` and the Homebrew formula auto-install the sidecar
  so the move is invisible from the user's side.
- **`orrery delegate --resume <id|index>` — native session resume.** Accepts a
  full session UUID, short prefix, or numeric index (matching the order shown
  by `orrery sessions`) and forwards to the delegate tool's native resume
  mechanism (`claude --resume`, `codex resume`, `gemini --resume`). Index
  resolution is scoped to the active environment + tool, so the same numeric
  "1" is unambiguous across runs.
- **`orrery delegate --session` / `--session-name <name>` — managed session
  picker + named resume.** Without a name, opens an interactive picker over
  all managed sessions across tools and envs (tool icon, env name, last-used
  time, first user message preview). With a name, resumes that mapping
  directly and auto-infers the tool from the saved entry. Mappings persist in
  `~/.orrery/sessions/mappings.json` and survive across machines via
  orrery-sync. `--session` / `--session-name` / `--resume` are mutually
  exclusive.

### MCP

- **Spec MCP tools are now sidecar-forwarded at startup.** `orrery-bin`
  handshakes with `orrery-magi --capabilities`, then fetches tool schemas
  with `--print-mcp-schemas` (plural) and registers live forwarders for
  `orrery_magi`, `orrery_spec`, `orrery_spec_verify`, and
  `orrery_spec_implement`. `orrery_spec_status` stays inline in `orrery-bin`
  because it only reads local state via `SpecRunStateReader.load()` — no
  sidecar fork on every poll.
- **Graceful degradation when the sidecar is missing or older.** Two
  layers:
  1. **MCP server startup is best-effort.** If `orrery-magi` cannot be
     resolved, `orrery-bin mcp-server` logs an install hint to stderr
     and starts anyway, exposing only the in-process built-in tools
     (`orrery_list` / `orrery_sessions` / `orrery_delegate` /
     `orrery_current` / `orrery_memory_read` / `orrery_memory_write`).
     Pre-v2.7.0 behavior would `exit 1` and leave the AI tool with no
     orrery MCP at all.
  2. **Older sidecar without `features.multi_tool_schema`.** The shim
     falls back to the legacy single-schema `--print-mcp-schema` path
     and only exposes `orrery_magi`; spec MCP tools are not registered.
- **Caveat: CLI `spec` / `spec-run` paths require a v1.1.0+ sidecar.**
  `main.swift` forwards `orrery spec` / `orrery spec-run` /
  `orrery _spec-finalize` unconditionally to the resolved sidecar; if
  the sidecar is v1.0.0 (no spec subcommands) the user sees an
  ArgumentParser error from orrery-magi rather than a friendly
  unsupported-version message. `install.sh` and the Homebrew formula
  pin v1.1.0 minimum so this is only reachable with a manually
  downgraded `~/.orrery/bin/orrery-magi`.

### Slash commands (`orrery mcp setup`)

- **New: `/orrery:spec-implement` and `/orrery:spec-status`.** `orrery mcp
  setup` now writes `.claude/commands/orrery:spec-implement.md` and
  `orrery:spec-status.md` so the new spec MCP tools are reachable from the
  chat box.
- **Updated: `/orrery:magi` adds a `/grill-me` pre-flight hint.** When the
  topic touches product strategy, release planning, scope boundaries, or
  has unstated constraints, the slash command body now suggests running
  `/grill-me` first to surface assumptions before multi-agent debate burns
  rounds on the wrong premise.

### Bug fixes

- **`orrery delegate -e <env>` now propagates `ORRERY_ACTIVE_ENV`.** Explicit
  `-e` was silently dropped from the child process environment, so nested
  `orrery` / `orrery-magi` invocations resolved the wrong env. Fixed by
  always injecting `ORRERY_ACTIVE_ENV=<env>` into the spawned child.
- **Atomic state-file writes (`~/.orrery/spec-runs/{id}.json`).** Writes now
  go to a UUID-suffixed tmp file in the same directory and rename onto the
  target via POSIX `rename(2)`. The previous path used `Data.write(.atomic)`
  whose internally-chosen tmp suffix could collide with concurrent writers.
- **Concurrent resume guard.** Two simultaneous `spec-implement --resume <id>`
  calls now race on `flock(LOCK_EX)` instead of both observing a non-running
  state and stomping each other's writes; the loser sees
  `SpecRunStateError.sessionAlreadyExists`.
- **Test binary path.** CLI roundtrip tests now reference
  `.build/debug/orrery-bin` (the actual product name) instead of the legacy
  `.build/debug/orrery` so they no longer silently `XCTSkip`.
- **In-flight v2.6.x implement sessions still finalize after upgrade.** The
  hidden `_spec-finalize` first-argument shim forwards to `orrery-magi`, so
  detached wrapper scripts launched before upgrading can still complete and
  write terminal state once `orrery-magi` is installed.

### Performance & runtime

- **`PhantomTrigger.readProcessInfo` uses `sysctl(KERN_PROC_PID)` first.**
  The new fast path avoids a `ps` subprocess on Darwin (no fork+exec) and
  also works inside sandboxed environments where spawning `ps` is denied.
  The existing `ps` invocation is kept verbatim as a fallback.
- **Strict orrery-magi sidecar handshake.** `MagiSidecar.resolve()` validates
  `$schema_version`, `compatibility.shim_protocol`, and the resolved binary
  version against the shim's supported range. Missing or incompatible
  sidecars hard-fail with an install hint
  (`brew install offskylab/orrery/orrery-magi`).
- **`UninstallCommand` removes the sidecar.** `orrery uninstall` now also
  deletes `~/.orrery/bin/orrery-magi` (best-effort — sidecar removal failure
  does not block the rest of uninstall).

### Spec pipeline (still in v2.7.0, runtime executes in `orrery-magi`)

- **`orrery spec-run --mode verify`.** MVP for the discuss → spec → implement
  loop. Consumes structured markdown from `orrery spec` and verifies its
  `## 驗收標準` section. Default dry-run; `--execute` to run sandboxed
  commands; `--strict-policy` to fail on policy_blocked.
- **`orrery spec-run --mode implement`.** Hands the spec to a delegate agent
  in a detached subprocess. Returns immediately with `session_id` +
  `status: "running"`; a wrapper shell owns the lifecycle (timeout watchdog,
  stdout/stderr redirection, `_spec-finalize` callback). DI5 safety net
  rejects specs missing any of the four mandatory headings (`介面合約` /
  `改動檔案` / `實作步驟` / `驗收標準`) before any subprocess launches.
- **`orrery spec-run --mode status`.** Polling companion. Reads the persisted
  session JSON, supports `--include-log` to tail the progress jsonl and
  `--since-timestamp` for incremental polling. Suggested cadence (in the
  tool description): first poll ~2s, then exponential backoff
  `min(30s, prev * 1.5)`, settling at 30s.
- **`SpecAcceptanceParser` heredoc awareness.** Recognises `<<EOF` /
  `<<'EOF'` / `<<"EOF"` / `<<-EOF` blocks inside acceptance code fences and
  keeps the entire heredoc as a single command. Previously JSON-RPC bodies
  inside `cat <<'EOF' | ...` were split line-by-line and mis-classified.
- **`SpecSandboxPolicy` for spec verification.** Three layers of defence:
  dry-run default, allowlist (word-boundary) + blocklist (substring,
  evaluated first) on shell commands, and hard runtime caps (60s per
  command, 600s overall, 1MB stdout per command with `…[truncated]` marker).
  Python snippets go through a regex-based deny-list lint.
- **`DelegateProcessBuilder` gains `OutputMode`.** New `.capture` mode pipes
  stdout to a `Pipe` for programmatic reading; existing `.passthrough` mode
  is the default — no change to `delegate` or other call sites.

### Public API surface

- **Removed from `OrreryCore`** (now in `orrery-magi`): `SpecGenerator`,
  `SpecImplementRunner`, `SpecVerifyRunner`, `SpecPromptBuilder`,
  `SpecPromptExtractor`, `SpecAcceptanceParser`, `SpecSandboxPolicy`,
  `SpecTemplate`, `SpecProfileResolver`, `SpecProgressLog`, `SpecCommand`,
  `SpecRunCommand`, `SpecFinalizeCommand`. Public spec writers
  (`SpecRunStateStore.write` / `.update` / `.createInitial`) are gone.
- **Kept public in `OrreryCore`** (read-side contract): `SpecRunState`,
  `SpecRunStateReader` (alias `SpecRunStateStore`), `SpecRunResult`,
  `SpecStatusResult`, `SpecRunStateContract`, `SpecRunStateError`. Status /
  result consumers continue to work without depending on `orrery-magi`.
- **New: `SpecRunStateContract`.** Versioned schema contract for
  `~/.orrery/spec-runs/{id}.json`. `currentVersion = 1`, `supportedVersions`
  range, and an `upgrade(_:)` hook so future schema bumps don't change call
  sites. Legacy state files (pre-v2.7.0) decode as v1 via
  `decodeIfPresent ?? 1`.
- **Environment inheritance contract is now explicit: no filtering.**
  `orrery` inherits all parent environment variables from the shell or MCP
  transport, and `orrery-magi` inherits all environment variables from
  `orrery`. The only env var orrery synthesises is `ORRERY_ACTIVE_ENV` when
  `delegate -e <env>` is given.
- **Internal: `AgentExecutor` protocol + `ProcessAgentExecutor`.** Generic
  subprocess abstraction in `OrreryCore`, shared by the spec pipeline (now
  in `orrery-magi`) and the sidecar dispatch path.

## v2.6.2

- **`/orrery:phantom` now installed by `orrery mcp setup` too.** v2.6.0–v2.6.1 only installed the slash command globally to `~/.claude/commands/`, which only Claude reads when `CLAUDE_CONFIG_DIR` is unset (i.e. only in the `origin` env). For non-origin envs, `CLAUDE_CONFIG_DIR` redirects user-level commands to the env's claude config dir, so the global file isn't found. `orrery mcp setup` now writes a project-local copy to `<project>/.claude/commands/orrery:phantom.md` (alongside the existing delegate/sessions/resume commands) — project-local commands are read regardless of `CLAUDE_CONFIG_DIR`, making `/orrery:phantom` available in any env where mcp setup has been run for the project.

## v2.6.1

- **Fix `/orrery:phantom` failing under Claude Code's caffeinate wrapper.** Newer Claude Code builds re-exec under `caffeinate` to keep the system awake during long sessions, so the process tree becomes `supervisor → caffeinate → claude`. v2.6.0's trigger required `claude.ppid == supervisor` directly and silently fell through with "Could not find a running claude process under the phantom supervisor". The trigger now walks up the full parent chain to the supervisor and kills the outermost claude on the way, so any wrapper layer (caffeinate, future variants) is handled transparently.
- **`install.sh`: strip macOS quarantine xattr + re-adhoc-sign before running setup.** Curl-pipe installs left `com.apple.quarantine` on `/usr/local/bin/orrery-bin`; macOS Gatekeeper SIGKILLs the binary on first launch with exit 137 ("Killed: 9"), which killed the post-install `orrery-bin setup` step. install.sh now does `xattr -c` + `codesign --force --sign -` after the binary lands in `/usr/local/bin`. Also fix the cosmetic "Orrery installed installed." message that fired when the SIGKILL'd `--version` probe fell back to the literal string `"installed"`.

  
## v2.6.0

- **Phantom env switching: `/orrery:phantom <env>` swaps the orrery environment without losing the Claude conversation.** `orrery run claude` is now phantom-supervised by default — when the slash command fires, Claude exits and the supervisor relaunches it with the new env active and `--resume <session-id>`, so the conversation continues uninterrupted across account switches. Opt out with `orrery run --non-phantom claude`.
- **Implementation**: a shell supervisor loop in `activate.sh` directly fork/execs claude (no PTY plumbing), a hidden `_phantom-trigger` subcommand walks up its own parent chain to find the supervised claude (robust against claude's internal forking — it's a Bun-compiled Mach-O), discovers the active session id via `<CLAUDE_CONFIG_DIR>/projects/<encoded-cwd>/<id>.jsonl` highest mtime, and signals claude to exit. The slash command markdown is installed globally to `~/.claude/commands/orrery:phantom.md` by `orrery setup`, so it's available in every project regardless of whether `orrery mcp setup` was run there.

## v2.5.0

- **`orrery install <id>` is now a top-level command.** The previous `orrery thirdparty install` is replaced by `orrery install`, matching `npm install` / `brew install` conventions. `uninstall`, `list`, and `available` remain under `orrery thirdparty` because the top-level slots are taken by orrery's own commands.
- **`--url` overrides the manifest source URL.** `orrery install statusline --url https://github.com/me/my-fork` keeps the manifest's install steps (copy `statusline.js`, patch `settings.json`) but pulls source from a custom git repository.
- **Statusline package renamed `orrery-statusline` → `statusline`.** The legacy id still resolves so existing lock files can be uninstalled, but it is hidden from `orrery thirdparty available`.
- **`"ref": "latest"` resolves to the newest version tag.** GitSource now interprets `latest` by calling `git ls-remote --tags --refs --sort=-v:refname` and picking the topmost semver tag (with `versionsort.suffix=-` so `0.2.5` beats `0.2.5-rc1`). The bundled statusline manifest now uses `latest` instead of `main`, so each install pulls the newest release rather than tracking an unstable branch.
- **`CODEX_HOME` for codex env isolation (was `CODEX_CONFIG_DIR`).** Codex CLI reads `CODEX_HOME`, not `CODEX_CONFIG_DIR` — the old variable was set but ignored, silently falling back to `~/.codex`. `orrery delegate --codex`, `orrery run -t codex`, and `orrery export` now correctly point Codex at the per-env config dir.

## v2.4.7

- **`orrery create claude` prompts to install `orrery-statusline`.** After completing the Claude tool wizard, the `create` command now asks whether to install the statusline (default: yes). Answering yes runs `orrery thirdparty install orrery-statusline` automatically during environment creation.
- **`orrery-statusline` replaces `cc-statusline`.** The built-in third-party registry entry is now `orrery-statusline`; `cc-statusline` has been removed.
- **`orrery thirdparty install` shows the installed ref.** The success message now includes the manifest ref and resolved commit SHA, e.g. `orrery-statusline v0.2.2@470e718 (3 files) → myenv`.

## v2.4.6

- **`orrery-statusline` thirdparty package.** New built-in package `orrery-statusline` — a lightweight Claude Code statusline showing Orrery environment name, working directory, git branch, 5h/7d quota bars, env path, and memory path. Install with `orrery thirdparty install orrery-statusline`. Quota and auth data reflect the active environment's account.

## v2.4.5

- **`orrery thirdparty` works in the origin environment.** Installing or uninstalling packages while in `origin` previously crashed with "Environment 'origin' not found" because the store only searches `~/.orrery/envs/`. The runner now routes `origin` directly to `originConfigDir`, the correct storage path.
- **`install.sh` installs the resource bundle on Linux.** The script previously only copied `orrery_OrreryThirdParty.bundle` (macOS); Linux tarballs include `orrery_OrreryThirdParty.resources` instead, which was silently skipped. Both suffixes are now handled.

## v2.4.4

- **`orrery uninstall` removes the binary.** After clearing shell integration and restoring managed configs, uninstall now also deletes `orrery-bin` from its install location. Complete removal in one command.
- **`orrery thirdparty` fatal error on install fixed.** The `OrreryThirdParty` resource bundle was missing from release tarballs and deb packages — only `orrery-bin` was packaged. CI now includes `orrery_OrreryThirdParty.bundle` alongside the binary; `install.sh` installs it to the same directory.

## v2.4.3

- **`orrery thirdparty` command.** New subcommand group for managing third-party plugin packages: `install <id>`, `uninstall <id>`, `list`, and `available`. Packages are fetched from Git (with a local vendored cache for offline use) and installed into the active environment's tool config directory via a declarative manifest. `--env` is optional on all subcommands — defaults to the current active environment (`ORRERY_ACTIVE_ENV`).
- **`orrery uninstall` fully removes the lazy-bootstrap stub.** The old line-filter left `orrery() { … }` behind after uninstall because it only caught the comment and `source` lines. The uninstaller now reuses the same block-stripping logic as `orrery setup`, which handles all three historic rc-file shapes correctly.
- **Dynamic update notice.** When `orrery _check-update` detects a newer release, it also fetches `docs/update-notice.md` from the repo's `main` branch and appends any matching message to the "new version available" line. Notices are filtered by an `applies-to:` frontmatter constraint (supports `<`, `<=`, `=`, `>=`, `>` with comma-separated AND), cached with HTTP `If-None-Match`, and served from cache on transient network failure. Failure is always silent.

## v2.4.1

- **`activate.sh` self-heals after `brew upgrade`.** The generated script now carries a version stamp on the first line. On every new shell, `_orrery_init` compares the stamp against the installed binary version. If they differ — e.g. because `post_install` was silently skipped — it runs `orrery-bin setup` to regenerate and immediately re-sources the file, so the shell heals itself without any manual intervention.
- **`orrery create` / `orrery tools add`: clone no longer copies account-specific data.** The blocklist expanded from 4 items to 20. Skipped: `cache/`, `agent-memory/`, `statsig/`, `stats-cache.json`, `telemetry/`, `usage-data/`, `mcp-needs-auth-cache.json`, `paste-cache/`, `shell-snapshots/`, `history.jsonl`, `file-history/`, `debug/`, `downloads/`, `plans/`, `tasks/`, `todos/`. Kept: `settings.json`, `commands/`, `skills/`, `plugins/`, `agents/`, `CLAUDE.md`, `statusline.sh`.
- **Claude install command updated to native installer.** Changed from `npm install -g @anthropic-ai/claude-code` to `curl -fsSL https://claude.ai/install.sh | bash` (run via `sh -c` to handle the pipe). `installCommandDisplay` added for human-readable output in prompts and error messages.
- **`ToolSetup` install errors now show the manual command.** `SetupError.installFailed` conforms to `LocalizedError`; on failure the message shows the exact command to run manually. The alternate-screen buffer (`\e[?1049h`/`l`) around `npm install` was removed — it was hiding npm's error output from the user.
- **`OrreryVersion.current` single source of truth.** Version string previously duplicated in `OrreryCommand`, `MCPServer`, and `ShellFunctionGenerator` — now all reference one constant.

## v2.4.0

- **Binary renamed `orrery` → `orrery-bin`.** The `orrery` command is now exclusively a shell function (defined in `~/.orrery/activate.sh`), removing the class of bugs where users accidentally invoked the binary in a shell that hadn't sourced the activation script. The binary itself is an implementation detail called by the shell function.
- **Lazy-bootstrap stub in rc file.** `orrery setup` now writes a tiny stub `orrery()` function to your rc file instead of a `source ~/.orrery/activate.sh` line. Shell startup is effectively free — activate.sh is loaded on first `orrery` invocation. Existing source lines / legacy `eval "$(orrery setup)"` shapes are migrated automatically.
- **Install / upgrade cleanup.** Both `install.sh` and the Homebrew formula remove the legacy `/usr/local/bin/orrery` (and `/opt/homebrew/bin/orrery`) binary so the shell function is the only path. The install tarball now ships `orrery-bin`; `install.sh` also accepts older tarballs that still contain `orrery` so the transition doesn't brick existing curl installs.
- **MCP integration points at `orrery-bin`.** `orrery mcp setup` registers `orrery-bin mcp-server` as the MCP server path, since MCP hosts launch servers as non-interactive subprocesses that never run the shell function.

## v2.3.3

- **Install via curl script; APT dropped.** Recommended install is now `curl -fsSL https://offskylab.github.io/Orrery/install.sh | bash` for macOS / Linux / WSL. Homebrew remains as an alternative for macOS. APT repo is retired.
- **`orrery update` smarter.** On macOS, detects `brew list orrery` and uses `brew upgrade` when installed via Homebrew; otherwise re-runs the install script. On Linux, always re-runs the install script.
- **`orrery setup` auto-runs after install.** Both `install.sh` and the Homebrew formula's `post_install` hook now invoke `orrery setup` immediately, so a single install command is enough to generate `activate.sh`, patch your rc file, and perform origin takeover.
- **Docs aligned with Claude's install layout.** Native Install (recommended) first, Homebrew (macOS) second, WSL note for Windows; origin reframed as Orrery's default-managed environment rather than a system passthrough.

## v2.3.2

- **Fix `orrery info origin` claude missing email/plan.** Under `origin` `CLAUDE_CONFIG_DIR` is unset — Claude stores its credential under the default Keychain entry and `~/.claude.json` at home root, not inside the managed dir. `orrery info` and `orrery auth store` now follow this convention for origin claude lookup.
- **Claude credential lookup on Linux.** Reads `{configDir}/.credentials.json` (Claude Code's non-macOS format) instead of falling through to macOS Keychain code.
- **`orrery create --clone` copies only useful settings.** Skips cache/telemetry/session-ephemeral dirs. Only `settings.json`, `commands/`, `skills/`, `plugins/`, `agents/`, `CLAUDE.md`, and `statusline.sh` carry over.
- **Claude install uses the native installer.** `orrery setup` / `orrery tools add` switch from `npm install -g` to `curl -fsSL https://claude.ai/install.sh | bash`. Install errors now surface the manual install command on failure.
- **Docs.** GitHub Pages aligned with README — added "The Model" section (Environment / Session / MCP Delegation) and origin management commands (`orrery origin status/release/uninstall`) in the Origin section.

## v2.3.1

- **`orrery auth show` renamed to `orrery auth store`.** Reflects that the command displays credential store locations (keychain service name, file path, masked API key). Removed separate `--filename` and `--masked-key` flags — all store info is shown together.

## v2.3.0

- **`orrery auth show` new command.** Displays credential info for tools in an environment. Supports `--env`, `--claude`/`--codex`/`--gemini` filters, `--filename` (keychain service name or credential file path), and `--masked-key` (masked API key). When a specific tool flag is given, output is plain (scriptable). When no tool flag is given, output is grouped with headers.
- **`orrery info` shows auth detail per tool.** Claude shows the Keychain service name (`keychain: Claude Code-credentials-{hash}`), Codex and Gemini show the credential file path. Masked API key is shown in the summary line when the tool uses API key auth mode.

## v2.2.4

- **`orrery setup` no longer gets killed.** All `FileHandle.write(Data(...))` calls
  (ObjC API) have been replaced with posix `write()` syscall helpers in a new
  `PosixIO.swift` module. The ObjC API raises `NSFileHandleOperationException` on
  any write failure — an exception Swift cannot catch — causing a SIGABRT that
  appears as `KILL` in iTerm2. The posix syscall silently returns a negative value
  on error and never throws. 14 files updated.
- **`orrery setup` session/memory prompts shown only once.** Previously the
  per-tool session-sharing and memory-sharing prompts appeared on every `orrery setup`
  run for all managed tools. Now they appear only for tools newly taken over in the
  current run — first-time setup still prompts, subsequent runs are silent.
- **`orrery info origin` shows full structured output.** Matching the layout for
  regular environments: Name, Path, Description, Tools with login info, Memory Mode,
  Memory Path, Session Mode, Env Vars.
- **`orrery memory isolate/share/storage` now works for the origin environment.**
  Was previously blocked with an error. Settings are stored in
  `~/.orrery/origin/config.json`.

## v2.2.3

- **`orrery delegate` no longer deadlocks on large output.** When called as
  a Bash tool inside Claude Code, the parent process receives output via a
  pipe whose buffer is ~64 KB. A long delegate session (code review, multi-step
  task) easily emits more than that before finishing. The previous
  `process.standardOutput = FileHandle.standardOutput` + `waitUntilExit()`
  pattern caused the child to block on `write()` once the buffer was full
  while orrery blocked in `waitUntilExit()` — a classic pipe-buffer deadlock.
  Fixed by routing stdout and stderr through `Pipe` and draining them via
  `readabilityHandler` on background queues, keeping the buffer clear for
  the lifetime of the subprocess.

## v2.2.2

- **`orrery resume` interactive picker now works correctly when launched
  from inside a Claude Code session.** The previous implementation used
  `Process().run()` + `waitUntilExit()` to spawn the tool, which left
  `CLAUDECODE` / `CLAUDE_CODE_ENTRYPOINT` / `CLAUDE_CODE_EXECPATH` in the
  child's environment — causing claude to detect itself as a subprocess
  and hang indefinitely. Now uses `execvp()` (same as `orrery run`),
  replacing the orrery process entirely and stripping those IPC variables
  before exec. Full TTY is inherited cleanly.
- **Picker I/O moved to `/dev/tty`.** `SingleSelect` and `MultiSelect`
  now open `/dev/tty` directly for all keyboard input, ANSI output, and
  terminal-mode changes. `stdin` and `stdout` are never touched, so the
  tool that runs after the picker receives a completely clean TTY.
- **Active session detection.** Sessions that are currently open in
  another window are marked with a green `▶` in the picker. Selecting one
  shows a warning before launching.
- **Session ID shown in picker.** Each entry now displays the first 8
  characters of the session ID (dim, before the title) for quick
  identification.

## v2.2.1

- **`orrery list` no longer deadlocks on large Claude credentials.** When
  Claude Code embeds OAuth tokens for connected MCP servers (figma,
  notion, etc.) into its Keychain entry, the credential JSON can exceed
  the macOS pipe buffer (~16 KB, sometimes less). `ClaudeKeychain.findPassword`
  ran `security find-generic-password`, called `waitUntilExit()` *first*,
  then read the pipe — the textbook pipe-buffer deadlock: `security`
  blocks writing into a full pipe while orrery blocks waiting for
  `security` to exit. Observed in the wild as a multi-minute hang with
  `security find-generic-password -s Claude Code-credentials …` visible
  in `ps` while `orrery list` sat idle. Now drains the pipe before
  `waitUntilExit`. Same deadlock pattern fixed in `MCPServer.execCommand`,
  where both stdout AND stderr pipes are now drained concurrently on
  background queues (sequential drain would still deadlock on whichever
  pipe filled second).
- **`orrery list` runs tool account lookups in parallel.** Each env's
  Claude/Codex/Gemini lookup used to run serially, so a slow Keychain
  read on env 1 blocked envs 2..N. Now flattens all `(env, tool)` pairs
  into a single work list and dispatches them via
  `DispatchQueue.concurrentPerform`. Worst-case wall time drops from
  `O(N envs × M tools × per-call)` to roughly `O(per-call)`. Output
  formatting and ordering are unchanged.
- **Memory path = a directory, not a phantom file.** `orrery info` and
  `orrery memory info` now print the memory **directory** (e.g.
  `~/.orrery/shared/memory/{projectKey}/`) instead of
  `.../ORRERY_MEMORY.md` — a file that never actually existed. The
  original v1.1.0 design wrote a single `ORRERY_MEMORY.md` and symlinked
  it into Claude's auto-memory; v1.1.2 switched to directory-level
  symlinking (so every auto-memory write lands in the shared/syncable
  path), which left the `ORRERY_MEMORY.md` filename as dead weight the
  code kept referencing.
- **MCP `orrery_memory_read/write` now operates on `MEMORY.md`.** Matches
  Claude's auto-memory convention, so Codex and Gemini — which call
  these tools via MCP — read and write the exact same file Claude does
  at session start. The memory folder remains the single source of
  truth; Claude gets it automatically via the existing symlink, other
  tools read it through the MCP tool.
- **Internal rename: `EnvironmentStore.memoryFile()` →
  `memoryDir()`.** Returns the folder URL. Downstream call sites
  (MemoryCommand, InfoCommand, MCPServer) updated. `memory export`
  default output filename changed to `MEMORY.md`.

## v2.2.0

- **Localization moved to JSON + build-time codegen.** All CLI strings now
  live in `Sources/OrreryCore/Resources/Localization/<locale>.json` (with
  `en.json` as the schema base). An SPM build plugin (`L10nCodegen`) reads
  the JSON on every `swift build` and emits the typed `L10n.*` accessors
  plus embedded translation tables, so single-file deploys (Homebrew,
  `.deb`) keep working with no runtime resource lookup. Drift across
  locales (missing keys, mismatched placeholders) fails the build.
- **Japanese locale (`ja.json`).** Currently stubbed from English while the
  translation lands; falls back to EN at runtime via `AppLocale.detect()`
  (matches `LANG=ja*`). Adding a future locale is now drop-a-JSON +
  `AppLocale` case + `Localizer` switch arm.
- **Translator key reference (`Resources/Localization/keys.md`).** Per-key
  context, placeholder meanings, and formatting rules (literal commands,
  trailing whitespace in prompts, `\n` placement) for every key — the
  context that can't live inside the flat JSON.
- **`orrery list` rewritten with a multi-line layout.** Each environment
  now shows on its own block with one tool per indented line — much easier
  to read once an env has multiple tools or longer suffixes. Tool rows are
  prefixed with `·`, and the active environment header is highlighted
  (cyan) so it pops out at a glance. Per-field colors keep the readout
  scannable: email near-white, plan mid-gray, model dim. Strips ANSI
  cleanly for non-TTY output (pipes, MCP).

## v2.1.2

- **Gemini env isolation.** gemini-cli ignores `GEMINI_CONFIG_DIR` and always
  reads `~/.gemini/`, so each orrery env now gets a sibling `gemini-home/`
  dir whose `.gemini` symlinks back to the env's gemini config. `orrery use`
  exports `ORRERY_GEMINI_HOME` and a shell `gemini()` wrapper runs gemini
  with `HOME=$ORRERY_GEMINI_HOME` so it lands in the right config dir.
  `orrery delegate --gemini` sets `HOME` on the child process directly.
  Setup is idempotent and backfilled for existing envs on `orrery use`.
- **`orrery delegate --gemini` works with API-key auth.** gemini-cli's
  non-interactive validator (`gemini -p …`) only looks at
  `process.env.GEMINI_API_KEY` and won't fall through to its own Keychain /
  encrypted-file lookup — so delegate now pre-extracts the stored key
  (macOS Keychain first, then decrypts `gemini-credentials.json` via scrypt
  + AES-256-GCM, same derivation gemini-cli uses) and injects it before
  invoking the child.
- **`orrery list` shows API-key auth for gemini.** Detects
  `security.auth.selectedType` (new schema) or `auth.selectedType` (legacy)
  in `settings.json` and renders `gemini(api key)` / `gemini(vertex)`
  alongside the OAuth email case.
- **Background update check no longer prints `[N] PID`.** The background
  version check is now wrapped in a double subshell so the interactive
  shell never registers it as a job — silences both zsh's `[N] PID` line
  and bash's equivalent, replacing the earlier `& disown` dance that still
  leaked a notice on some setups.

## v2.1.1

- **Fix: `orrery delegate` no longer triggers Claude's "no stdin data
  received in 3s" warning.** The delegated tool (`claude -p`, `codex exec`,
  `gemini -p`) takes the prompt as an arg, so the child's stdin is now wired
  to `/dev/null` instead of inheriting the caller's. Removes the warning and
  the 3-second startup latency in non-TTY callers (other scripts, SSH
  without a pty, the MCP server).

## v2.1.0

- **`orrery delete` without args opens a multi-select.** Pick any number of envs
  with arrow keys + space, confirm once, and delete them in one go. Useful
  after testing or when cleaning out a pile of throwaway envs. `--force`
  skips the confirmation; passing a name still does the single-env delete
  with the original confirmation prompt.

Bug fixes carried over (originally drafted for v2.0.1):

- **`orrery create --tool X` now still runs the sub-wizard** for the chosen
  tool (login source, clone source, sessions, memory). The flag was supposed
  to mean "skip the per-tool yes/no loop", not "skip every wizard step".
- **Self-login + clone no longer adopts the source's identity.** Identity
  keys (`oauthAccount`, `userID`, `anonymousId`) and onboarding markers
  (`hasCompletedOnboarding`, `lastOnboardingVersion`) are stripped from
  the cloned `.claude.json` so Claude runs its own onboarding + login flow
  at next launch.
- **Clone skips `backups/`.** `.claude.json.backup.<ts>` snapshots carry a
  full identity. Without this, the heal-from-backup pass would later
  restore the source's identity into the new env, defeating the strip above.
- **Origin's tool logins shown in `list` and `info`.** The `* origin` row
  shows each tool's email + plan, same format as regular envs.
- **Stale session symlinks healed on `orrery use`.** After migration, env's
  `claude/projects` etc. symlinks still pointed at `~/.orbital/shared/...`.
  `linkSharedSessionDirs` now detects misaligned symlinks (not just real
  directories) and recreates them pointing at `~/.orrery/shared/...`.
- **Background version-check no longer prints `[N] done` notices** in zsh —
  the subshell is `disown`'d after backgrounding.
- **Migration heals lost `.claude.json` from backups** when a migrated env
  has `claude/backups/.claude.json.backup.<ts>` present but the main file
  missing (Claude Code refuses to launch in that state).
- **Migration prompt wording tightened.**

## v2.0.0

Orbital has been renamed to **Orrery** and forked to `OffskyLab/Orrery`. This
release continues from Orbital v1.1.6 with no feature changes — the entire
diff is the rename.

**Breaking:**
- CLI binary: `orbital` → `orrery`
- Config directory: `~/.orbital/` → `~/.orrery/`
- Env vars: `ORBITAL_HOME` → `ORRERY_HOME`, `ORBITAL_ACTIVE_ENV` → `ORRERY_ACTIVE_ENV`, `ORBITAL_MEMORY.md` → `ORRERY_MEMORY.md`
- Swift module: `OrbitalCore` → `OrreryCore`
- Homebrew tap: `OffskyLab/orbital/orbital` → `OffskyLab/orrery/orrery`

**Interactive migration:** on each `orrery` invocation, if `~/.orbital/` still
has envs or shared data that haven't been migrated (or previously declined),
`orrery` prompts `[Y/n]` once. Say yes and it moves everything (envs, shared
sessions/memory, `current`, `sync-config.json`), regenerates `activate.sh`
with the new env var names, and updates `source` lines in your shell rc
files. Say no and the declined env IDs are remembered in
`~/.orrery/.migration-state.json` so we don't re-ask. If new orbital envs
appear later, the prompt comes back for just those.

**Claude Keychain migration:** the Keychain service name includes
`SHA256(configDir)`, so renaming the env's config dir would normally
invalidate the stored token and force you to re-login. Migration copies each
env's credential from the old-path service name to the new-path one so your
Claude sessions keep working without re-authenticating.

**Transitional compatibility:** The old `OffskyLab/Orbital` repo remains
published as a deprecated wrapper — it ships a `orbital` command that
forwards to `orrery` with a deprecation notice so existing shell aliases,
MCP configs, and scripts keep working.

## v1.1.6

- **Per-tool setup flow** — new `ToolFlow` protocol with `ClaudeFlow`/`CodexFlow`/`GeminiFlow`; each tool owns its own login copy and settings clone logic
- **Create wizard rewritten** — yes/no per tool (claude → codex → gemini), each "yes" runs a per-tool sub-wizard (login copy → clone settings → sessions → memory for claude)
- **Copy login state** — new wizard step copies credentials + `.claude.json` from origin or another env; Claude uses Keychain (SHA256-hashed service name) + `.claude.json`; Codex uses `auth.json`; Gemini uses `oauth_creds.json`
- **`.claude.json` identity/prefs split** — when login source and clone source are both picked, preferences (theme, dismissed dialogs, projects, usage counters) follow clone; identity keys (`oauthAccount`, `userID`, `anonymousId`, `hasCompletedOnboarding`, `lastOnboardingVersion`) overlay from login; per-account caches (`cachedGrowthBookFeatures`, `cachedStatsigGates`) are stripped so Claude refreshes them
- **Per-tool session isolation** — `OrreryEnvironment.isolateSessions: Bool` (env-wide) split into `isolatedSessionTools: Set<Tool>` (per-tool); backward-compat decoder migrates old env.json on load
- **`tools` subcommand split** — `orrery tools add` (wizard lists un-added tools) and `orrery tools remove` (wizard lists added tools) replace the previous free-form multi-select
- **Login account info in `list` and `info`** — each tool shown as `claude(email, plan)`, `codex(email, plan)`, `gemini(email)` when logged in
- **Login wizard** — options deduplicated by account (email), shows `查詢登入狀況中…` while querying; fast-path email lookup skips Keychain subprocess calls for already-seen accounts
- **Fix: merge preserves existing identity** — if the login source has a partial `.claude.json` (e.g. missing `hasCompletedOnboarding`), merge no longer strips those keys from the target; it only overlays keys that exist in the source
- **`--tool` flag is single-value** — multi-tool non-interactive create was removed; multi-tool envs go through the wizard or through `tools add`

## v1.1.5

- **Wizard cleanup** — create wizard prompts and options are fully cleared after each step, leaving only the final summary visible
- **Post-create switch prompt** — after `orrery create`, asks whether to switch to the new environment immediately
- **Remove Claude auth login step** — `claude auth login` does not respect `CLAUDE_CONFIG_DIR`; removed from create flow — Claude prompts for login naturally on first interactive run
- **Fix: update check empty notice** — background version check no longer creates empty notice files when already up to date

## v1.1.4

- **Update notification redesign** — notice now shows on every `orrery` command (in yellow) until `orrery update` clears it; version check runs in background at most once every 4 hours triggered by command invocation, not shell startup; eliminates Powerlevel10k instant prompt conflict

## v1.1.3

- **Fix: `orrery use <env>` not persisting** — new shell always restored to origin instead of the last used environment; `_set-current` is now called after every successful `orrery use`

## v1.1.2

- **Memory directory symlink** — Claude's auto-memory directory for each project is now symlinked directly to the orrery shared memory location; all memories Claude writes automatically land in the shared (and syncable) location without requiring any CLAUDE.md instructions
- **Fix: `_check-update` version** — now reads from `OrreryCommand.configuration.version` instead of a separate hardcoded string, eliminating version drift

## v1.1.1

- **`ORRERY_MEMORY.md` auto-loaded by Claude** — on `orrery create` (with Claude tool) and on first MCP memory access, a symlink is created inside Claude's auto-memory directory so Claude picks up shared memory automatically at session start
- **Fix: `orrery update` runs `brew update` first** — prevents Homebrew tap cache from reporting an old version as already installed
- **Fix: `orrery list` after upgrade** — migrates `ORRERY_ACTIVE_ENV="default"` and `current` file to `"origin"` on first shell start after upgrading from pre-1.1.0

## v1.1.0

- **Memory external storage** — `orrery memory storage <path>` redirects `ORRERY_MEMORY.md` and fragments to any directory (e.g. Obsidian vault); prompts to copy existing memory when new path is empty; `--reset` to revert
- **Update check at shell startup** — `activate.sh` checks for new releases in background (at most once per day) and shows a notice at the next shell open; runs `orrery update` to upgrade

## v1.0.7

- **`orrery update`** — new command to self-update: uses `brew upgrade orrery` on macOS, `apt-get install --only-upgrade orrery` on Linux
- **`orrery sync` marked experimental** — abstract and discussion now indicate experimental status; `team` subcommands also labeled

## v1.0.6

- **Rename `default` → `origin`** — the reserved system environment is now called `origin`; `orrery use origin` / `orrery deactivate` return to unmanaged system config
- **Switch-to-origin message** — informative locale-aware message when switching to `origin` instead of plain "Switched to environment"
- **GitHub Pages** — new `origin` section explaining its special role; nav link added; `orrery env set/unset` corrected in commands grid

## v1.0.5

- **`orrery env set/unset`** — moved from `orrery set env` / `orrery unset env` to `orrery env set` / `orrery env unset`
- **`orrery info`** — now displays memory path, memory mode (isolated/shared), and session mode (isolated/shared)
- **`orrery memory` redesign** — interactive settings menu with `info`, `export`, `isolate`, `share` subcommands; discard migration requires explicit confirmation
- **Fix: `orrery tools`** — guard against default environment; prompts auth login for newly added tools
- **Fix: `orrery delegate` with Codex** — use `codex exec` for non-interactive mode
- **Fix: default environment** — `orrery set env`, `orrery unset env`, `orrery export`, `orrery unexport` no longer crash on default environment

## v1.0.4

- **Per-environment memory isolation** — `orrery memory isolate` / `orrery memory share` with fragment-based migration; `orrery create` wizard includes memory sharing step (default: isolated)
- **Interactive auth login in `orrery create`** — after selecting tools, prompts to log in to each tool via `execvp` for proper TTY
- **Fix: `orrery create` auth login TTY** — correct `execvp` argv construction, login now works correctly
- **Fix: Strip `ANTHROPIC_API_KEY` in `run` and `delegate`** — inherited API key no longer leaks into non-default environments

## v1.0.2

- **Fix: Strip `ANTHROPIC_API_KEY` in `run` and `delegate`** — inherited API key from shell no longer leaks into non-default environments, ensuring each environment's own credentials are used

## v1.0.1

- **Fix: `orrery run` supports interactive tools** — uses `execvp` to inherit full TTY, fixing `orrery run claude` / `orrery run codex` hanging
- **Fix: Strip Claude IPC env vars** in `run` and `delegate` commands to prevent child processes from hanging
- **Fix: Gemini MCP setup** — updated `gemini mcp add` to new CLI format
- **P2P Sync section** added to README and GitHub Pages (EN + 中文)
- **Fix: scroll-padding-top** for sticky nav on GitHub Pages

## v1.0.0

- **P2P sync** — `orrery sync` delegates to orrery-sync daemon for real-time memory sync across machines
- **Memory fragment integration** — `orrery_memory_read` detects pending sync fragments and prompts agent to consolidate
- **Fragment cleanup** — overwrite mode (`append=false`) automatically cleans up integrated fragments
- **CLAUDE.md** — development guidelines added
- orrery-sync bundled as dependency via Homebrew/APT

## v0.3.3

- **Memory fragment log** — each `orrery_memory_write` now produces an append-only fragment file in `fragments/` alongside `ORRERY_MEMORY.md`, keyed by UUID + peer name. Prepares for future P2P sync with conflict-free replication.

## v0.3.2

- **`/orrery:resume` slash command** — resume session by index from `orrery sessions`
- Slash commands renamed to `/orrery:delegate` and `/orrery:sessions`
- GitHub Pages badge updated

## v0.3.1

- **`orrery memory export`** — export shared project memory to file
- Improved MCP memory tool descriptions with usage scenarios and guidance

## v0.3.0

- **Shared memory across AI tools** — `orrery_memory_read` / `orrery_memory_write` MCP tools let Claude, Codex, and Gemini share the same project memory (`ORRERY_MEMORY.md`)
- **`orrery mcp setup` registers with all tools** — automatically registers MCP server with Claude Code, Codex CLI, and Gemini CLI (skips uninstalled ones)
- AI tool integration section on GitHub Pages (renamed from "Claude Code Integration" to cover all tools)

## v0.2.8

- **MCP server** — `orrery mcp-server` exposes tools via Model Context Protocol (stdin/stdout JSON-RPC)
- **`orrery mcp setup`** — one command registers MCP server + installs `/delegate` and `/sessions` slash commands
- **`orrery delegate`** — delegate tasks to AI tools in other environments (`--claude`/`--codex`/`--gemini`)
- **`orrery resume`** — resume sessions by index from `orrery sessions`, with passthrough args (e.g. `--dangerously-skip-permissions`)
- **`orrery run`** — run any command in a specific environment (`orrery run -e work claude --resume <id>`)
- **`activate.sh`** — `orrery setup` generates `~/.orrery/activate.sh`, rc file uses `source` instead of `eval`
- Shell init silenced for Powerlevel10k instant prompt compatibility
- Linux static linking (`--static-swift-stdlib`) — no runtime dependencies
- Linux built on Ubuntu 22.04 (jammy) for glibc 2.35 compatibility
- APT repo i386 empty Packages to prevent 404 on multiarch systems
- `.deb` postinst runs `orrery setup` automatically
- Localized `--claude`/`--codex`/`--gemini` flag help strings
- `install.sh --main` flag to build from latest main branch

## v0.2.0

- Built-in `default` environment — `orrery use default` returns to system config
- `orrery deactivate` now aliases to `orrery use default`
- Clone wizard in `orrery create` — single-select to clone from `default` or any existing environment
- Session sharing wizard changed to single-select UI
- Each create wizard step is independent — only skipped if its flag is provided
- `orrery sessions` command with `--claude`, `--codex`, `--gemini` flags
- Sessions display with branded tool names, indexed card layout, full session ID
- Pre-built binary releases for macOS (arm64), Linux (x86_64, arm64)
- `.deb` packages and APT repository (Ubuntu/Debian)
- GitHub Pages with Use Cases section, language switcher (English / 繁體中文)

## v0.1.9

- `orrery sessions` command — list AI tool sessions for the current project
- `--claude`, `--codex`, `--gemini` filter flags
- APT repository auto-update in release workflow
- GitHub Pages and README updated with sessions command and APT install

## v0.1.8

- Branded tool names in sessions output (Anthropic Claude, OpenAI Codex, Google Gemini)
- Sessions card layout with full session ID for `claude --resume`
- GitHub Pages badge and hero title updates

## v0.1.7

- Linux build fix — replace C stdio with Foundation `FileHandle` for Swift 6 concurrency safety
- Remove macOS x86_64 from release workflow (Apple Silicon only)
- Release workflow outputs `.tar.gz` archives

## v0.1.6

- `orrery sessions` — list Claude sessions for the current project
- Session support for Codex (`sessions/`) and Gemini (`tmp/`) directories
- Remove auth login instructions from create flow

## v0.1.5

- Fix locale detection — skip empty `LC_ALL`/`LC_MESSAGES` before falling through to `LANG`
- Lazy session symlink migration — `orrery use` auto-creates symlinks for existing environments
- Pre-built binary releases via GitHub Actions

## v0.1.4

- Capitalize product name to Orrery (CLI command stays lowercase)
- Mobile hamburger menu for GitHub Pages
- Language dropdown switcher (English / 繁體中文)
- Copy buttons on install code blocks
- GitHub Pages with Traditional Chinese version

## v0.1.3 (not released as tag)

- Session sharing across environments (default: shared, `--isolate-sessions` to opt out)
- Bash shell support (`orrery setup` auto-detects shell)
- `orrery setup` outputs shell function to stdout for immediate `eval`
- `post_install` in Homebrew formula
- i18n support — Traditional Chinese and English (auto-detect from system locale)
- Traditional Chinese README

## v0.1.2

- Interactive multi-select wizard for tool management
- `orrery info` defaults to active environment
- Linux support with auth instructions
- Switch to Apache 2.0 license

## v0.1.1

- UUID-based environment directories (rename no longer moves dirs)
- `orrery rename` command
- `orrery use` command with shell integration
- Hide internal commands from help

## v0.1.0

- Initial release
- `orrery create`, `delete`, `list`, `info` commands
- `orrery set env`, `unset env`, `tools` commands
- `orrery setup` and `orrery init` for shell integration
- Per-shell environment activation via `orrery use`
- Support for Claude Code, Codex CLI, and Gemini CLI
- Homebrew formula and install script
