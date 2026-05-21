# v3.0 Command Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote `account` commands to top level (`orrery add/list/show/use/remove`), demote `env` to a `sandbox` namespace (`orrery sandbox create/use/...`), delete `auth`/`origin`/`deactivate`, and ship as **v3.0.0** with no backward-compat aliases.

**Architecture:** Build `SandboxCommand` (a `ParsableCommand` with nested subcommand structs) alongside the existing top-level env commands. Move env-related verbs one by one into `SandboxCommand` (their nested struct copies the existing body) and delete the old top-level files. Then rename `Account*Command` → `*Command` to claim the freed-up top-level slots. Rewrite `ShellFunctionGenerator` to match the new dispatch shape. Rename phantom IPC sentinel field `TARGET_ENV` → `TARGET_SANDBOX` and internal command `_phantom-trigger` → `_phantom-trigger-sandbox`.

**Tech Stack:** Swift 6, ArgumentParser, swift-testing (`@Suite`/`@Test`/`#expect`), L10n codegen plugin.

> **L10n key shape:** This codebase uses **2-segment flat camelCase** keys throughout (e.g. `"sandbox.setEnvAbstract"` → `L10n.Sandbox.setEnvAbstract`). Do NOT introduce 3-segment dot-nested keys (e.g. `"sandbox.setEnv.abstract"` → `L10n.Sandbox.SetEnv.abstract`) — the codegen plugin does not produce a nested `SetEnv` enum.

**Spec:** `docs/superpowers/specs/2026-05-21-v3-command-restructure-design.md` (markdown) and `.html` (illustrated).

---

## File Structure

### Created

| Path | Responsibility |
|------|----------------|
| `Sources/OrreryCore/Commands/SandboxCommand.swift` | New parent. Holds nested subcommand structs for `create`, `use`, `list`, `delete`, `info`, `rename`, `current`, `memory`, `sync`, `set-env`, `unset-env`, `export`, `unexport`. |
| `Sources/OrreryCore/Commands/AddCommand.swift` | Top-level account add (renamed from `AccountAddCommand.swift`). |
| `Sources/OrreryCore/Commands/ListCommand.swift` (new content) | Top-level account list (renamed/repurposed; the old env-list content moves into `SandboxCommand.List`). |
| `Sources/OrreryCore/Commands/ShowCommand.swift` | Top-level account show (renamed from `AccountShowCommand.swift`). |
| `Sources/OrreryCore/Commands/UseCommand.swift` (new content) | Top-level account use (renamed/repurposed; the old env-use content moves into `SandboxCommand.Use`). |
| `Sources/OrreryCore/Commands/RemoveCommand.swift` | Top-level account remove (renamed from `AccountRemoveCommand.swift`). |
| `Sources/OrreryCore/Commands/PhantomSandboxTriggerCommand.swift` | Renamed from `PhantomTriggerCommand.swift`. |

### Deleted

- `Sources/OrreryCore/Commands/EnvCommand.swift` (env-var commands move into Sandbox.set-env/unset-env)
- `Sources/OrreryCore/Commands/CreateCommand.swift` (→ `SandboxCommand.Create`)
- `Sources/OrreryCore/Commands/UseCommand.swift` (old env-use body → `SandboxCommand.Use`; file slot reused for new account use)
- `Sources/OrreryCore/Commands/ListCommand.swift` (old env-list body → `SandboxCommand.List`; file slot reused)
- `Sources/OrreryCore/Commands/DeleteCommand.swift` (→ `SandboxCommand.Delete`)
- `Sources/OrreryCore/Commands/InfoCommand.swift` (→ `SandboxCommand.Info`)
- `Sources/OrreryCore/Commands/RenameCommand.swift` (→ `SandboxCommand.Rename`)
- `Sources/OrreryCore/Commands/CurrentCommand.swift` (→ `SandboxCommand.Current`)
- `Sources/OrreryCore/Commands/MemoryCommand.swift` (→ `SandboxCommand.Memory`)
- `Sources/OrreryCore/Commands/SyncCommand.swift` (→ `SandboxCommand.Sync`)
- `Sources/OrreryCore/Commands/ExportCommand.swift` (→ `SandboxCommand.Export`)
- `Sources/OrreryCore/Commands/UnexportCommand.swift` (→ `SandboxCommand.Unexport`)
- `Sources/OrreryCore/Commands/AccountCommand.swift` (parent removed; subcommands promoted to top level)
- `Sources/OrreryCore/Commands/AccountAddCommand.swift` → renamed to `AddCommand.swift`
- `Sources/OrreryCore/Commands/AccountListCommand.swift` → content moved to (new) `ListCommand.swift`
- `Sources/OrreryCore/Commands/AccountShowCommand.swift` → renamed to `ShowCommand.swift`
- `Sources/OrreryCore/Commands/AccountUseCommand.swift` → content moved to (new) `UseCommand.swift`
- `Sources/OrreryCore/Commands/AccountRemoveCommand.swift` → renamed to `RemoveCommand.swift`
- `Sources/OrreryCore/Commands/AuthCommand.swift` (deleted, no replacement)
- `Sources/OrreryCore/Commands/OriginCommand.swift` (deleted; takeover is automatic; release functionality verified in uninstall)
- `Sources/OrreryCore/Commands/PhantomTriggerCommand.swift` → renamed to `PhantomSandboxTriggerCommand.swift`

### Modified

| Path | Change |
|------|--------|
| `Sources/orrery/OrreryCommand.swift` | Subcommand list reshaped: remove env-related top-level, add `SandboxCommand`, rename account subcommands |
| `Sources/OrreryCore/Shell/ShellFunctionGenerator.swift` | Case statement rewritten: `sandbox)` / `add)` / `run)`. Old `use)`, `deactivate)`, `create)`, `account)` cases removed/replaced. |
| `Sources/OrreryCore/Commands/PhantomAccountTriggerCommand.swift` | Sentinel write call updated (`targetSandbox:` instead of `targetEnv:`); references to renamed `PhantomSandboxTriggerCommand`. |
| `Sources/OrreryCore/Commands/AccountAddPrepareCommand.swift` | Reference to `AccountAddCommand.resolveTool` → `AddCommand.resolveTool`. |
| `Sources/OrreryCore/Commands/AccountAddFinalizeCommand.swift` | Reference to `AccountAddCommand` updates. |
| `Sources/OrreryCore/Commands/UninstallCommand.swift` | Verify it covers origin release; add if missing. |
| `Sources/OrreryCore/Resources/Localization/{en,zh-Hant,ja}.json` | Remove `auth.*`, `origin.*`, `envVar.*` (renamed to `sandbox.setEnv.*`). Rename namespace where verbs moved. |
| `Sources/OrreryCore/Resources/Localization/keys.md` | Update sections. |
| `Sources/OrreryCore/Resources/Localization/l10n-signatures.json` | Sync. |
| `Sources/OrreryCore/Version.swift` | `current` → `"3.0.0"`. |
| `Sources/OrreryCore/MCP/MCPServer.swift` | `currentVersion()` returns `"3.0.0"` via `OrreryVersion.current`. |
| `CHANGELOG.md` | v3.0.0 entry with full breaking-change table. |
| `docs/index.html` / `docs/zh_TW.html` | Badge bump to `v3.0.0`. |
| `Tests/OrreryTests/*` | Update every test that constructs the renamed/moved commands. |

---

## Task 1: Scaffold `SandboxCommand` + move env-var

