# Design — `orrery thirdparty install cc-statusline`

**Date:** 2026-04-20
**Status:** Draft, pending user review

## Goal

Let users install third-party add-ons into an orrery-managed Claude environment
without touching the global `~/.claude/` directory. The first supported add-on
is `cc-statusline`. The design establishes a reusable, manifest-driven mechanism
so additional add-ons can ship later without CLI or protocol changes.

## Non-goals

- Dynamic loading of third-party Swift code.
- Installing to multiple envs in one command (explicit `--env` only).
- Installing to `origin/claude/`.
- Guaranteeing that the add-on itself runs correctly (that is the add-on's
  contract with Claude Code; orrery only places files and patches config).

## Scoped decisions

| # | Decision |
|---|---|
| 1 | Install targets a single env via `--env <name>`; no `current` fallback. |
| 2 | Architecture is manifest-driven. v1 ships a built-in registry only; `path` / URL resolvers are a later extension. |
| 3 | `settings.json` is deep-merged: objects recurse, arrays append + dedupe by `command`, scalars overwrite. |
| 4 | Source abstraction ships with `git:` (used by cc-statusline). `tarball:` and `vendored:` are reserved; `vendored:` is implemented for integration tests. |
| 5 | Install and uninstall both supported in v1, backed by a per-package lock file. |
| 6 | Source clones live in a shared cache (`~/.orrery/shared/thirdparty/cache/`), keyed by resolved commit SHA. |
| 7 | Manifest default `ref: main`; CLI `--ref <git-ref>` overrides. Missing `node` only emits a warning. Re-install auto-uninstalls the previous version first. |
| 8 | Hook commands in `settings.json` are written with install-time absolute paths (no `${CLAUDE_CONFIG_DIR}` runtime expansion). |

## Package layout

```swift
.target(name: "OrreryCore", ...),                                 // existing
.target(
    name: "OrreryThirdParty",                                      // new
    dependencies: ["OrreryCore"],
    path: "Sources/OrreryThirdParty",
    resources: [.process("Manifests")]
),
.executableTarget(
    name: "orrery-bin",
    dependencies: ["OrreryCore", "OrreryThirdParty"],              // adds ThirdParty
    path: "Sources/orrery"
),
.testTarget(
    name: "OrreryThirdPartyTests",
    dependencies: ["OrreryThirdParty"],
    path: "Tests/OrreryThirdPartyTests"
),
```

### Boundary

- **`OrreryCore`** — defines protocols (`ThirdPartyRunner`, `ThirdPartyRegistry`),
  value types (`ThirdPartyPackage`, `ThirdPartySource`, `ThirdPartyStep`,
  `InstallRecord`, `SettingsPatchRecord`), and nothing else. No concrete source
  fetcher, no concrete runner, no embedded manifests.
- **`OrreryThirdParty`** — all concrete implementations: `GitSource`,
  `VendoredSource`, `ManifestParser`, `BuiltInRegistry`, `ManifestRunner`,
  `SettingsJSONPatcher`, `FileCopier`, plus the bundled `cc-statusline.yaml`.
- **`orrery-bin`** — registers `ThirdPartyCommand` with subcommands and wires
  a `ManifestRunner` backed by `BuiltInRegistry`.

Core owns the protocol so future Core features (e.g. `orrery use` auto-setup)
can invoke a runner injected from the binary without pulling the ThirdParty
target into Core.

## Core protocol surface

Files under `Sources/OrreryCore/ThirdParty/`.

