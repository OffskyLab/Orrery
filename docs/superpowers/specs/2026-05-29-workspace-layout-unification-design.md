# Workspace Layout Unification — Design Spec (rc.2)

**Date:** 2026-05-29
**Target version:** v3.1.0-rc.2 (RC, self-validation only — not for real users)
**Status:** Design approved, pending spec review

---

## Problem

v3.1 introduced two **colliding** concepts both named "workspace":

1. **sandbox/env** (`~/.orrery/envs/<UUID>/`) — an isolation unit: a set of env
   vars + per-tool config dirs (`claude/`, `codex/`, `gemini/`). User-facing
   vocabulary was renamed `sandbox` → `workspace` in rc.1.
2. **v3.1 "workspace"** (`~/.orrery/envs/<UUID>/claude-workspace/`) — a shared
   *content* namespace for claude (`projects/`, `memory/`, `agents/`,
   `commands/`, `todos/`) that pinned accounts symlink into.

And `origin` — the user's real `~/.claude`, taken over into
`~/.orrery/origin/` — was handled as a **special case** physically separate
from both: its claude content lived in `~/.orrery/origin/claude/` (takeover
root), but rc.1 *also* mistakenly created a parallel
`~/.orrery/envs/origin/claude-workspace/` shared store. The result: "origin"
existed in two physical locations, sessions written via plain `claude` and via
`orrery use <origin-pinned-account>` could not see each other, and the code
carried an `if workspace == "origin"` special case throughout.

**Root insight (user):** there are not two concepts. A *workspace* IS the
isolation unit. It contains both the env-var/config side (codex/gemini) AND
the claude shared content. `origin` is simply the **default workspace whose
physical root is the takeover root** — the user's pre-existing `~/.claude`
becomes the `origin` workspace. There was never meant to be a separate v3.1
workspace dir for it.

## Goal

Collapse "sandbox/env" and "v3.1 workspace" into a **single `workspace`
concept** with one uniform on-disk layout, and make `origin` a zero-special-case
member of it. Migrate existing (v3.0.x) users non-destructively. Do **not**
touch user-facing command vocabulary or introduce higher-level abstractions
this round (see Non-Goals).

---

## Target On-Disk Layout

```
~/.orrery/
  workspaces/                       (renamed from envs/)
    origin/                         reserved-name dir = takeover workspace
      claude/                       ← ~/.claude symlinks here (takeover root)
      codex/                        ← CODEX_HOME / CODEX_CONFIG_DIR target
      gemini/                       ← GEMINI_CONFIG_DIR target
      workspace.json                metadata (replaces origin/config.json)
    <UUID>/                         named workspace; dir name ALWAYS a UUID
      claude/                       projects/ memory/ agents/ commands/ todos/
      codex/
      gemini/
      workspace.json                { "name": "work", ... }  display name, may repeat
  accounts/
    claude/<id>/                    per-account dir = CLAUDE_CONFIG_DIR
      projects/ → ../../../workspaces/<pinned>/claude/projects
      memory/   → ...               (agents, commands, todos likewise)
      metadata.json                 Account model (has `workspace` field)
    codex/<id>/   gemini/<id>/       (unchanged; no per-account symlinks)
  shared/                           UNCHANGED — claude session jsonl live here;
                                    workspaces/<ws>/claude/projects symlinks
                                    into shared/ for tools that share sessions
  bin/  activate.sh  current  .update-ts  …   (unchanged top-level files)
```

### Key invariants

- **Workspace directory name is always a UUID**, except the reserved `origin`.
  Display names live in `workspace.json.name` and may collide freely — UUID
  disambiguates. (The non-UUID dirs `personal/`, `work/`, etc. seen on the
  developer's machine are 0.x leftovers from before launch; real users do not
  have them. See Migration §"unrecognized dirs".)
- **`origin` is a normal workspace** structurally identical to named ones
  (`<root>/{claude,codex,gemini}/` + `workspace.json`). Its only distinction is
  the reserved dir name `origin` and that its `claude/` is the takeover root
  (`~/.claude` symlinks to it). No `if workspace == "origin"` path branching
  remains — only the reserved-name check when *resolving* a workspace.