**Files:**
- Create: `Sources/OrreryCore/Commands/SandboxCommand.swift`
- Delete: `Sources/OrreryCore/Commands/EnvCommand.swift`
- Modify: `Sources/orrery/OrreryCommand.swift` (replace `EnvCommand.self` with `SandboxCommand.self` in subcommands list)
- Modify: `Sources/OrreryCore/Resources/Localization/{en,zh-Hant,ja}.json`, `keys.md`, `l10n-signatures.json`
- Test: `Tests/OrreryTests/EnvVarCommandTests.swift` (if exists) — rename and adapt; otherwise add `Tests/OrreryTests/SandboxCommandTests.swift`.

- [ ] **Step 1: Add new L10n keys for `sandbox.setEnv` / `sandbox.unsetEnv`**

Read the existing `envVar.*` keys in `en.json` first. The new keys reuse the same English strings but under a different namespace. Add to `en.json`:

```json
"sandbox.abstract": "Manage sandboxes (advanced isolation: memory, sessions, env-vars).",
"sandbox.setEnvAbstract": "Set an environment variable on a sandbox.",
"sandbox.setEnvKeyHelp": "Variable name.",
"sandbox.setEnvValueHelp": "Variable value.",
"sandbox.setEnvSandboxHelp": "Target sandbox (default: active sandbox).",
"sandbox.setEnvNoActive": "No active sandbox. Use 'orrery sandbox use <name>' first or pass -s.",
"sandbox.setEnvOriginNotSupported": "Cannot set env vars on the origin sandbox.",
"sandbox.setEnvSuccess": "Set {key} on sandbox '{name}'.",
"sandbox.unsetEnvAbstract": "Unset an environment variable on a sandbox.",
"sandbox.unsetEnvKeyHelp": "Variable name.",
"sandbox.unsetEnvSuccess": "Unset {key} on sandbox '{name}'."
```

Add equivalent zh-Hant / ja translations (match the existing `envVar.*` translations word-for-word, just under the new key paths).

Add corresponding entries to `l10n-signatures.json` and `keys.md`.

- [ ] **Step 2: Write SandboxCommand scaffold**

Create `Sources/OrreryCore/Commands/SandboxCommand.swift`:

```swift
import ArgumentParser
import Foundation

public struct SandboxCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sandbox",
        abstract: L10n.Sandbox.abstract,
        subcommands: [SetEnv.self, UnsetEnv.self]
        // More subcommands added in later tasks.
    )

    public init() {}

    // MARK: - SetEnv

    public struct SetEnv: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "set-env",
            abstract: L10n.Sandbox.setEnvAbstract
        )

        @Argument(help: ArgumentHelp(L10n.Sandbox.setEnvKeyHelp)) public var key: String
        @Argument(help: ArgumentHelp(L10n.Sandbox.setEnvValueHelp)) public var value: String
        @Option(name: [.short, .customLong("sandbox")],
                help: ArgumentHelp(L10n.Sandbox.setEnvSandboxHelp)) public var sandbox: String?

        public init() {}

        public func run() throws {
            guard let envName = sandbox ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"] else {
                throw ValidationError(L10n.Sandbox.setEnvNoActive)
            }
            guard envName != ReservedEnvironment.defaultName else {
                throw ValidationError(L10n.Sandbox.setEnvOriginNotSupported)
            }
            let store = EnvironmentStore.default
            var env = try store.load(named: envName)
            env.env[key] = value
            try store.save(env)
            print(L10n.Sandbox.setEnvSuccess(key, envName))
        }
    }

    // MARK: - UnsetEnv

    public struct UnsetEnv: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "unset-env",
            abstract: L10n.Sandbox.unsetEnvAbstract
        )

        @Argument(help: ArgumentHelp(L10n.Sandbox.unsetEnvKeyHelp)) public var key: String
        @Option(name: [.short, .customLong("sandbox")],
                help: ArgumentHelp(L10n.Sandbox.setEnvSandboxHelp)) public var sandbox: String?

        public init() {}

        public func run() throws {
            // Borrows `setEnvNoActive` / `setEnvOriginNotSupported` from SetEnv:
            // the user-facing strings are tool-action-agnostic and apply equally to unset.
            // If the unset path ever needs different wording, add dedicated keys.
            guard let envName = sandbox ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"] else {
                throw ValidationError(L10n.Sandbox.setEnvNoActive)
            }
            guard envName != ReservedEnvironment.defaultName else {
                throw ValidationError(L10n.Sandbox.setEnvOriginNotSupported)
            }
            let store = EnvironmentStore.default
            var env = try store.load(named: envName)
            env.env.removeValue(forKey: key)
            try store.save(env)
            print(L10n.Sandbox.unsetEnvSuccess(key, envName))
        }
    }
}
```

- [ ] **Step 3: Delete `EnvCommand.swift`**

Run: `rm Sources/OrreryCore/Commands/EnvCommand.swift`

- [ ] **Step 4: Register `SandboxCommand` in root**

Modify `Sources/orrery/OrreryCommand.swift`. Find the line `EnvCommand.self,` in the subcommands array and replace with `SandboxCommand.self,`. Keep alphabetical-ish ordering similar to the existing.

- [ ] **Step 5: Delete obsolete `envVar.*` L10n keys**

Remove the `envVar.abstract`, `envVar.setAbstract`, `envVar.unsetAbstract`, `envVar.envHelp`, `envVar.noActive`, `envVar.defaultNotSupported`, `envVar.set`, `envVar.unset` keys from all three locale files, `keys.md`, and `l10n-signatures.json`.

- [ ] **Step 6: Update tests**

Find any tests referencing `EnvCommand.SetSubcommand` or `EnvCommand.UnsetSubcommand` (grep `Tests/`). Update construction to `SandboxCommand.SetEnv` / `SandboxCommand.UnsetEnv`. The parse arguments change: tests using `EnvCommand.SetSubcommand.parse(["FOO", "bar", "-e", "work"])` become `SandboxCommand.SetEnv.parse(["FOO", "bar", "-s", "work"])`.

- [ ] **Step 7: Verify**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
```

Expected: build clean, all tests pass. The CLI now responds to `orrery sandbox set-env FOO bar -s work` (`set-env` / `unset-env` are leaf verbs of `orrery sandbox`).

- [ ] **Step 8: Commit**

```bash
git add Sources/ Tests/ docs/
git commit -m "[REFACTOR] SandboxCommand scaffold; move env-var commands → sandbox set-env/unset-env"
```

---

## Task 2: Move simple env commands into Sandbox

Move 6 env-related commands as nested subcommands of `SandboxCommand`: `Use`, `List`, `Delete`, `Info`, `Rename`, `Current`. The bodies copy verbatim; only the struct nesting + commandName references change.

**Files:**
- Modify: `Sources/OrreryCore/Commands/SandboxCommand.swift` (add 6 nested structs)
- Delete: `Sources/OrreryCore/Commands/UseCommand.swift`, `ListCommand.swift`, `DeleteCommand.swift`, `InfoCommand.swift`, `RenameCommand.swift`, `CurrentCommand.swift`
- Modify: `Sources/orrery/OrreryCommand.swift` (remove 6 entries from subcommands list)
- Modify: `Tests/OrreryTests/` — update any test constructing these commands directly.

For EACH of the 6 commands, do this:

- [ ] **Step 1 (per command): Read the existing file**

For `UseCommand`, read `Sources/OrreryCore/Commands/UseCommand.swift`. Note the full struct body. Same for the other 5.

- [ ] **Step 2 (per command): Add nested struct to SandboxCommand**

Inside the `SandboxCommand` struct (between `UnsetEnv` and the closing brace), add a nested struct with the same body. Example for `Use`:

```swift
    // MARK: - Use

    public struct Use: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "use",
            abstract: L10n.Use.abstract
        )

        @Argument(help: ArgumentHelp(L10n.Use.nameHelp))
        public var name: String

        public init() {}

        public func run() throws {
            stderrWrite(L10n.Use.needsShellIntegration)
            throw ExitCode.failure
        }
    }