```swift
public struct ThirdPartyPackage: Sendable {
    public let id: String
    public let displayName: String
    public let description: String
    public let source: ThirdPartySource
    public let steps: [ThirdPartyStep]
}

public enum ThirdPartySource: Sendable {
    case git(url: String, ref: String)
    case tarball(url: String, sha256: String)   // reserved
    case vendored(bundlePath: String)           // used by tests
}

public enum ThirdPartyStep: Sendable {
    case copyFile(from: String, to: String)
    case copyGlob(from: String, toDir: String)
    case patchSettings(file: String, patch: SettingsPatch)
}

public protocol ThirdPartyRunner: Sendable {
    func install(_ pkg: ThirdPartyPackage,
                 into env: String,
                 refOverride: String?,
                 forceRefresh: Bool) throws -> InstallRecord
    func uninstall(packageID: String, from env: String) throws
    func listInstalled(in env: String) throws -> [InstallRecord]
}

public protocol ThirdPartyRegistry: Sendable {
    func lookup(_ id: String) throws -> ThirdPartyPackage
    func listAvailable() -> [String]
}

public struct InstallRecord: Codable, Sendable {
    public let packageID: String
    public let resolvedRef: String                // 40-char SHA from git rev-parse HEAD
    public let manifestRef: String                // what the manifest / CLI asked for
    public let installedAt: Date
    public let copiedFiles: [String]              // relative to claudeDir
    public let patchedSettings: [SettingsPatchRecord]
}

public struct SettingsPatchRecord: Codable, Sendable {
    public let file: String                       // relative to claudeDir
    public let entries: [Entry]
    public struct Entry: Codable, Sendable {
        public let keyPath: [String]              // ["hooks", "UserPromptSubmit"]
        public let before: BeforeState            // reconstruct to undo
    }
    public enum BeforeState: Codable, Sendable {
        case absent
        case scalar(previous: JSONValue)
        case object(addedKeys: [String])          // keys we newly introduced
        case array(appendedElements: [JSONValue]) // exact elements we appended
    }
}
```

`SettingsPatch` and `JSONValue` are Codable value types living in the same file;
`JSONValue` is a recursive enum (object / array / string / number / bool / null)
sufficient for `settings.json` content.

## Manifest schema

YAML, matching the Codable shapes above. Example (the bundled
`cc-statusline.yaml`):

```yaml
id: cc-statusline
displayName: cc-statusline
description: Full statusline dashboard for Claude Code
source:
  type: git
  url: https://github.com/NYCU-Chung/cc-statusline
  ref: main
steps:
  - type: copyFile
    from: statusline.js
    to: statusline.js
  - type: copyGlob
    from: hooks/*.js
    toDir: hooks
  - type: patchSettings
    file: settings.json
    patch:
      statusLine:
        type: command
        command: "node <CLAUDE_DIR>/statusline.js"
        refreshInterval: 30
      hooks:
        SubagentStart:
          - matcher: ".*"
            hooks:
              - { type: command, command: "node <CLAUDE_DIR>/hooks/subagent-tracker.js" }
        SubagentStop:
          - matcher: ".*"
            hooks:
              - { type: command, command: "node <CLAUDE_DIR>/hooks/subagent-tracker.js" }
        PreCompact:
          - matcher: ".*"
            hooks:
              - { type: command, command: "node <CLAUDE_DIR>/hooks/compact-monitor.js" }
        UserPromptSubmit:
          - hooks:
              - { type: command, command: "node <CLAUDE_DIR>/hooks/message-tracker.js" }
              - { type: command, command: "node <CLAUDE_DIR>/hooks/summary-updater.js" }
        Stop:
          - matcher: "*"
            hooks:
              - { type: command, command: "node <CLAUDE_DIR>/hooks/message-tracker.js" }
        PostToolUse:
          - matcher: "Write|Edit"
            hooks:
              - { type: command, command: "node <CLAUDE_DIR>/hooks/file-tracker.js" }
```

### Path placeholders

`<CLAUDE_DIR>` is a manifest-level sentinel substituted at install time with
the env's absolute claude config dir (e.g. `/Users/foo/.orrery/envs/<uuid>/claude`).
This substitution happens inside `ManifestRunner` before `patchSettings` touches
the file, so the on-disk `settings.json` contains only absolute paths and no
dependency on runtime environment variables.

### Merge semantics

- Object values → recursive merge; newly introduced child keys recorded in
  `Entry.before = .object(addedKeys: ...)`.
- Array values → for each element in the patch, append it if no existing
  element in the target array is equal under the comparator below; recorded
  in `Entry.before = .array(appendedElements: ...)` so undo removes the exact
  JSON values we added.
- Scalars → overwrite; previous value recorded in `Entry.before = .scalar(...)`.

### Array equality comparator