- **`account.workspace`** stores a UUID or the literal `"origin"`. Account dir
  symlinks resolve to `workspaces/<account.workspace>/claude/<subdir>`.
- **codex/gemini have no per-account dirs.** They use whole-config dirs at
  `workspaces/<ws>/{codex,gemini}/`, pointed to by env vars on workspace enter.

---

## Component Changes

### 1. Path constants — `EnvironmentStore.swift`

| Constant | Before | After |
|---|---|---|
| `envsURL` | `~/.orrery/envs/` | `~/.orrery/workspaces/` |
| `originDir` | `~/.orrery/origin/` | `~/.orrery/workspaces/origin/` |
| `originConfigURL` | `~/.orrery/origin/config.json` | `~/.orrery/workspaces/origin/workspace.json` |
| `claudeWorkspaceDir(workspace:)` | `envs/<ws>/claude-workspace/` | `workspaces/<ws>/claude/` |
| `originConfigDir(tool:)` | `~/.orrery/origin/<tool>/` | `~/.orrery/workspaces/origin/<tool>/` |
| `toolConfigDir(tool:, environment:)` | `envs/<id>/<tool>/` | `workspaces/<id>/<tool>/` |
| `sharedURL`, `sharedSessionDir`, `sharedMemoryDir`, account paths | — | **unchanged** |

Because origin is now under `workspaces/`, `originDir` becomes
`envsURL.appendingPathComponent("origin")` — i.e. expressible via the same base
as named workspaces, reinforcing zero-special-case.

`claudeWorkspaceDir(workspace:)` after the change returns
`workspaces/<ws>/claude/` for BOTH named workspaces and origin — there is no
longer a separate "claude-workspace" subdir. The takeover root's `claude/` IS
the origin workspace's claude content dir.

### 2. Metadata unification — merge `OriginConfig` into `OrreryEnvironment` →
`Workspace`

`OriginConfig` (origin/config.json) and `OrreryEnvironment` (env.json) have
near-identical fields. Unify into a single `Workspace` model serialized as
`workspace.json`:

```
Workspace:
  id: String                  // UUID, or "origin" for the reserved workspace
  name: String                // display name (origin → "origin"); may repeat
  description: String
  createdAt: Date
  lastUsed: Date
  tools: [Tool]
  env: [String: String]
  isolatedSessionTools: Set<Tool>
  isolateMemory: Bool
  memoryStoragePath: String?
  accounts: [String: AccountID]   // keyed by Tool.rawValue
```

- `OriginConfig` is removed; origin reads/writes the same `Workspace` model.
- Decoder is tolerant: a `workspace.json` missing the new `id`/`name`/etc.
  fields (i.e. a migrated old `config.json`) defaults `id`/`name` to `"origin"`.
- Rename `OrreryEnvironment` type → `Workspace` (and `env.json` filename →
  `workspace.json`) across the codebase. `OrreryEnvironment.defaultName`
  (`"origin"`) becomes `Workspace.reservedOriginName`.

### 3. Account dir symlinks — `ClaudeAccountDirectory.swift`

- `sharedSubdirs` unchanged: `["projects","memory","agents","commands","todos"]`.
- `prepareDirectory` / `verifySymlinks`: target base changes from
  `claudeWorkspaceDir` (old `claude-workspace/`) to the new
  `workspaces/<ws>/claude/`. Logic otherwise unchanged.
- Symlink targets remain **absolute paths** (required: the target is read after
  `CLAUDE_CONFIG_DIR` export, and relative symlinks would resolve against the
  account dir incorrectly).

### 4. Migration — two-phase, idempotent

**Strategy:** Converge any real-user state (v3.0.x `envs/<UUID>/` + `accounts/`
pool + `origin/`) to the target `workspaces/` layout. rc versions were never
shipped to real users, so the rc.1 `claude-workspace/` (and erroneous
`envs/origin/`) intermediate states are **ignored** — no compensation layer
for a state no real user has. rc.1's `runV31AccountLayoutIfNeeded` is
**replaced** at the source by the corrected logic, not patched over (per
global rule: eliminate root cause).