```

Repeat the exact same pattern for `List`, `Delete`, `Info`, `Rename`, `Current` — copy each command's full body verbatim into a nested struct named after the verb.

- [ ] **Step 3: Update `SandboxCommand.configuration.subcommands`**

At this point ONLY the 6 commands added in this task (plus the 2 from Task 1) exist as nested structs. Update the subcommands array to:

```swift
subcommands: [
    SetEnv.self, UnsetEnv.self,        // from Task 1
    Use.self, List.self, Delete.self, Info.self, Rename.self, Current.self,
    // Create / Memory / Sync / Export / Unexport added in Tasks 3 and 4
]
```

Tasks 3 and 4 will add the remaining 5 nested structs and update this array.

- [ ] **Step 4: Delete the 6 old top-level files**

```bash
rm Sources/OrreryCore/Commands/UseCommand.swift
rm Sources/OrreryCore/Commands/ListCommand.swift
rm Sources/OrreryCore/Commands/DeleteCommand.swift
rm Sources/OrreryCore/Commands/InfoCommand.swift
rm Sources/OrreryCore/Commands/RenameCommand.swift
rm Sources/OrreryCore/Commands/CurrentCommand.swift
```

- [ ] **Step 5: Unregister from root command**

Modify `Sources/orrery/OrreryCommand.swift` — remove the 6 entries `UseCommand.self, ListCommand.self, DeleteCommand.self, InfoCommand.self, RenameCommand.self, CurrentCommand.self` from the subcommands array.

- [ ] **Step 6: Update tests**

`grep -rn "UseCommand\|ListCommand\|DeleteCommand\|InfoCommand\|RenameCommand\|CurrentCommand" Tests/`

For each test file that references these directly, update the references:
- `UseCommand` → `SandboxCommand.Use`
- `ListCommand` → `SandboxCommand.List`
- `DeleteCommand` → `SandboxCommand.Delete`
- `InfoCommand` → `SandboxCommand.Info`
- `RenameCommand` → `SandboxCommand.Rename`
- `CurrentCommand` → `SandboxCommand.Current`

Test parsing changes: `UseCommand.parse(["foo"])` → `SandboxCommand.Use.parse(["foo"])`.

- [ ] **Step 7: Verify**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
```

Expected: clean build, all tests pass. `orrery use foo` no longer works at top level — `orrery sandbox use foo` works.

- [ ] **Step 8: Commit**

```bash
git add Sources/ Tests/
git commit -m "[REFACTOR] move simple env commands → SandboxCommand nested subcommands"
```

---

## Task 3: Move `CreateCommand` into Sandbox

`CreateCommand` is larger (has wizard logic). Same pattern as Task 2 but separate task for clarity.

**Files:**
- Modify: `Sources/OrreryCore/Commands/SandboxCommand.swift` (add `Create` nested struct)
- Delete: `Sources/OrreryCore/Commands/CreateCommand.swift`
- Modify: `Sources/orrery/OrreryCommand.swift` (remove `CreateCommand.self` from subcommands)
- Modify: `Tests/OrreryTests/CreateCommandTests.swift` and any other referencing tests

- [ ] **Step 1: Read existing `CreateCommand.swift` and copy the full struct body**

This is a longer file (~30 lines of declarations + the wizard helpers). Plan to copy ALL of it verbatim into the nested struct.

- [ ] **Step 2: Add `SandboxCommand.Create` nested struct**

Copy the whole `CreateCommand` body into `SandboxCommand` as `public struct Create: ParsableCommand { ... }`. Keep `commandName: "create"`. Any helper functions defined on `CreateCommand` (e.g. `static func resolveSomething`) are moved inside the nested struct or made top-level free functions if used elsewhere.

- [ ] **Step 3: Add `Create.self` to `SandboxCommand` subcommands array**

- [ ] **Step 4: Delete `CreateCommand.swift`**

```bash
rm Sources/OrreryCore/Commands/CreateCommand.swift
```

- [ ] **Step 5: Unregister from root**

Remove `CreateCommand.self,` from `OrreryCommand.swift` subcommands.

- [ ] **Step 6: Update tests**

`grep -rn "CreateCommand" Tests/`. Replace references with `SandboxCommand.Create`.

- [ ] **Step 7: Update `ShellFunctionGenerator` `create)` case (partial)**

The shell function has a `create)` case that runs the command then prompts the user. That case stays in the shell, but the command it invokes is now `sandbox create`. Find lines 61-81 of `ShellFunctionGenerator.swift` (approximately):

```sh
create)
  command orrery-bin "$@"      # old: orrery create <name>
  ...
```

Change to:

```sh
sandbox)
  if [ "${2:-}" = "create" ]; then
    command orrery-bin "$@"    # orrery sandbox create <name>
    # ... rest of the post-create prompt logic
  else
    command orrery-bin "$@"    # other sandbox subcommands fall through
  fi
  ;;
```

This is partial — the full `sandbox)` rewrite is in Task 11. For now we just rename the case so the shell doesn't break for `orrery sandbox create`.

- [ ] **Step 8: Verify**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
```

- [ ] **Step 9: Commit**

```bash
git add Sources/ Tests/
git commit -m "[REFACTOR] CreateCommand → SandboxCommand.Create"
```

---

## Task 4: Move Memory, Sync, Export, Unexport into Sandbox

`MemoryCommand` has nested subcommands itself (Info, Export, Isolate, Share, Storage). Moving it into Sandbox means it becomes `SandboxCommand.Memory` with its own nested subcommands intact.

**Files:**
- Modify: `Sources/OrreryCore/Commands/SandboxCommand.swift` (add 4 nested structs/parents)
- Delete: `MemoryCommand.swift`, `SyncCommand.swift`, `ExportCommand.swift`, `UnexportCommand.swift`
- Modify: `Sources/orrery/OrreryCommand.swift` (remove 4 entries)
- Modify: tests

- [ ] **Step 1: Move `MemoryCommand` body into `SandboxCommand.Memory`**

Copy the entire `MemoryCommand` struct (including its nested subcommands `InfoSubcommand`, `ExportSubcommand`, `IsolateSubcommand`, `ShareSubcommand`, `StorageSubcommand`) into `SandboxCommand` as `public struct Memory: ParsableCommand { ... }`. Update `commandName: "memory"`. Nested subcommands' commandNames stay the same. The full path becomes `orrery sandbox memory info`, `orrery sandbox memory export`, etc.

- [ ] **Step 2: Move `SyncCommand` body into `SandboxCommand.Sync`**

It's a single command (no subcommands). Copy verbatim with `commandName: "sync"`.

- [ ] **Step 3: Move `ExportCommand` and `UnexportCommand`**

These are internal (`_export` / `_unexport`?). Read their files, copy bodies into `SandboxCommand.Export` and `SandboxCommand.Unexport`. Keep `shouldDisplay: false` if they had it. CommandNames stay `export` and `unexport`.

- [ ] **Step 4: Add the 4 to `SandboxCommand` subcommands array**

```swift
subcommands: [
    Create.self, Use.self, List.self, Delete.self, Info.self,
    Rename.self, Current.self, Memory.self, Sync.self,
    Export.self, Unexport.self,
    SetEnv.self, UnsetEnv.self,
]
```

- [ ] **Step 5: Delete the 4 files**

```bash
rm Sources/OrreryCore/Commands/MemoryCommand.swift
rm Sources/OrreryCore/Commands/SyncCommand.swift
rm Sources/OrreryCore/Commands/ExportCommand.swift
rm Sources/OrreryCore/Commands/UnexportCommand.swift
```

- [ ] **Step 6: Unregister from root**

Remove `MemoryCommand.self, SyncCommand.self, ExportCommand.self, UnexportCommand.self` from `OrreryCommand.swift`.

- [ ] **Step 7: Update tests**

`grep -rn "MemoryCommand\|SyncCommand\|ExportCommand\|UnexportCommand" Tests/`. Update references.

- [ ] **Step 8: Verify + commit**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
git add Sources/ Tests/
git commit -m "[REFACTOR] Memory/Sync/Export/Unexport → SandboxCommand"
```