- Default: deep-equal JSON.
- Special case for arrays whose element shape looks like a hook-matcher
  (object with a `hooks` child that is itself an array of `{ type, command }`):
  two elements are considered equal when they have the same `matcher` value
  (or both absent) **and** the same set of `command` strings inside `hooks[]`
  (order-insensitive, compared after `<CLAUDE_DIR>` substitution).
- This shape check is applied per array individually; it does not globally
  change how other arrays are compared.

Rationale: the hook-matcher comparator lets a re-install (after a manually
deleted lock file) skip entries that are already fully present, without
touching entries the user added independently.

## Directory layout

### Shared cache

```
~/.orrery/shared/thirdparty/
├── cache/
│   └── cc-statusline/
│       └── @<commit-sha>/       # git clone --depth 1, then rev-parse HEAD
│           ├── statusline.js
│           └── hooks/
└── registry/                     # reserved for external manifest resolvers
```

- Cache key: `<packageID>@<resolvedSHA>`. Branch refs re-resolve via
  `git ls-remote` before deciding whether to reuse cache.
- `--force-refresh` removes the SHA directory and re-clones.
- Uninstall never touches cache (other envs may share).

### Per-env

```
<env>/claude/
├── statusline.js                 # copyFile step
├── hooks/                        # copyGlob step
│   └── *.js
├── settings.json                 # patchSettings step
└── .thirdparty/
    └── cc-statusline.lock.json   # InstallRecord
```

The lock file lives inside the env's claude dir so it is deleted automatically
when the env is deleted, and never co-locates with cross-env cache state.

## CLI surface

```
orrery thirdparty install <id> --env <name> [--ref <git-ref>] [--force-refresh]
orrery thirdparty uninstall <id> --env <name>
orrery thirdparty list --env <name>
orrery thirdparty available
```

- `install`: runs the full flow below. If already installed, runs uninstall
  first, then install (see decision 7).
- `uninstall`: reads the lock file and reverses it; errors if no lock exists.
- `list`: prints all `InstallRecord`s found in `<env>/claude/.thirdparty/`.
- `available`: prints IDs from `BuiltInRegistry.listAvailable()`.

## Install flow

1. `BuiltInRegistry.lookup(id)` → `ThirdPartyPackage`. `--ref` overrides
   `source.ref` for the `git` case.
2. `EnvironmentStore.envDir(for: env)` validates the env exists; resolve
   `claudeDir = toolConfigDir(tool: .claude, environment: env)`.
3. If `<claudeDir>/.thirdparty/<id>.lock.json` exists, print a notice and
   invoke the uninstall flow before continuing.
4. Pre-checks (non-fatal): `which node`; missing → print warning, continue.
5. Source prep (`GitSource`):
   - Resolve ref to a SHA. If the ref is already 40 hex chars, use it as-is.
     Otherwise `git ls-remote <url> <ref>` returns the SHA.
   - `cacheDir = ~/.orrery/shared/thirdparty/cache/<id>/@<sha>/`.
   - Cache miss or `--force-refresh` → `git clone --depth 1 --branch <ref>`;
     on a pure SHA ref, clone the default branch then `git checkout <sha>`.
   - Cache hit → no-op.
6. Execute steps with an `InstallRecordBuilder` that tracks completed work.
   Any step throws → `builder.rollback()` reverses completed steps in reverse
   order, then rethrows.
   - `copyFile`: copy `<cacheDir>/<from>` → `<claudeDir>/<to>`; append to
     `copiedFiles`.
   - `copyGlob`: expand `<cacheDir>/<from>` (simple `*.ext` glob), copy each
     match into `<claudeDir>/<toDir>/`; append all destinations to
     `copiedFiles`.
   - `patchSettings`: load `<claudeDir>/<file>` (missing → `{}`), substitute
     `<CLAUDE_DIR>` in the patch, deep-merge, atomic write (`.tmp` + rename),
     append a `SettingsPatchRecord`.
7. Write `<claudeDir>/.thirdparty/<id>.lock.json` with the complete
   `InstallRecord`.
8. Print: files copied, settings patched, resolved short SHA.

## Uninstall flow