**Why two phases (ordering constraint):** the migration cannot be a single
step at one position in `main.swift`'s chain, because of conflicting
dependencies:
- The **structure relocation** (renaming dirs, moving the takeover root,
  repointing `~/.claude`) MUST run *before* `OriginTakeoverBootstrap`.
  Otherwise takeover runs with the new `originDir` constant
  (`workspaces/origin/`) while the physical dir is still at `origin/` and
  `~/.claude` points at the old location — takeover misjudges and fights the
  not-yet-run migration.
- The **account-symlink repoint** depends on the account pool existing, which
  `AccountMigration.runIfNeeded` (v2→v3) builds *later* in the chain.

So split into two flag-guarded, best-effort (never-throw) phases:

**Phase A — `runWorkspaceStructureRelocationIfNeeded`** (new; runs FIRST,
after `LegacyOrbitalMigration`, before `OriginTakeoverBootstrap`):
  1. If `~/.orrery/envs/` exists and `~/.orrery/workspaces/` does not, rename
     `envs/` → `workspaces/`. (Real users have no `envs/origin/`; if an rc
     artifact is present, the reserved name is handled by step 2 taking
     precedence — see below.)
  2. Move takeover root `~/.orrery/origin/` → `~/.orrery/workspaces/origin/`
     if `workspaces/origin/` does not already exist. If it DOES already exist
     (only possible from an rc artifact, never for real users), do NOT
     overwrite the takeover root — log the conflict and leave both in place.
     Repoint `~/.claude` symlink (and codex/gemini equivalents if
     origin-managed) to `workspaces/origin/<tool>/`.
  3. For each workspace dir: `config.json`/`env.json` → `workspace.json`;
     `claude-workspace/` (rc artifact) → merge into `claude/` if present.
  4. Write flag `.workspace-structure-relocated`.
  After Phase A, `OriginTakeoverBootstrap` sees `isOriginManaged == true`
  (or, for a fresh user with no prior takeover, takes over cleanly into the
  new location) — either way a no-op-or-correct outcome, no fight.

**Phase B — `runWorkspaceAccountSymlinksIfNeeded`** (replaces
`runV31AccountLayoutIfNeeded`; runs LAST, after `AccountMigration`):
  5. For each claude account: rebuild the 5 symlinks to point at
     `workspaces/<account.workspace>/claude/<subdir>`.
  6. Write flag `.workspace-account-symlinks` (supersedes
     `.v3.1-account-layout-migrated`).

- **Unrecognized dirs** (non-UUID name dirs, or UUID dirs missing
  `env.json`/`workspace.json`): both phases **leave them untouched and log**
  them. Migration NEVER deletes user directories — deletion risk is unjustified
  for states real users cannot have. Cleanup of the developer machine's
  leftovers is a **separate, manual script** (see Out-of-band cleanup).

### 5. Uninstall — `UninstallCommand.swift` + `originRelease`

- `originRelease(tool:)` / `originTakeover` / `isOriginManaged` automatically
  follow the changed `originConfigDir` constant → now release from
  `workspaces/origin/<tool>/` back to `~/.claude` etc.
- **Beneficial consequence:** because origin's claude content (including
  v3.1-wrapper-written sessions) now lives in the takeover root all along,
  uninstall's existing release logic folds everything back into `~/.claude/`
  with NO extra merge-back code. The rc.1 "orphaned v3.1 sessions" problem is
  structurally eliminated.

### 6. Shell function / activate.sh — `ShellFunctionGenerator.swift`

- The version-stamp self-heal in `_orrery_init` (compares activate.sh stamp vs
  `orrery-bin --version`, re-runs `orrery setup` + re-sources on mismatch) is
  the **trigger point**: after a user upgrades the binary, the next `orrery`
  invocation in any shell regenerates activate.sh. No new shell-side migration
  logic is added — file-system migration is entirely binary-side (per approved
  division of labor).
- `enter`/`exit`/`use`/`run` cases: paths they reference resolve through the
  changed `EnvironmentStore` constants. Semantics & vocabulary **unchanged**.
  Any current shell still exporting an old `envs/...` path is corrected on the
  next `enter`/`exit` (which re-reads from the binary).