---

## Task 5: Promote `Account*Command` to top-level (renames)

Rename 5 file/struct pairs. Drop the `AccountCommand` parent. Change `--name` from `@Option` to `@Argument` (positional) for `use` and `remove`.

**Files:**
- Rename: `AccountAddCommand.swift` → `AddCommand.swift` (struct `AccountAddCommand` → `AddCommand`)
- Rename: `AccountListCommand.swift` → `ListCommand.swift` (struct `AccountListCommand` → `ListCommand`)
- Rename: `AccountShowCommand.swift` → `ShowCommand.swift` (struct `AccountShowCommand` → `ShowCommand`)
- Rename: `AccountUseCommand.swift` → `UseCommand.swift` (struct `AccountUseCommand` → `UseCommand`)
- Rename: `AccountRemoveCommand.swift` → `RemoveCommand.swift` (struct `AccountRemoveCommand` → `RemoveCommand`)
- Delete: `AccountCommand.swift` (the parent)
- Modify: `Sources/orrery/OrreryCommand.swift` (remove `AccountCommand.self`, add 5 top-level entries)
- Modify: `AccountAddPrepareCommand.swift`, `AccountAddFinalizeCommand.swift` (update `AccountAddCommand.resolveTool` → `AddCommand.resolveTool`)
- Modify: `Tests/OrreryTests/AccountCommandsTests.swift` (extensive)

- [ ] **Step 1: Rename `AccountAddCommand.swift` → `AddCommand.swift`**

```bash
git mv Sources/OrreryCore/Commands/AccountAddCommand.swift Sources/OrreryCore/Commands/AddCommand.swift
```

In the new file, rename the struct: `public struct AccountAddCommand` → `public struct AddCommand`. The `commandName: "add"` stays. The `static func resolveTool(...)` stays (rename references throughout the codebase).

- [ ] **Step 2: Rename `AccountShowCommand.swift` → `ShowCommand.swift`**

```bash
git mv Sources/OrreryCore/Commands/AccountShowCommand.swift Sources/OrreryCore/Commands/ShowCommand.swift
```

Rename struct: `AccountShowCommand` → `ShowCommand`. `commandName: "show"` stays.

- [ ] **Step 3: Rename `AccountListCommand.swift` → `ListCommand.swift`**

```bash
git mv Sources/OrreryCore/Commands/AccountListCommand.swift Sources/OrreryCore/Commands/ListCommand.swift
```

Rename struct: `AccountListCommand` → `ListCommand`. `commandName: "list"` stays.

(Note: the OLD top-level `ListCommand.swift` for env was deleted in Task 2 — the slot is now free for this rename.)

- [ ] **Step 4: Rename `AccountUseCommand.swift` → `UseCommand.swift` and convert to positional**

```bash
git mv Sources/OrreryCore/Commands/AccountUseCommand.swift Sources/OrreryCore/Commands/UseCommand.swift
```

In the new file, rename struct: `AccountUseCommand` → `UseCommand`. `commandName: "use"` stays.

CRITICAL change: convert `@Option(name: .long) public var name: String` to `@Argument(help: ArgumentHelp(L10n.Account.nameSelectorHelp)) public var name: String`. The rest of `run()` body is unchanged.

- [ ] **Step 5: Rename `AccountRemoveCommand.swift` → `RemoveCommand.swift` and convert to positional**

```bash
git mv Sources/OrreryCore/Commands/AccountRemoveCommand.swift Sources/OrreryCore/Commands/RemoveCommand.swift
```

Same as Step 4: rename struct, convert `--name` from `@Option` to `@Argument`.

- [ ] **Step 6: Delete `AccountCommand.swift`**

```bash
rm Sources/OrreryCore/Commands/AccountCommand.swift
```

- [ ] **Step 7: Update root command registration**

In `Sources/orrery/OrreryCommand.swift`:
- Remove `AccountCommand.self,` from the subcommands array
- Add `AddCommand.self, ListCommand.self, ShowCommand.self, UseCommand.self, RemoveCommand.self,` (5 new top-level entries)

The full updated subcommands array (final shape after this task — drop env-related, add account top-level, keep everything else):

```swift
subcommands: [
    UpdateCommand.self,
    SetupCommand.self,
    InitCommand.self,
    AddCommand.self,             // new top-level (was AccountAddCommand)
    ListCommand.self,            // new top-level (was AccountListCommand)
    ShowCommand.self,            // new top-level (was AccountShowCommand)
    UseCommand.self,             // new top-level (was AccountUseCommand)
    RemoveCommand.self,          // new top-level (was AccountRemoveCommand)
    SandboxCommand.self,         // already added in Task 1
    ToolsCommand.self,
    WhichCommand.self,
    RunCommand.self,
    ResumeCommand.self,
    DelegateCommand.self,
    SessionsCommand.self,
    MCPSetupCommand.self,
    MCPServerCommand.self,
    SetCurrentCommand.self,
    CheckUpdateCommand.self,
    LinkMemoryCommand.self,
    UninstallCommand.self,
    InstallCommand.self,
    ThirdPartyCommand.self,
    PhantomTriggerCommand.self,            // renamed in Task 9
    PhantomAccountTriggerCommand.self,
    AccountAddPrepareCommand.self,
    AccountAddFinalizeCommand.self,
]
```

Note: `AuthCommand.self`, `OriginCommand.self` are still there at this point; they get removed in Task 8.

- [ ] **Step 8: Update `AccountAddCommand.resolveTool` references**

`grep -rn "AccountAddCommand.resolveTool" Sources/`. The references are in `AccountAddPrepareCommand`, `AccountAddFinalizeCommand`, `AccountUseCommand`, `AccountRemoveCommand`, `PhantomAccountTriggerCommand` (likely). Update each:

```swift
// before:
let tool = try AccountAddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)
// after:
let tool = try AddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)
```

- [ ] **Step 9: Update tests**

`grep -rn "AccountAdd\|AccountList\|AccountShow\|AccountUse\|AccountRemove\|AccountCommand" Tests/`