1. Read `<claudeDir>/.thirdparty/<id>.lock.json`; missing → error.
2. For each `SettingsPatchRecord` in reverse order:
   - Load `<claudeDir>/<file>`.
   - For each entry, walk to `keyPath` and restore based on `before`:
     - `absent` → delete the key.
     - `scalar(previous)` → overwrite with `previous`.
     - `object(addedKeys)` → delete only those child keys; if the resulting
       object is empty **and** we were the ones who created it (parent
       entry's before was `absent`), also remove the parent key.
     - `array(appendedElements)` → remove elements equal to any entry in
       `appendedElements` under the same comparator used for append (hook-
       matcher rule where applicable, otherwise deep-equal JSON).
   - Atomic write.
3. Delete each path in `copiedFiles` (missing → skip, do not error).
4. Delete the lock file.
5. Leave the shared cache alone.

Uninstall is best-effort on the filesystem side (files may have been hand-edited
or deleted). The goal is a clean exit, not byte-equal restoration of anything
the user has touched after install. The settings restoration, however, is
exact provided the user has not hand-edited the keys we patched.

## Testing

### Unit tests (`OrreryThirdPartyTests`)

1. `SettingsJSONPatcher`:
   - Empty settings + full patch → full write, all `before` entries `absent`.
   - Existing `statusLine` + overwrite → new value written, previous captured
     in `.scalar(previous:)`.
   - Existing `hooks.UserPromptSubmit` array with an unrelated matcher + our
     patch element → our element appended, user's untouched.
   - Hook-matcher element already fully equivalent under the hook-matcher
     comparator → skipped, recorded with `appendedElements: []`.
   - Hook-matcher element present but with a different `command` inside
     `hooks[]` → our element appended as a separate entry (current comparator
     is whole-element equality; per-command merging is out of scope for v1).
   - Uninstall: `absent` → key deleted; object → only added child keys
     deleted (plus parent key if it became empty and was itself `absent`
     before); array → exact appended elements removed, others untouched.
   - Round-trip: starting from a canonical JSON file (sorted keys, 2-space
     indent — our write format), patch → unpatch yields a byte-equal file.
     The canonical form is what every write path produces, so this invariant
     holds whenever the round-trip begins after any prior orrery write or
     from an orrery-written snapshot.

2. `ManifestParser`:
   - `cc-statusline.yaml` parses into the expected `ThirdPartyPackage`.
   - Missing `source.url` / `source.ref` → throws.
   - Unknown `step.type` → throws.
   - `copyGlob.from` not matching `*.ext` form → throws.

3. `BuiltInRegistry`:
   - `lookup("cc-statusline")` succeeds.
   - `lookup("does-not-exist")` throws with a readable message.
   - `listAvailable()` contains `cc-statusline`.

4. `InstallRecord` codec:
   - JSON round-trip.
   - `resolvedRef` validates as 40-char hex.

### Integration tests

- `GitSource` real clone, gated by `SKIP_NETWORK_TESTS=1`: clone
  `cc-statusline` main, assert `statusline.js` and `hooks/*.js` exist in cache.
- Full install/uninstall round-trip using a `vendored:` fixture to avoid the
  network:
  - Build temp `<home>/.orrery/` and a fake env.
  - `install` → assert `statusline.js`, `hooks/`, `.thirdparty/*.lock.json`
    exist; assert `settings.json` matches expected content.
  - `uninstall` → assert all of the above are gone and `settings.json` is
    byte-equal to its pre-install state.

### Not tested

- Whether Claude Code actually executes the statusline / hooks correctly
  (belongs to cc-statusline × Claude Code).
- Whether `node` is available at runtime (install only warns).

## Future extensions (explicitly deferred)

- `orrery thirdparty install ./path/to/manifest.yaml`
- `orrery thirdparty install https://.../manifest.yaml`
- `tarball:` source using GitHub's auto-generated `archive/<ref>.tar.gz` plus
  sha256 verification.
- `orrery thirdparty available --remote` pulling from a curated index.
- Auto-install on `orrery use` driven by an env-level `thirdparty: [...]` field.

None of these require protocol changes; each is an additional resolver or CLI
surface sitting on top of the same `ManifestRunner`.
