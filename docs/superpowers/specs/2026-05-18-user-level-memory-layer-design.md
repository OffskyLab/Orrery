# Design — User-level Memory Layer

**Date:** 2026-05-18
**Status:** Draft, pending user review

## Goal

Introduce a true **user-global** memory layer in Orrery that is independent of
any env or projectKey. It restores the cross-project "this is about *you*" layer
that Claude Code never natively provided as auto-memory, and that was further
masked when Orrery's `origin` takeover folded `~/.claude/CLAUDE.md` into a
per-env config file. Each AI tool (Claude, Codex, Gemini) loads this layer
automatically at session start via its native `SessionStart` hook.

## Non-goals

- Migrating existing memory files out of the project layer into the user layer
  (Orrery cannot reliably classify which entries are project-specific vs.
  user-global). A future `orrery memory user import` may help, but it is out of
  scope for this release.
- "Rescuing" `~/.claude/CLAUDE.md` from origin takeover. After takeover, that
  file is the *origin env's* CLAUDE.md, by design; the user-memory layer is
  what replaces its lost cross-env semantics.
- Replacing the project-level memory layer or fragments-based sync mechanism.
  The user layer is **additive**; project layer behavior is unchanged.
- Cross-machine sync transport changes. Existing `orrery-sync` machinery is
  reused; only the path list it watches grows.

## Background

Two discoveries shaped this design:

1. **Claude Code has no user-global auto-memory directory.** Auto-memory is
   strictly per-project under `~/.claude/projects/{projectKey}/memory/`. The
   only user-global mechanism is the static, hand-written `~/.claude/CLAUDE.md`.
   The 4 memory types (`user`, `feedback`, `project`, `reference`) defined in
   the auto-memory frontmatter are semantic labels stored per-project — so a
   `type: user` memory in project A is invisible to project B.

2. **Origin takeover converted `~/.claude/CLAUDE.md` into an env-level file.**
   Symlinking `~/.claude/` into `~/.orrery/origin/claude/` is correct semantics
   for *most* of the contents, but it incidentally demoted the user-global
   instructions file to per-env scope.

The user-layer this spec defines lives **outside the env hierarchy**, served
through MCP (for writes) and a `SessionStart` hook (for automatic reads).

## Scoped decisions

| # | Decision |
|---|---|
| 1 | User-memory storage lives at `~/.orrery/user/memory/`, outside any env. |
| 2 | Schema mirrors the project layer (`MEMORY.md` index + individual `*.md` + `fragments/`), reusing the same 4-type frontmatter taxonomy. |
| 3 | Auto-loading uses each tool's native `SessionStart` hook; the hook command (`orrery memory user emit`) prints `MEMORY.md` to stdout. |
| 4 | All three supported tools (Claude, Codex, Gemini) get hook installers in this release — not phased. |
| 5 | New MCP tools `orrery_user_memory_read` / `orrery_user_memory_write` are introduced as siblings to the existing `orrery_memory_*` pair (no `scope` parameter). |
| 6 | Per-env `shareUserMemory: Bool` defaults to `true` (opt-out, not opt-in). |
| 7 | `orrery memory` CLI is reorganised into `orrery memory project ...` and `orrery memory user ...` sub-groups; existing names become breaking changes (major version bump). |
| 8 | Existing memories are **not** auto-migrated. A `orrery memory user import` helper is deferred to future work. |
| 9 | The hook entry carries an `_orrery_managed: true` marker; `orrery use` reconciles env state to settings.json on every switch (manual hook deletion gets restored if `shareUserMemory=true`). |
| 10 | Codex hook config uses `~/.codex/hooks.json` (JSON) instead of `config.toml`, avoiding a TOML dependency. |
| 11 | `emit` truncates to 25KB and appends `(truncated, read full via orrery_user_memory_read)` so the hook stdout never exceeds the strictest tool's limit. |

## Storage layout

```
~/.orrery/
├── envs/                           (existing — env-scoped)
├── shared/memory/{projectKey}/     (existing — project layer)
├── origin/                         (existing — takeover storage)
└── user/                           ★ new top-level
    └── memory/
        ├── MEMORY.md               ← index, auto-loaded by hook (first 25KB)
        ├── reference_*.md          ← individual entries (same schema as project)
        ├── feedback_*.md
        ├── user_*.md
        └── fragments/
            └── f-{id}-{peer}.md    ← cross-machine sync, sibling format
```

Path is created lazily on first write; `emit` no-ops cleanly if absent.

`~/.orrery/user/` is a deliberate sibling of `shared/`, not a subdirectory of
it. `shared/memory/` is keyed by projectKey; `user/memory/` is not keyed at
all — its mere position above the env hierarchy is what gives it user-global
semantics.

## MCP tools