For each test file, update references:
- `AccountAddCommand` → `AddCommand`
- `AccountListCommand` → `ListCommand`
- `AccountShowCommand` → `ShowCommand`
- `AccountUseCommand` → `UseCommand`
- `AccountRemoveCommand` → `RemoveCommand`

For `AccountUseCommand.parse(["--name", "foo"])` → `UseCommand.parse(["foo"])` (positional now).

For `AccountRemoveCommand.parse(["--name", "foo"])` → `RemoveCommand.parse(["foo"])`.

- [ ] **Step 10: Update L10n key `nameSelectorHelp`**

The `L10n.Account.nameSelectorHelp` key is used by both old `account use --name` (option) and is now used by positional `use <name>`. The English text "Name of the account." reads naturally for either. Update zh-Hant / ja translations to match if they assumed option form.

- [ ] **Step 11: Verify + commit**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
```

Expected: `orrery add --name foo` (or `orrery add` with prompt) works; `orrery list` shows accounts; `orrery use foo` switches to the account named "foo"; `orrery remove foo` deletes. The `orrery account ...` namespace no longer works.

```bash
git add Sources/ Tests/
git commit -m "[REFACTOR] promote account commands to top-level (add/list/show/use/remove); positional --name"
```

---

## Task 6: Delete `AuthCommand` and `OriginCommand`

**Files:**
- Delete: `Sources/OrreryCore/Commands/AuthCommand.swift`
- Delete: `Sources/OrreryCore/Commands/OriginCommand.swift`
- Modify: `Sources/orrery/OrreryCommand.swift`
- Modify: `Sources/OrreryCore/Resources/Localization/{en,zh-Hant,ja}.json` (remove `auth.*`, `origin.*`)
- Verify: `Sources/OrreryCore/Commands/UninstallCommand.swift` covers origin release

- [ ] **Step 1: Verify `UninstallCommand` handles origin release**

Read `Sources/OrreryCore/Commands/UninstallCommand.swift`. Confirm it calls `EnvironmentStore.default.originRelease(tool:)` (or equivalent) for each tool. If it does NOT, the spec assumption "release 走 uninstall" is unmet — add it:

```swift
// inside UninstallCommand.run(), before deleting ~/.orrery/:
for tool in Tool.allCases {
    try? store.originRelease(tool: tool)  // safe to call even if not managed
}
```

- [ ] **Step 2: Delete `AuthCommand.swift`**

```bash
rm Sources/OrreryCore/Commands/AuthCommand.swift
```

- [ ] **Step 3: Delete `OriginCommand.swift`**

```bash
rm Sources/OrreryCore/Commands/OriginCommand.swift
```

- [ ] **Step 4: Unregister from root**

In `Sources/orrery/OrreryCommand.swift`, remove `AuthCommand.self,` and `OriginCommand.self,` from the subcommands array.

- [ ] **Step 5: Delete L10n keys**

Remove all `auth.*` and `origin.*` keys from `en.json`, `zh-Hant.json`, `ja.json`, `l10n-signatures.json`, and the corresponding sections in `keys.md`.

- [ ] **Step 6: Delete tests**

`grep -rn "AuthCommand\|OriginCommand" Tests/`. Delete any test files solely about these commands (e.g. `AuthCommandTests.swift`). If a shared test file references these incidentally, just remove those test cases.

- [ ] **Step 7: Verify + commit**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
```

Expected: build clean. `orrery auth` and `orrery origin` produce "Unknown command" errors (the compat-hint task adds friendlier messages later).

```bash
git add Sources/ Tests/
git commit -m "[REMOVE] AuthCommand and OriginCommand (v3.0)"
```

---

## Task 7: Rename `PhantomTriggerCommand` + sentinel field

**Files:**
- Rename: `Sources/OrreryCore/Commands/PhantomTriggerCommand.swift` → `PhantomSandboxTriggerCommand.swift`
- Modify: struct + command names; sentinel field name
- Modify: `Sources/orrery/OrreryCommand.swift` (registration)
- Modify: `Sources/OrreryCore/Commands/PhantomAccountTriggerCommand.swift` (references to the renamed struct/sentinel function)
- Modify: `Sources/OrreryCore/Shell/ShellFunctionGenerator.swift` (sentinel-reading shell code: `TARGET_ENV` → `TARGET_SANDBOX`)
- Modify: tests

- [ ] **Step 1: Rename file**

```bash
git mv Sources/OrreryCore/Commands/PhantomTriggerCommand.swift Sources/OrreryCore/Commands/PhantomSandboxTriggerCommand.swift
```

- [ ] **Step 2: Rename struct + commandName**

In `PhantomSandboxTriggerCommand.swift`:
- `public struct PhantomTriggerCommand` → `public struct PhantomSandboxTriggerCommand`
- `commandName: "_phantom-trigger"` → `commandName: "_phantom-trigger-sandbox"`

- [ ] **Step 3: Rename sentinel field**

In `writeSentinel(targetEnv:targetAccountTool:targetAccountName:sessionId:store:)`:
- Rename parameter `targetEnv: String?` → `targetSandbox: String?`
- The line that writes `"TARGET_ENV='\(shellEscape(targetEnv))'"` → `"TARGET_SANDBOX='\(shellEscape(targetSandbox))'"`

- [ ] **Step 4: Update `PhantomSandboxTriggerCommand.run()`**

The call to `writeSentinel(targetEnv: target, ...)` becomes `writeSentinel(targetSandbox: target, ...)`.

- [ ] **Step 5: Update `PhantomAccountTriggerCommand`**

Find the call `PhantomTriggerCommand.writeSentinel(...)` and `PhantomTriggerCommand.findClaudeAncestor(...)` etc. Replace with `PhantomSandboxTriggerCommand.*`. The `writeSentinel` call passes `targetEnv: nil` → change to `targetSandbox: nil`.

- [ ] **Step 6: Update root command registration**

In `Sources/orrery/OrreryCommand.swift`, `PhantomTriggerCommand.self` → `PhantomSandboxTriggerCommand.self`.

- [ ] **Step 7: Update slash command markdown (partial — full update in Task 8)**

The `slashCommandMarkdown` static let in `PhantomSandboxTriggerCommand.swift` describes the slash command. Change any reference to `orrery-bin _phantom-trigger` to `orrery-bin _phantom-trigger-sandbox`. Full markdown rewrite (default semantics flip) happens in Task 8.

- [ ] **Step 8: Update shell function for new sentinel field**

In `Sources/OrreryCore/Shell/ShellFunctionGenerator.swift`, find the phantom loop's sentinel-source section. Lines that reference `TARGET_ENV` (e.g. `local TARGET_ENV='' ...; . "$_phantom_sentinel"; ... if [ -n "$TARGET_ENV" ]; then orrery use "$TARGET_ENV"`) become `TARGET_SANDBOX`:

```sh
local TARGET_SANDBOX='' TARGET_ACCOUNT_TOOL='' TARGET_ACCOUNT_NAME='' SESSION_ID=''
. "$_phantom_sentinel"
rm -f "$_phantom_sentinel"
if [ -n "$TARGET_SANDBOX" ]; then
  orrery sandbox use "$TARGET_SANDBOX" || break
fi
...
```

Note: also change `orrery use "$TARGET_ENV"` → `orrery sandbox use "$TARGET_SANDBOX"` (the env switch is now a sandbox command).

- [ ] **Step 9: Update tests**

`grep -rn "PhantomTriggerCommand\|TARGET_ENV\|targetEnv:" Tests/`. Rename references.