### 7. Hardcoded-string sweep

Audit and update per the changed concepts:
- `"claude-workspace"` — `EnvironmentStore.swift:249` (sole occurrence) →
  removed.
- `"envs"` — `EnvironmentStore.swift:19`, `AccountMigration.swift:36`,
  `LegacyOrbitalMigration.swift` → `"workspaces"`. **Caution:**
  `LegacyOrbitalMigration` references `envs` as part of the *orbital→orrery*
  move; that historical migration must keep producing the layout the
  workspace-layout migration then consumes. Verify the two migrations compose.
- `"origin"` — reserved name retained as `Workspace.reservedOriginName`;
  `if workspace == "origin"` *path-branching* removed, reserved-name *resolution*
  checks retained (`ShellFunctionGenerator.swift` 9 sites, `RunCommand`,
  `ListCommand`, `ManifestRunner`, etc.).

---

## Out-of-band: developer machine cleanup (separate script)

NOT part of shipped migration. After the migration code lands, a standalone
script cleans this developer machine's pre-launch leftovers:
- 0.x name-as-dir workspaces: `workspaces/{personal,work,demo,demo2,hhh}/`
  (the non-UUID dirs).
- Orphan UUID dirs with no `env.json`/`workspace.json`:
  `05FB10B9, 51D82751, 7578B036, 772FF591, CC651B15, E76DC827`.

**Must NOT delete** `B761FD59-…` (UUID dir, `name=personal`) — it is the active
session's `ORRERY_HOME` workspace. Script lists everything for confirmation
before deleting.

---

## Non-Goals (explicitly out of scope for rc.2)

- **User-facing command vocabulary convergence** (`enter`/`exit`/`use`/`pin`/
  `workspace` naming). Deferred — a separate UX design.
- **"sandbox as higher-level abstraction binding (workspace, account)."** The
  user is still considering whether `sandbox` should become a first-class
  wrapper. Deferred to its own brainstorm.
- Migrating origin's *historical* `~/.claude/projects/` sessions into any new
  structure beyond the takeover root (they already live there).
- Reverse migration (`workspaces/` → `envs/`). One-way, as before.

---

## Testing Strategy

- **Unit:** `Workspace` model encode/decode incl. tolerant decode of a legacy
  `config.json` (missing id/name) and legacy `env.json`.
- **Migration tests** (temp `ORRERY_HOME`): given a synthesized v3.0.x tree
  (`envs/<UUID>/{claude,codex,gemini}/` + `env.json`, `origin/{claude,…}/` +
  `config.json`, `accounts/claude/<id>/` with `workspace` field), assert:
  - `workspaces/` exists, `envs/` gone; `workspaces/origin/` exists, `origin/`
    gone.
  - each `workspace.json` present & decodes; `claude-workspace/` absent.
  - account symlinks resolve to `workspaces/<ws>/claude/<subdir>`.
  - both phase flags (`.workspace-structure-relocated`,
    `.workspace-account-symlinks`) written; second run of each phase is a no-op.
  - Phase A runs before takeover with no fight (assert `isOriginManaged`
    after the chain); Phase B runs after the account pool exists.
  - an unrecognized dir is left untouched and logged (not deleted).
- **Idempotency:** running migration twice yields identical tree.
- **Uninstall round-trip:** takeover → write a session via wrapper → uninstall
  → assert session content is back under `~/.claude/projects/`.
- **L10n build gate** must stay green (all-locales-have-all-keys).
- Full `swift test` (315 baseline) must pass.

## Known Limitations

- One-way migration; back up `~/.orrery/` before upgrading.
- `EnvironmentStore.loadOriginConfig` reading production paths under a test
  `ORRERY_HOME` is a pre-existing v3.0.x bug, not addressed here.
- `ClaudeJsonMerge` field categorization remains hardcoded (unchanged).

## Version

Ship as **v3.1.0-rc.2** (continued self-validation; RC not for real users).
Bump: `Version.swift`, `docs/index.html`, `docs/zh_TW.html`, `CHANGELOG.md`.
Skip homebrew formula (RC convention).