Both new tools are siblings of the existing `orrery_memory_*` pair, registered
by `MCPServer`:

### `orrery_user_memory_read`

- **Parameters:** none.
- **Returns:** contents of `~/.orrery/user/memory/MEMORY.md`. If pending
  fragments exist, appends the "Pending Memory Fragments (from sync)" block
  exactly the way `orrery_memory_read` already does for the project layer.
- **Description (verbatim, to be embedded in tool registration):**
  *"Read the user-global Orrery memory. This memory follows you across all
  projects and all environments — use it for facts about who you are (the
  user), cross-project preferences, and tool/account references. Always read
  before writing to avoid overwriting existing knowledge. If pending sync
  fragments are present, consolidate them into MEMORY.md and write back with
  `append=false`."*

### `orrery_user_memory_write`

- **Parameters:** `content: string`, `append: bool = true`.
- **Behavior:** writes/appends `MEMORY.md` *and* records a fragment in
  `fragments/` (`action=append` or `action=overwrite`). When `append=false`,
  cleans up consumed fragments after the overwrite — same semantics as the
  existing project-layer `writeMemory`.
- **Description (verbatim):**
  *"Write or append to the user-global Orrery memory. This persists across all
  projects/envs. Use for: user role/preferences, cross-project feedback rules,
  tool/account references. Default is append; set `append=false` to rewrite
  (used after consolidating fragments)."*

Both tools share an internal `MemoryStore` helper extracted from the existing
project-layer code; user/project differ only by the directory URL they hold.

## CLI surface

### Top-level reorganisation (breaking)

```
orrery memory                          ← interactive, shows both layer states
orrery memory project info             ← was: orrery memory info
orrery memory project export           ← was: orrery memory export
orrery memory project isolate          ← was: orrery memory isolate
orrery memory project share            ← was: orrery memory share
orrery memory project storage [PATH]   ← was: orrery memory storage

orrery memory user                     ← interactive, shows user-layer status
orrery memory user info
orrery memory user export [-o PATH]
orrery memory user path
orrery memory user enable              ← installs hook in current env
orrery memory user disable             ← removes hook in current env
orrery memory user emit                ← hook target; prints MEMORY.md to stdout
```

`orrery memory` (no subcommand) prints a two-line status digest and a menu
that drills into either layer's submenu. No flat menu listing both layers'
actions side by side.

### Migration & breaking-change handling

- This is a major-version change: bump to **v3.0.0** at release.
- No aliases for the renamed commands. `CHANGELOG.md` and the upgrade notes
  call out the rename. Rationale: aliases keep two name surfaces forever; a
  clean break is cheaper to maintain.
- The interactive `orrery memory` keeps working without arguments, so casual
  users land on the new menu naturally.

## SessionStart hook design

### Common command

```sh
orrery memory user emit
```

`emit`:

1. Reads `~/.orrery/user/memory/MEMORY.md`. Missing file → print nothing,
   exit 0.
2. If `fragments/` is non-empty, appends the pending-fragments block (same
   wording as `orrery_user_memory_read`).
3. Truncates output at 25,600 bytes. If truncated, appends:
   `\n\n(truncated — read full via orrery_user_memory_read)`.
4. Writes to stdout, exits 0. Stderr is silent unless a real error occurs.

### Per-tool hook installers

A new protocol abstracts the per-tool config-file mechanics:

```swift
protocol UserMemoryHookInstaller {
    func install(at configDir: URL) throws
    func remove(at configDir: URL) throws
    func isInstalled(at configDir: URL) -> Bool
}
```

Three implementations, one per tool:

#### `ClaudeHookInstaller`

- Target file: `<configDir>/settings.json`.
- Reads existing JSON, locates/creates `hooks.SessionStart`, ensures one
  entry with `command == "orrery memory user emit"` and
  `_orrery_managed == true`. Idempotent.
- `remove` deletes only entries with `_orrery_managed == true`.

#### `CodexHookInstaller`

- Target file: `<configDir>/hooks.json` (sibling of `config.toml`, not its
  contents).
- Same JSON-merge semantics as Claude.
- Schema/key names follow the Codex CLI hook reference at PR time; this spec
  reserves the right to adjust them before merge.

#### `GeminiHookInstaller`

- Target file: `<env>/gemini/settings.json` — the real file backing the
  `<env>/gemini-home/.gemini/settings.json` symlink that Gemini CLI actually
  reads (Gemini CLI ignores `GEMINI_CONFIG_DIR` and resolves only via `~/.gemini/`,
  so the wrapper redirects `HOME`; writing to the real file is equivalent and
  avoids walking the symlink).
- Same JSON-merge semantics as Claude.

### `EnvironmentStore` integration

```swift
extension EnvironmentStore {
    func ensureUserMemoryHooks(for envName: String) throws    // calls each installer
    func removeUserMemoryHooks(for envName: String) throws
}
```