- [ ] **Step 10: Verify + commit**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
git add Sources/ Tests/
git commit -m "[RENAME] PhantomTriggerCommand → PhantomSandboxTriggerCommand; sentinel TARGET_ENV → TARGET_SANDBOX"
```

---

## Task 8: Rewrite slash command markdown for v3 defaults

The `/orrery:phantom` slash command's default semantics flip: bare `<name>` now means account, sandbox needs explicit keyword.

**Files:**
- Modify: `Sources/OrreryCore/Commands/PhantomSandboxTriggerCommand.swift` `slashCommandMarkdown` static let
- Modify: `Sources/OrreryCore/Commands/SetupCommand.swift` and `MCPSetupCommand.swift` (these install the slash command file at `~/.claude/commands/orrery:phantom.md`)

- [ ] **Step 1: Read current markdown**

Open `PhantomSandboxTriggerCommand.swift` and locate the `slashCommandMarkdown` static let. Read the current content (multi-line string).

- [ ] **Step 2: Rewrite the markdown**

Replace the slash-command-markdown content with the new v3 defaults:

```swift
public static let slashCommandMarkdown: String = """
---
description: Switch orrery account or sandbox without restarting Claude
argument-hint: [name | <tool> <name> | sandbox <name>]
---

# Phantom: switch orrery account or sandbox in-place

Switch the active orrery account (or sandbox) without losing the conversation. Claude exits and the orrery supervisor relaunches it with `--resume`, so the conversation continues where it left off.

**Prerequisite**: Claude must have been launched via `orrery run claude` (which is phantom-supervised by default). If Claude was launched directly or with `orrery run --non-phantom claude`, the trigger will error with a clear message.

## What to do

Inspect `$ARGUMENTS` and pick the matching branch:

- **`$ARGUMENTS` is `sandbox <name>`** (explicit sandbox switch): run `orrery-bin _phantom-trigger-sandbox <name>`.

- **`$ARGUMENTS` starts with `claude`, `codex`, or `gemini`** followed by a name: switch that tool's account. Run `orrery-bin _phantom-trigger-account --<tool> --name <name>`.

- **`$ARGUMENTS` is just `<name>`** (a single token, not `sandbox`/`claude`/`codex`/`gemini`): default to switching the claude account. Run `orrery-bin _phantom-trigger-account --claude --name <name>`.

- **`$ARGUMENTS` is empty**: first run `orrery-bin _phantom-trigger-sandbox` (no args) to get the list of available sandboxes, and `orrery-bin list` to get the list of accounts. Present both lists to the user, ask which they want to switch to, and re-invoke this slash command with their choice.

Do not narrate the relaunch — Claude will simply exit and reappear with the new account or sandbox active. The user's next message lands in the new context.
"""
```

- [ ] **Step 3: Verify `SetupCommand` and `MCPSetupCommand` install the markdown from this static let (not a hardcoded copy)**

Search `grep -rn "slashCommandMarkdown" Sources/`. Confirm both `SetupCommand` and `MCPSetupCommand` reference `PhantomSandboxTriggerCommand.slashCommandMarkdown` (renamed from `PhantomTriggerCommand.slashCommandMarkdown` in Task 7). If anywhere has hardcoded markdown, update that too.

- [ ] **Step 4: Update tests**

`grep -rn "phantom.*<env\|TARGET_ENV\|_phantom-trigger\"" Tests/`. Verify tests that assert against markdown content are updated.

- [ ] **Step 5: Verify + commit**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
git add Sources/ Tests/
git commit -m "[CHANGE] /orrery:phantom default semantics: bare <name> is account; sandbox keyword for sandbox"
```

---

## Task 9: Rewrite `ShellFunctionGenerator`

Full rewrite of the shell function. Old cases: `use`, `deactivate`, `create`, `account`, `run`. New cases: `sandbox`, `add`, `run` (kept). Other commands fall through.

**Files:**
- Modify: `Sources/OrreryCore/Shell/ShellFunctionGenerator.swift`
- Modify: `Tests/OrreryTests/ShellFunctionGeneratorTests.swift`

- [ ] **Step 1: Read the full current `generate()` function**

Open `ShellFunctionGenerator.swift`. Note the structure: it's one big Swift heredoc producing the entire bash/zsh function. The case statements span lines ~30-220.

- [ ] **Step 2: Plan the new structure**

The full new case block should look like:

```sh
case "$cmd" in
  sandbox)
    case "${2:-}" in
      use)
        # Move the OLD `use` case logic here.
        # Shift off "sandbox" so $2 ("use") is now $1
        shift
        if [ -z "${2:-}" ]; then echo "Usage: orrery sandbox use <name>" >&2; return 1; fi
        if [ -n "${ORRERY_ACTIVE_ENV:-}" ] && [ "$ORRERY_ACTIVE_ENV" != "origin" ]; then
          eval "$(command orrery-bin sandbox unexport "$ORRERY_ACTIVE_ENV" 2>/dev/null || true)"
        fi
        if [ "$2" = "origin" ]; then
          unset CLAUDE_CONFIG_DIR CODEX_HOME CODEX_CONFIG_DIR GEMINI_CONFIG_DIR ORRERY_GEMINI_HOME
          export ORRERY_ACTIVE_ENV="origin"
          command orrery-bin _set-current origin 2>/dev/null || true
        else
          local exports
          exports=$(command orrery-bin sandbox export "$2") || { echo "orrery: sandbox '$2' not found" >&2; return 1; }
          eval "$exports"
          export ORRERY_ACTIVE_ENV="$2"
          command orrery-bin _set-current "$2" 2>/dev/null || true
          ( ( command orrery-bin quota refresh -e "$2" >/dev/null 2>&1 ) & ) >/dev/null 2>&1
        fi
        printf "\(L10n.Use.switched)\\n" "$2"
        ;;
      create)
        # Move the OLD `create` post-prompt logic here.
        command orrery-bin "$@"
        if [ $? -eq 0 ]; then
          local _name="" _skip=0
          for _arg in "${@:3}"; do
            if [ $_skip -eq 1 ]; then _skip=0; continue; fi
            case "$_arg" in
              --description|--clone|--tool) _skip=1 ;;
              --*) ;;
              *) _name="$_arg"; break ;;
            esac
          done
          if [ -n "$_name" ]; then
            printf "切換到 sandbox '%s'？[Y/n] " "$_name"
            read -r _ans </dev/tty
            case "${_ans:-Y}" in
              [Yy]*|"") orrery sandbox use "$_name" ;;
            esac
          fi
        fi
        ;;
      *)
        command orrery-bin "$@"   # other sandbox subcommands (list/delete/info/rename/current/memory/sync/set-env/unset-env)
        ;;
    esac
    ;;
  add)
    # The existing claude-TTY interception from the OLD `account)` case.
    # Copy the body unchanged, just renaming references.
    for _a in "${@:2}"; do
      case "$_a" in
        -h|--help) command orrery-bin "$@"; return $?; ;;
      esac
    done
    local _is_claude=1
    for _a in "${@:2}"; do
      case "$_a" in
        --codex|--gemini) _is_claude=0; break ;;
      esac
    done
    if [ $_is_claude -eq 1 ]; then
      local _staging
      _staging=$(command orrery-bin _account-add-prepare "${@:2}") || return $?
      [ -z "$_staging" ] && { echo "orrery: prepare returned empty staging dir" >&2; return 1; }
      printf "\(L10n.Account.loginReadyHint)\n"
      CLAUDE_CONFIG_DIR="$_staging" command claude
      command orrery-bin _account-add-finalize --staging "$_staging"
      return $?
    fi
    command orrery-bin "$@"
    ;;
  run)
    # Phantom claude loop — copy the OLD `run)` case body verbatim.
    # Inside the loop, the sentinel read uses TARGET_SANDBOX (already renamed in Task 7).
    # And the env-switch line: `orrery use "$TARGET_ENV"` → `orrery sandbox use "$TARGET_SANDBOX"` (already updated in Task 7).
    ...
    ;;
  *)
    command orrery-bin "$@"
    ;;
esac
```

- [ ] **Step 3: Rewrite `generate()` with the new case block**

Replace the entire `case "$cmd" in ... esac` block with the structure above. Preserve the heredoc indentation. Reuse the localized strings via Swift interpolation as before (`\(L10n.Use.switched)` etc).

NOTE: the old `use)` case has been moved into `sandbox)/use)`. The OLD top-level `use)` case is REMOVED — the new top-level `orrery use <X>` (account use) falls through to `command orrery-bin "$@"` (the default `*)`), because account use needs no shell magic.

The OLD `deactivate)` case is REMOVED entirely (users use `orrery sandbox use origin`).

The OLD `account)` case is REMOVED — the claude-TTY case logic moved into `add)`.

- [ ] **Step 4: Update L10n where verb shifted**

`L10n.Use.switched` was used by the OLD env-use shell case. It still applies (the new `sandbox use` triggers the same shell). Confirm no rename needed.

If any L10n key explicitly mentioned "env" in user-facing text, update to "sandbox". Scan `en.json` for occurrences of "env" in values.

- [ ] **Step 5: Update tests**

`Tests/OrreryTests/ShellFunctionGeneratorTests.swift` — every test that asserts the generated script's contents needs updating:
- Tests asserting `case "use)"` now expect `case "sandbox)"` (and the inner `use)`).
- Tests asserting `case "deactivate)"` → those tests get deleted.
- Tests asserting `case "create)"` → moved inside `sandbox)`.
- Tests asserting `case "account)"` → renamed to `add)`.

The existing tests already cover phantom loop + account-add TTY path. Adapt assertions to new structure.

- [ ] **Step 6: Verify + commit**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
```

Test by hand in a temp shell:
```bash
swift run orrery-bin setup    # regenerate activate.sh
source ~/.orrery/activate.sh
orrery sandbox use myenv      # should activate
orrery use myaccount          # should fall through to orrery-bin (account use, no shell magic)
```

```bash
git add Sources/ Tests/
git commit -m "[REWRITE] ShellFunctionGenerator: sandbox/add/run case structure for v3"
```

---

## Task 10: Compatibility hints (custom error messages for removed/renamed commands)

When users type old commands (`orrery use foo` expecting env, `orrery auth`, etc.), give friendly hints.

**Files:**
- Modify: `Sources/orrery/OrreryCommand.swift` (or a new helper) — install a custom error path that intercepts "Unknown subcommand" errors and adds hints

ArgumentParser doesn't natively support "did you mean" out of the box. We'll add a minimal pre-parse hook that catches a handful of well-known old verbs.

- [ ] **Step 1: Add a pre-parse interception in `main.swift`**

Read `Sources/orrery/main.swift`. After the migration calls but before `OrreryCommand.main()`, add:

```swift
// v3 compat hints — intercept obvious old commands and print friendly hints.
if CommandLine.arguments.count >= 2 {
    let verb = CommandLine.arguments[1]
    switch verb {
    case "create", "delete", "info", "rename", "memory", "sync":
        FileHandle.standardError.write(Data(
            "'orrery \(verb)' was moved to 'orrery sandbox \(verb)' in v3.0.\n".utf8))
    case "auth":
        FileHandle.standardError.write(Data(
            "'orrery auth' was removed in v3.0. Use 'orrery show' for pinned accounts or 'orrery list' for the full pool.\n".utf8))
    case "origin":
        FileHandle.standardError.write(Data(
            "'orrery origin' was removed in v3.0. Takeover runs automatically; release happens via 'orrery uninstall'.\n".utf8))
    case "deactivate":
        FileHandle.standardError.write(Data(
            "'orrery deactivate' was removed in v3.0. Use 'orrery sandbox use origin' instead.\n".utf8))
    case "current":
        FileHandle.standardError.write(Data(
            "'orrery current' was moved to 'orrery sandbox current' in v3.0.\n".utf8))
    default:
        break
    }
}
```

This prints the hint and then **continues** to normal parsing (which will produce the ArgumentParser "Unknown subcommand" error). User sees BOTH the helpful hint AND the standard error. Acceptable.

- [ ] **Step 2: `use` hint when sandbox has that name but account doesn't**

The `use` case is trickier — `orrery use foo` IS valid (account use). The hint should only fire when the user typed `orrery use foo` AND no account "foo" exists AND a sandbox named "foo" does. That's logic inside `UseCommand.run()` itself, not main.swift. Add to `UseCommand.run()` (the account use one):

```swift
public func run() throws {
    let tool = try AddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)
    let acctStore = AccountStore.default
    guard let acct = try acctStore.findByDisplayName(name, tool: tool) else {
        // Hint if a sandbox with that name exists
        let envStore = EnvironmentStore.default
        if (try? envStore.load(named: name)) != nil {
            FileHandle.standardError.write(Data(
                "No account '\(name)'. Did you mean: orrery sandbox use \(name)?\n".utf8))
        }
        throw ValidationError(L10n.Account.useNotFound(name, tool.rawValue))
    }
    // ... rest of existing run() ...
}
```

- [ ] **Step 3: Test the hints by hand**

```bash
swift build
.build/debug/orrery-bin create foo 2>&1 | head -2
# expected: hint about sandbox create + Unknown subcommand error
```

- [ ] **Step 4: Add a test**

In an existing test file (or new `Tests/OrreryTests/CompatHintTests.swift`), assert that running with `["use", "nonexistent-name"]` produces a stderr line mentioning "Did you mean: orrery sandbox use".

This will require running the binary as a subprocess or stubbing `FileHandle.standardError`. Use the simpler approach: capture stderr via a Pipe-based subprocess.

- [ ] **Step 5: Commit**

```bash
git add Sources/ Tests/
git commit -m "[ADD] v3 compat hints for old command names"
```

---

## Task 11: L10n audit

After all the moves, several L10n keys have stale paths or stale user-facing text. Audit and clean up.

**Files:**
- Modify: `Sources/OrreryCore/Resources/Localization/{en,zh-Hant,ja}.json`
- Modify: `Sources/OrreryCore/Resources/Localization/keys.md`
- Modify: `Sources/OrreryCore/Resources/Localization/l10n-signatures.json`

- [ ] **Step 1: Inventory the L10n key prefixes**

```bash
cd Sources/OrreryCore/Resources/Localization
jq 'keys | map(split(".")[0]) | unique' en.json
```

Expected groups: `account`, `create`, `currentEnv`, `delete`, `info`, `list`, `phantom`, `rename`, `run`, `sandbox`, `setup`, `toolSetup`, `use`, etc.

- [ ] **Step 2: Identify keys that need renaming**

After the moves:
- `create.*` (env create) — keys stay; they're now used by `SandboxCommand.Create`. No rename needed; `L10n.Create.*` works.
- `use.*` (env use) — same; used by `SandboxCommand.Use`. No rename.
- `list.*` (env list) — same; used by `SandboxCommand.List`.
- `delete.*`, `info.*`, `rename.*`, `currentEnv.*` — same logic.
- `account.use*`, `account.list*`, `account.add*`, `account.show*`, `account.remove*` — these keys move with the commands but the keys themselves don't need renaming. The codegen still produces `L10n.Account.useNotFound`, just used from a top-level command now. **No rename needed.**

Conclusion: most L10n keys can stay. The only ones that need rework are:
- `envVar.*` → `sandbox.setEnv.*` / `sandbox.unsetEnv.*` (already done in Task 1)
- `auth.*` → deleted (done in Task 6)
- `origin.*` → deleted (done in Task 6)

So this audit task is mostly a verification.

- [ ] **Step 3: Scan user-facing text for "env" mentions that should say "sandbox"**

```bash
jq -r 'to_entries[] | .value' en.json | grep -i "env\b"
```

Review each match. Update those that refer to the orrery-env concept (now sandbox) to say "sandbox". Leave references to `ORRERY_ACTIVE_ENV` (env var name) alone.

Common candidates:
- `create.abstract: "Create a new orrery environment"` → `"Create a new orrery sandbox"`
- `list.empty: "No environments found"` → `"No sandboxes found"`
- `info.notFound: "Environment '{name}' not found"` → `"Sandbox '{name}' not found"`
- etc.

Apply to all three locales.

- [ ] **Step 4: Verify all 3 locales stay in key-set parity**

```bash
diff <(jq -r 'keys[]' en.json | sort) <(jq -r 'keys[]' zh-Hant.json | sort)
diff <(jq -r 'keys[]' en.json | sort) <(jq -r 'keys[]' ja.json | sort)
```

Expected: both diffs empty.

- [ ] **Step 5: Build + test**

```bash
swift build 2>&1 | tail -3
swift test --filter Localization 2>&1 | tail -3
```

- [ ] **Step 6: Commit**

```bash
git add Sources/OrreryCore/Resources/Localization/
git commit -m "[L10N] audit: env→sandbox in user-facing text; remove auth/origin keys"
```

---

## Task 12: Version bump + CHANGELOG

Final task. Bump to 3.0.0 across all 5 locations and write the CHANGELOG.

**Files:**
- Modify: `Sources/OrreryCore/Version.swift`
- Modify: `Sources/OrreryCore/MCP/MCPServer.swift` (verify `currentVersion()` returns `OrreryVersion.current`)
- Modify: `docs/index.html`, `docs/zh_TW.html` (badge)
- Modify: `CHANGELOG.md`
- Modify: `Sources/orrery/OrreryCommand.swift` (if it has its own version field)

- [ ] **Step 1: Bump `OrreryVersion.current`**

In `Sources/OrreryCore/Version.swift`:

```swift
public enum OrreryVersion {
    public static let current = "3.0.0"
}
```

- [ ] **Step 2: Verify `MCPServer.currentVersion()`**

Confirm it reads `OrreryVersion.current` (not hardcoded). If hardcoded, fix to use the constant.

- [ ] **Step 3: Bump badges**

In `docs/index.html`: find the version badge URL (e.g. `https://img.shields.io/badge/version-2.8.0-...`) and change to `3.0.0`. Same in `docs/zh_TW.html`.