Called from:

- `addTool` — when a tool is added to an env that has `shareUserMemory=true`.
- `orrery use <env>` activation — reconciles all tools' hooks to current
  `shareUserMemory` state.
- `orrery memory user enable/disable` — direct flip.
- `originTakeover` — applies the same logic against `~/.orrery/origin/`.

## Env config schema changes

`OrreryEnvironment` and `OriginConfig` both gain:

```swift
public var shareUserMemory: Bool   // default true
```

Codable: `decodeIfPresent(... ) ?? true` — existing env.json files without
this field are automatically treated as enabled. **No data migration
required.**

## Wizard changes

The env-creation wizard already asks about project-memory isolation. A new
question is appended *after* that block:

```
User memory (cross-project, cross-env personal memory layer)

  ▸ Enable (recommended)
    Disable for this env

Default: Enable.  Esc to keep default.
```

The wizard writes `shareUserMemory` into the new env's `env.json` and the
top-level setup loop will run `ensureUserMemoryHooks` after wizard exit, so
the hook lands in every tool config that exists in the new env.

`orrery setup` (origin path) gains the same question for `OriginConfig`.

## Failure modes & edge cases

| Situation | Behavior |
|---|---|
| `orrery` not on PATH when hook fires | Hook fails, AI tool warns but session continues. Documented in setup output. |
| `~/.orrery/user/memory/MEMORY.md` missing | `emit` prints nothing, exits 0. |
| `MEMORY.md` exceeds 25KB | `emit` truncates and appends a recovery hint pointing at the MCP read tool. |
| User manually edits `settings.json` to delete the hook entry | Treated as transient drift. Next `orrery use` reconciles based on `shareUserMemory`; if `true`, the entry is restored. To opt out persistently, use `orrery memory user disable`. |
| Two machines write concurrently | Fragments accumulate independently; next `orrery_user_memory_read` (or `emit`) surfaces them; AI consolidates and writes back `append=false`. Identical to project-layer semantics. |
| `shareUserMemory=true` but env has no tool installed yet | `ensureUserMemoryHooks` no-ops for that tool; later `addTool` installs the hook. |
| Existing third-party hook entries in `settings.json` | Untouched. Installer only modifies / removes entries that carry `_orrery_managed: true`. |

## Cross-machine sync

`orrery-sync`'s config gains one extra watched path:

```
~/.orrery/user/memory/fragments/
```

No protocol or transport change. The fragments format
(`f-{id}-{peer}.md` with frontmatter `id`/`peer`/`timestamp`/`action`) is the
same one the project layer uses, so consolidation logic on the read side is
identical.

## Testing approach

- **`MemoryStore` unit tests:** read/write/append/overwrite + fragment
  generation + fragment consolidation, parameterised so the same suite runs
  for both project and user instances.
- **`emit` command tests:** missing file, 25KB truncation, fragments
  appendix, no-fragments case.
- **`UserMemoryHookInstaller` tests, per implementation:** install on empty
  config, install on config with foreign hooks present, install idempotency,
  remove only-our-entries, remove with no entries.
- **`EnvironmentStore.ensureUserMemoryHooks` integration:** create env with
  Claude+Codex+Gemini, toggle `shareUserMemory`, assert each tool's config
  reflects the flag.
- **CLI rename:** snapshot tests for the new `orrery memory project ...` and
  `orrery memory user ...` help output.
- **Wizard:** scripted run that answers default → assert new env has
  `shareUserMemory=true` and hooks installed; second run with disable → assert
  `false` and hooks absent.

## Migration & rollout

- **Version bump:** v2.6.x → **v3.0.0** (CLI rename is breaking).
- **Release notes:** dedicated section on the rename + new user-memory layer.
- **Existing data:** untouched. `~/.orrery/shared/memory/{key}/` continues to
  hold project memory. Users wanting to promote entries up to the user layer
  do so manually (or with the future `import` helper).
- **Existing envs:** transparent upgrade. `shareUserMemory` defaults to `true`;
  the first `orrery use <env>` post-upgrade installs the hooks in that env's
  tool configs.
- **Existing hook conflict in user's settings.json:** safe — installer
  appends, doesn't replace; marker enables clean removal later.

## Future work

- `orrery memory user import <project-key>` — interactive helper to lift
  project-layer entries that are really cross-project into the user layer.
- Cross-tool hook conflict detection (warn if a tool already has a non-Orrery
  SessionStart hook calling something memory-related).
- Custom `userMemoryStoragePath` for users who want the user-memory store
  pointed at an external location (Obsidian vault etc.). Parallels the
  existing `memoryStoragePath` on `OrreryEnvironment`.
- A `phantom`-style ephemeral env that *doesn't* inherit user memory
  (useful for demos / screen recordings).