- [ ] **Step 4: Write CHANGELOG entry**

Prepend to `CHANGELOG.md` under the existing `## v2.8.0` (or whatever the latest entry is):

```markdown
## [v3.0.0] - 2026-05-21

⚠️ **Breaking change release.** Top-level commands restructured.

### Breaking changes

- `account` subcommands are now top-level. Use `orrery add` / `list` / `show` / `use <name>` / `remove <name>` instead of `orrery account add` / `list` / `show` / `use --name X` / `remove --name X`.
- `env` commands moved into `orrery sandbox` namespace. Use `orrery sandbox create / use / list / delete / info / rename / current / memory / sync / set-env / unset-env` instead of the old top-level forms.
- `orrery auth` removed. Use `orrery show` (pinned accounts) or `orrery list` (full pool).
- `orrery origin` removed. Takeover runs automatically on startup; release happens via `orrery uninstall`.
- `orrery deactivate` removed. Use `orrery sandbox use origin`.
- `orrery env set KEY VALUE` and `orrery env unset KEY` are now `orrery sandbox set-env KEY VALUE` and `orrery sandbox unset-env KEY`. The `-e <env>` option is now `-s <sandbox>`.

### Migration

- The `~/.orrery/` data layout is unchanged. No data migration needed.
- The `ORRERY_ACTIVE_ENV` environment variable name is preserved (script-compatibility).
- Update any user scripts that invoke `orrery use`, `orrery list`, `orrery create`, etc. See the mapping above.

### Added

- Friendly error messages for old command names: `orrery create foo` now prints "moved to orrery sandbox create" before failing.
- `orrery use <name>` (account use) suggests `orrery sandbox use <name>` if the name matches a sandbox.

### Internal

- `PhantomTriggerCommand` renamed to `PhantomSandboxTriggerCommand`; `_phantom-trigger` → `_phantom-trigger-sandbox`.
- Sentinel field `TARGET_ENV` → `TARGET_SANDBOX`.
- `/orrery:phantom` slash command default semantics flipped: bare `<name>` switches account (was: sandbox).
```

- [ ] **Step 5: Run full test suite**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
```

Expected: clean build, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ docs/ CHANGELOG.md
git commit -m "[REL] v3.0.0: account top-level, sandbox namespace"
```

---

## Self-Review Checklist

After the full plan executes, verify:

- [ ] **Spec coverage**: Each spec section has a corresponding task.
  - §3 mapping → Tasks 1-7 (sandbox build), 5 (account promotion), 6 (deletes)
  - §4 shell function → Task 9
  - §5 slash command → Task 8
  - §6 sentinel rename → Task 7
  - §7 compat hints → Task 10
  - §8 impl scope → covered by Tasks 1-12
  - §9 out of scope → not touched (run/delegate/sessions/etc. unchanged)
- [ ] **No placeholders**: Each step has concrete code or commands.
- [ ] **Type consistency**: Renamed types are used consistently across tasks (e.g. `AddCommand` not `AccountAddCommand` after Task 5).
- [ ] **Test coverage**: Every refactor task includes "update tests" step.
- [ ] **Build/test verify**: Every task ends with `swift build` + `swift test`.

---

## Execution Notes

- This is a refactor, not new behavior. Most "tests" are existing tests that need their construction calls updated. Few new unit tests are needed.
- The renames may surface compile errors in unexpected files (e.g. `LinkMemoryCommand` may reference something now in `SandboxCommand.Memory`). Each task includes a `grep -rn` step before-renaming to find references.
- After the full implementation, a manual end-to-end test:
  1. `swift build -c release && sudo cp .build/release/orrery-bin /usr/local/bin/orrery-bin && sudo codesign --force --sign - /usr/local/bin/orrery-bin`
  2. `orrery-bin setup`
  3. `source ~/.orrery/activate.sh`
  4. Try `orrery list`, `orrery show`, `orrery sandbox list`, `orrery sandbox use origin`, `orrery use <account>`, `orrery add` (interactive), `orrery sandbox create test`, etc.
- Open PR titled "v3.0.0: account-first command surface, sandbox namespace".
