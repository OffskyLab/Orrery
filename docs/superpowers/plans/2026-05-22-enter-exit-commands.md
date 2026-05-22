# `orrery enter` / `orrery exit` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `orrery sandbox use <name>` with two top-level verbs — `orrery enter <sandbox>` (opt into a sandbox) and `orrery exit` (return to origin) — so origin is treated as a *state* (no sandbox active), not a sandbox name.

**Architecture:** Two new top-level `ParsableCommand`s on `OrreryCommand` whose `run()` only throws `needsShellIntegration` (the env-var dance lives in the shell function, like `SandboxCommand.Use` does today). `ShellFunctionGenerator` grows two top-level dispatch cases (`enter)` / `exit)`) and the nested `sandbox)/use)` arm is removed. The phantom supervisor loop in the generated shell script translates `TARGET_SANDBOX=origin` → `orrery exit`, other values → `orrery enter $TARGET_SANDBOX`. Internal types (`EnvironmentStore`, `ReservedEnvironment`, env var `ORRERY_ACTIVE_ENV`) are unchanged; only the verb surface moves.

**Tech Stack:** Swift 6.0+ · Swift ArgumentParser · Swift Testing · Foundation · in-repo `L10nCodegen` plugin (generates `L10n.Enter.*` / `L10n.Exit.*` types from `*.json`).

**Worktree:** `~/.config/superpowers/worktrees/orrery/v3-command-restructure` (branch `feat/v3-command-restructure`).

---

## File Structure

**Create:**
- `Sources/OrreryCore/Commands/EnterCommand.swift` — top-level `EnterCommand` (throws `enter.needsShellIntegration`).
- `Sources/OrreryCore/Commands/ExitCommand.swift` — top-level `ExitCommand` (throws `enter.needsShellIntegration`; shared key).

**Modify:**
- `Sources/OrreryCore/Resources/Localization/en.json` — rename `use.*` → `enter.*`/`exit.*`, add 3 new keys, update hint strings.
- `Sources/OrreryCore/Resources/Localization/zh-Hant.json` — same shape, 繁體中文 content.
- `Sources/OrreryCore/Resources/Localization/ja.json` — same shape, content stays English (matches existing partial-translation reality).
- `Sources/OrreryCore/Resources/Localization/keys.md` — doc table reflects new key names / commands.
- `Sources/orrery/OrreryCommand.swift` — register `EnterCommand.self`, `ExitCommand.self`; remove nothing.
- `Sources/OrreryCore/Commands/SandboxCommand.swift` — delete `Use` struct (lines 85-102), remove `Use.self` from subcommands list (line 15).
- `Sources/OrreryCore/Shell/ShellFunctionGenerator.swift` — add top-level `enter)` + `exit)` cases; drop `sandbox)/use)` arm; update `_orrery_init`, `sandbox)/create)` auto-switch, `run)` target switch, and phantom loop to use the new verbs.
- `Sources/OrreryCore/Commands/ThirdPartyCommand.swift` — `ValidationError` text updated from `orrery sandbox use <env>` → `orrery enter <env>`.
- `Sources/OrreryCore/Commands/InstallCommand.swift` — same.
- `Tests/OrreryTests/ShellFunctionGeneratorTests.swift` — rename `handlesSandboxUse` → `handlesEnter`; add `handlesExit`; update `autoActivatesCurrent`; add phantom-translation assertion; add reject-`enter-origin` assertion; add sandbox-use-gone negative assertion.

**Out of process (not git-tracked):**
- `~/.orrery-v3/bin/orrery-bin` — refresh from release build.
- `~/.orrery-v3/activate.sh` — regenerate.

---

## Task 1: L10n keys + reference updates

This task keeps the build green throughout by updating every reference to `L10n.Use.*` in the same commit as the JSON rename.

**Files:**
- Modify: `Sources/OrreryCore/Resources/Localization/en.json`
- Modify: `Sources/OrreryCore/Resources/Localization/zh-Hant.json`
- Modify: `Sources/OrreryCore/Resources/Localization/ja.json`
- Modify: `Sources/OrreryCore/Resources/Localization/keys.md`
- Modify: `Sources/OrreryCore/Shell/ShellFunctionGenerator.swift:61` (single reference `\(L10n.Use.switched)` → `\(L10n.Enter.switched)`)
- Modify: `Sources/OrreryCore/Commands/SandboxCommand.swift:90,93,99` (Use struct's three `L10n.Use.*` references → `L10n.Enter.*`)
- Modify: `Sources/OrreryCore/Commands/ThirdPartyCommand.swift:77` (ValidationError text)
- Modify: `Sources/OrreryCore/Commands/InstallCommand.swift:49` (ValidationError text)

- [ ] **Step 1: Rename `use.*` keys in `en.json` (lines 313-318) and update content**

Find this block:
```json
  "use.abstract": "Activate an environment in the current shell",
  "use.nameHelp": "Environment name",
  "use.needsShellIntegration": "error: 'orrery sandbox use' requires shell integration.\nRun 'orrery setup' to install it, then restart your terminal.\n",
  "use.switched": "Switched to environment: %s",
  "use.switchedToOrigin": "Switched back to: origin",
```
Replace with:
```json
  "enter.abstract": "Enter a sandbox in the current shell",
  "enter.nameHelp": "Sandbox name",
  "enter.needsShellIntegration": "error: 'orrery enter' or 'orrery exit' requires shell integration.\nRun 'orrery setup' to install it, then restart your terminal.\n",
  "enter.switched": "Entered sandbox: %s",
  "enter.cannotEnterOrigin": "'origin' is not a sandbox — use 'orrery exit' to leave the current sandbox.",
  "exit.abstract": "Leave the current sandbox and return to origin",
  "exit.switched": "Left sandbox, back to origin.",
  "exit.alreadyAtOrigin": "Already at origin (no sandbox active).",
```

(Drop the unused `use.switchedToOrigin` key; the message moves into `exit.switched`. If the codegen complains about the key vanishing, that's expected — the codegen rebuilds the type from the new JSON keys.)

- [ ] **Step 2: Same rename in `zh-Hant.json` (lines 313-318) with 繁體中文 content**

```json
  "enter.abstract": "進入 sandbox（在目前 shell 中啟用）",
  "enter.nameHelp": "Sandbox 名稱",
  "enter.needsShellIntegration": "error: 'orrery enter' 或 'orrery exit' 需要 shell 整合。\n請執行 'orrery setup' 安裝後，重新啟動終端機。\n",
  "enter.switched": "已進入 sandbox：%s",
  "enter.cannotEnterOrigin": "'origin' 不是 sandbox — 請用 'orrery exit' 離開目前的 sandbox。",
  "exit.abstract": "離開目前的 sandbox 並回到 origin",
  "exit.switched": "已離開 sandbox，回到 origin。",
  "exit.alreadyAtOrigin": "目前已在 origin（沒有 sandbox 啟用）。",
```

- [ ] **Step 3: Same rename in `ja.json` (lines 313-318), content stays English**

Use the same English strings from Step 1 (the existing file keeps several keys in English; we don't introduce a translation regression for v3's brand-new keys).

- [ ] **Step 4: Update hint strings that reference `'orrery sandbox use'` → `'orrery enter'`**

In each of `en.json`, `zh-Hant.json`, `ja.json`, do the substring replacement `orrery sandbox use` → `orrery enter` for these keys (the wider sentence/word stays):
- `create.firstEnvCreated`
- `info.noActive`
- `memory.noActiveEnv`
- `tools.noActive`
- `which.noActive`
- `sandbox.setEnvNoActive`

(These were just updated to say `orrery sandbox use` in commit `c242327`; we're moving them one more step.)

- [ ] **Step 5: Update Swift ValidationError text in two files**

`Sources/OrreryCore/Commands/ThirdPartyCommand.swift:77`:
```swift
throw ValidationError("No active environment. Use --env <env> or switch with `orrery enter <env>`.")
```

`Sources/OrreryCore/Commands/InstallCommand.swift:49`:
```swift
throw ValidationError("No active environment. Use --env <env> or switch with `orrery enter <env>`.")
```

- [ ] **Step 6: Update `ShellFunctionGenerator.swift:61` reference**

Find:
```swift
                  printf "\(L10n.Use.switched)\\n" "$2"
```
Replace with:
```swift
                  printf "\(L10n.Enter.switched)\\n" "$2"
```

- [ ] **Step 7: Update `SandboxCommand.swift` Use struct's three references**

Find (lines 87-102):
```swift
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

Replace with (only the `L10n.Use.*` → `L10n.Enter.*` swap; the struct stays — it's deleted in Task 3):
```swift
    public struct Use: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "use",
            abstract: L10n.Enter.abstract
        )

        @Argument(help: ArgumentHelp(L10n.Enter.nameHelp))
        public var name: String

        public init() {}

        public func run() throws {
            stderrWrite(L10n.Enter.needsShellIntegration)
            throw ExitCode.failure
        }
    }
```

- [ ] **Step 8: Update `keys.md` doc table**

In `Sources/OrreryCore/Resources/Localization/keys.md`, locate the `## use — \`orrery use\`` section (around line 339) and replace it with:

```markdown
## enter / exit — `orrery enter` and `orrery exit`

| Key | Context |
| --- | --- |
| `enter.abstract` | Command help. |
| `enter.nameHelp` | Positional `name` help. |
| `enter.needsShellIntegration` | Error when shell integration isn't installed. Shared by `exit` (both verbs need the shell wrapper to export/unset env vars). References `orrery setup` — keep literal. Has `\n`. |
| `enter.switched` | Shown when entering a sandbox. `%s` = sandbox name. |
| `enter.cannotEnterOrigin` | Rejection when the user passes `origin` to `enter`. References `orrery exit` — keep literal. |
| `exit.abstract` | Command help. |
| `exit.switched` | Shown when leaving a sandbox back to origin. |
| `exit.alreadyAtOrigin` | Friendly no-op message when `exit` runs while already at origin. |
```

Also: in any row that previously said `orrery sandbox use` (e.g. the descriptions for the hint strings updated in Step 4), replace with `orrery enter`.

- [ ] **Step 9: Build to verify the codegen + Swift compiles**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 10: Run tests to make sure nothing else asserted on the old keys**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && swift test 2>&1 | tail -5
```
Expected: `Test run with 238 tests in 61 suites passed`.

If anything fails citing `L10n.Use.*`, grep for the remaining reference and update it.

- [ ] **Step 11: Commit**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && git add \
  Sources/OrreryCore/Resources/Localization/en.json \
  Sources/OrreryCore/Resources/Localization/zh-Hant.json \
  Sources/OrreryCore/Resources/Localization/ja.json \
  Sources/OrreryCore/Resources/Localization/keys.md \
  Sources/OrreryCore/Shell/ShellFunctionGenerator.swift \
  Sources/OrreryCore/Commands/SandboxCommand.swift \
  Sources/OrreryCore/Commands/ThirdPartyCommand.swift \
  Sources/OrreryCore/Commands/InstallCommand.swift && \
git commit -m "$(cat <<'EOF'
[L10n] introduce enter.*/exit.* keys; rename use.*; align references

Foundation commit for the orrery enter / orrery exit verbs. Renames
the use.* L10n keys to enter.*/exit.* (use.abstract → enter.abstract,
use.switched → enter.switched, use.switchedToOrigin → exit.switched,
use.needsShellIntegration → enter.needsShellIntegration shared by both
verbs) and adds three new keys: exit.abstract, exit.alreadyAtOrigin,
enter.cannotEnterOrigin.

Hint strings that just landed on "orrery sandbox use <name>" in c242327
move one more step to "orrery enter <name>" — same translator scope
across en/zh-Hant/ja.

The Swift Use struct in SandboxCommand and the printf line in
ShellFunctionGenerator update to the new L10n type names so the build
stays green; behaviour is unchanged in this commit (Use struct is
removed in the next task, shell-function dispatch in the one after).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `EnterCommand` and `ExitCommand`

**Files:**
- Create: `Sources/OrreryCore/Commands/EnterCommand.swift`
- Create: `Sources/OrreryCore/Commands/ExitCommand.swift`
- Modify: `Sources/orrery/OrreryCommand.swift` (register both)

- [ ] **Step 1: Create `EnterCommand.swift`**

```swift
import ArgumentParser
import Foundation

/// Top-level `orrery enter <sandbox>`. The binary always throws
/// `enter.needsShellIntegration` — the actual env-var dance lives in
/// the shell function (see ShellFunctionGenerator).
public struct EnterCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "enter",
        abstract: L10n.Enter.abstract
    )

    @Argument(help: ArgumentHelp(L10n.Enter.nameHelp))
    public var name: String

    public init() {}

    public func run() throws {
        stderrWrite(L10n.Enter.needsShellIntegration)
        throw ExitCode.failure
    }
}
```

- [ ] **Step 2: Create `ExitCommand.swift`**

```swift
import ArgumentParser
import Foundation

/// Top-level `orrery exit`. Same shape as EnterCommand: the binary
/// throws needsShellIntegration; the shell function does the work.
public struct ExitCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "exit",
        abstract: L10n.Exit.abstract
    )

    public init() {}

    public func run() throws {
        // enter.needsShellIntegration is shared with enter — both verbs
        // need the shell wrapper to mutate env vars.
        stderrWrite(L10n.Enter.needsShellIntegration)
        throw ExitCode.failure
    }
}
```

- [ ] **Step 3: Register both on `OrreryCommand.subcommands`**

In `Sources/orrery/OrreryCommand.swift`, find the `subcommands:` array (around line 15). Insert `EnterCommand.self` and `ExitCommand.self` near `UseCommand.self`. Final block:

```swift
        subcommands: [
            UpdateCommand.self,
            SetupCommand.self,
            InitCommand.self,
            AddCommand.self,
            ListCommand.self,
            ShowCommand.self,
            UseCommand.self,
            EnterCommand.self,
            ExitCommand.self,
            RemoveCommand.self,
            SandboxCommand.self,
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
            PhantomSandboxTriggerCommand.self,
            PhantomAccountTriggerCommand.self,
            AccountAddPrepareCommand.self,
            AccountAddFinalizeCommand.self,
        ]
```

- [ ] **Step 4: Build**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 5: Verify the commands appear in `--help`**

```bash
~/.config/superpowers/worktrees/orrery/v3-command-restructure/.build/debug/orrery-bin --help 2>&1 | grep -E "enter|exit"
```
Expected (debug binary may print the ArgumentParser async-availability warning — that's expected for debug builds, ignore it; the help text should still mention `enter` and `exit`). If the debug binary still won't print, do a release build instead:
```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && swift build -c release 2>&1 | tail -3 && \
~/.config/superpowers/worktrees/orrery/v3-command-restructure/.build/release/orrery-bin --help 2>&1 | grep -E "enter|exit"
```
Expected: two lines, one each for `enter` and `exit`.

- [ ] **Step 6: Commit**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && git add \
  Sources/OrreryCore/Commands/EnterCommand.swift \
  Sources/OrreryCore/Commands/ExitCommand.swift \
  Sources/orrery/OrreryCommand.swift && \
git commit -m "$(cat <<'EOF'
[ADD] EnterCommand / ExitCommand top-level verbs

Two new top-level ParsableCommands that both throw needsShellIntegration —
their actual env-var work lives in the shell function. Same shape as the
existing SandboxCommand.Use stub (which is removed in the next task).

EnterCommand is the opt-in side (`orrery enter <sandbox>`); ExitCommand
is the opt-out side (`orrery exit`) that returns the shell to origin.
Both share the enter.needsShellIntegration L10n key — the error message
mentions both verbs so the user knows what was attempted.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Delete `SandboxCommand.Use`

**Files:**
- Modify: `Sources/OrreryCore/Commands/SandboxCommand.swift` (delete struct + remove from subcommands list)

- [ ] **Step 1: Remove `Use.self` from the subcommands list**

Find (line 13-18):
```swift
        subcommands: [
            SetEnv.self, UnsetEnv.self,
            Use.self, List.self, Delete.self, Info.self, Rename.self, Current.self,
            Create.self,
            Memory.self, Sync.self, Export.self, Unexport.self,
        ]
```

Replace with:
```swift
        subcommands: [
            SetEnv.self, UnsetEnv.self,
            List.self, Delete.self, Info.self, Rename.self, Current.self,
            Create.self,
            Memory.self, Sync.self, Export.self, Unexport.self,
        ]
```

- [ ] **Step 2: Delete the entire `Use` struct**

Find (lines 85-102, the whole `// MARK: - Use` block including the struct and the blank line before `// MARK: - List`):
```swift
    // MARK: - Use

    public struct Use: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "use",
            abstract: L10n.Enter.abstract
        )

        @Argument(help: ArgumentHelp(L10n.Enter.nameHelp))
        public var name: String

        public init() {}

        public func run() throws {
            stderrWrite(L10n.Enter.needsShellIntegration)
            throw ExitCode.failure
        }
    }

```

Delete that whole block (the `// MARK: - List` heading on the next line stays).

- [ ] **Step 3: Build**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 4: Run tests**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && swift test 2>&1 | tail -5
```
Expected: still 238 tests pass. The shell function still references `sandbox use` (cleaned in Task 5), but the generator just builds strings — no Swift link to the deleted struct.

- [ ] **Step 5: Commit**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && git add \
  Sources/OrreryCore/Commands/SandboxCommand.swift && \
git commit -m "$(cat <<'EOF'
[REMOVE] SandboxCommand.Use — superseded by top-level enter/exit

The `orrery sandbox use` subcommand is replaced by `orrery enter`
(opt into a sandbox) and `orrery exit` (return to origin). The Swift
stub for sandbox use is gone; the shell function still calls it via
the sandbox)/use) dispatch arm, which the next task removes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: ShellFunctionGenerator — add `enter)` and `exit)` cases (TDD)

The new dispatch arms are tested first via string assertions on the generated script.

**Files:**
- Modify: `Tests/OrreryTests/ShellFunctionGeneratorTests.swift` (add `handlesEnter`, `handlesExit`, `enterRejectsOrigin`)
- Modify: `Sources/OrreryCore/Shell/ShellFunctionGenerator.swift` (add two top-level cases)

- [ ] **Step 1: Write the failing tests**

In `Tests/OrreryTests/ShellFunctionGeneratorTests.swift`, **replace** the existing `handlesSandboxUse` test (lines 13-19) with three new tests:

```swift
    @Test("output handles top-level 'enter' subcommand")
    func handlesEnter() {
        let script = ShellFunctionGenerator.generate()
        // Top-level enter) case exists.
        #expect(script.contains("\n    enter)\n"))
        // Same shell-side export pipeline that sandbox use had.
        #expect(script.contains("sandbox _export"))
        #expect(script.contains("ORRERY_ACTIVE_ENV"))
    }

    @Test("output handles top-level 'exit' subcommand")
    func handlesExit() {
        let script = ShellFunctionGenerator.generate()
        // Top-level exit) case exists.
        #expect(script.contains("\n    exit)\n"))
        // exit clears tool env vars and writes ORRERY_ACTIVE_ENV=origin.
        #expect(script.contains("unset CLAUDE_CONFIG_DIR CODEX_HOME CODEX_CONFIG_DIR GEMINI_CONFIG_DIR ORRERY_GEMINI_HOME"))
        #expect(script.contains("export ORRERY_ACTIVE_ENV=\"origin\""))
    }

    @Test("enter rejects 'origin' and points the user at exit")
    func enterRejectsOrigin() {
        let script = ShellFunctionGenerator.generate()
        // The enter case must check for "$1" = "origin" and surface the L10n message.
        #expect(script.contains("\"$1\" = \"origin\""))
        #expect(script.contains(L10n.Enter.cannotEnterOrigin))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && swift test --filter ShellFunctionGenerator 2>&1 | tail -25
```
Expected: 3 failing tests (`handlesEnter`, `handlesExit`, `enterRejectsOrigin`) — the script doesn't contain `enter)` / `exit)` yet.

- [ ] **Step 3: Add the `enter)` and `exit)` cases to the generator**

In `Sources/OrreryCore/Shell/ShellFunctionGenerator.swift`, find the `case "$cmd" in` block (line 31). Insert two new top-level cases **before** the existing `sandbox)` case. After the change, the dispatch top looks like:

```swift
          local cmd="${1:-}"
          case "$cmd" in
            enter)
              # Shell-side env-var export when opting into a sandbox.
              # `shift` so $1 becomes the sandbox name.
              shift
              if [ -z "${1:-}" ]; then
                echo "Usage: orrery enter <sandbox>" >&2
                return 1
              fi
              if [ "$1" = "origin" ]; then
                printf "\(L10n.Enter.cannotEnterOrigin)\\n" >&2
                return 1
              fi
              # Unexport previous sandbox's env vars if switching from another sandbox.
              if [ -n "${ORRERY_ACTIVE_ENV:-}" ] && [ "$ORRERY_ACTIVE_ENV" != "origin" ]; then
                eval "$(command orrery-bin sandbox _unexport "$ORRERY_ACTIVE_ENV" 2>/dev/null || true)"
              fi
              local exports
              exports=$(command orrery-bin sandbox _export "$1") || { echo "orrery: sandbox '$1' not found" >&2; return 1; }
              eval "$exports"
              export ORRERY_ACTIVE_ENV="$1"
              command orrery-bin _set-current "$1" 2>/dev/null || true
              # Background quota refresh so `orrery list` shows fresh data
              # next time. Double subshell hides the job notice from
              # interactive shells, just like the update check above.
              ( ( command orrery-bin quota refresh -e "$1" >/dev/null 2>&1 ) & ) >/dev/null 2>&1
              printf "\(L10n.Enter.switched)\\n" "$1"
              ;;
            exit)
              # Idempotent: even when already at origin we re-assert the
              # state (set ORRERY_ACTIVE_ENV=origin, write current=origin)
              # so a freshly-started shell ends up consistent.
              if [ -z "${ORRERY_ACTIVE_ENV:-}" ] || [ "$ORRERY_ACTIVE_ENV" = "origin" ]; then
                export ORRERY_ACTIVE_ENV="origin"
                command orrery-bin _set-current origin 2>/dev/null || true
                printf "\(L10n.Exit.alreadyAtOrigin)\\n" >&2
                return 0
              fi
              eval "$(command orrery-bin sandbox _unexport "$ORRERY_ACTIVE_ENV" 2>/dev/null || true)"
              unset CLAUDE_CONFIG_DIR CODEX_HOME CODEX_CONFIG_DIR GEMINI_CONFIG_DIR ORRERY_GEMINI_HOME
              export ORRERY_ACTIVE_ENV="origin"
              command orrery-bin _set-current origin 2>/dev/null || true
              printf "\(L10n.Exit.switched)\\n"
              ;;
            sandbox)
```

(The existing `sandbox)` arm and everything below stays exactly as-is — Task 5 cleans `sandbox)/use)` separately.)

- [ ] **Step 4: Run tests to verify the three new tests now pass**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && swift test --filter ShellFunctionGenerator 2>&1 | tail -25
```
Expected: all `ShellFunctionGenerator` suite tests pass.

- [ ] **Step 5: Run full test suite to make sure nothing else broke**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && swift test 2>&1 | tail -5
```
Expected: 238 + 2 = 240 tests pass (we added 2 net new tests, replaced 1).

Note: actual count may differ by ±1 depending on whether the original `handlesSandboxUse` counted as 1 — verify build summary line, not exact number.

- [ ] **Step 6: Commit**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && git add \
  Sources/OrreryCore/Shell/ShellFunctionGenerator.swift \
  Tests/OrreryTests/ShellFunctionGeneratorTests.swift && \
git commit -m "$(cat <<'EOF'
[ADD] shell function: top-level enter) and exit) cases

The generated orrery() shell function gains two new dispatch arms:

- enter) does the same env-var export pipeline that the now-departing
  sandbox)/use) arm did, plus an early reject when the user passes
  'origin' (the spec calls this out as a clarity gain, not a peer
  sandbox to enter).
- exit) is symmetric to enter): unexport the current sandbox, unset
  the per-tool config-dir env vars, set ORRERY_ACTIVE_ENV=origin,
  write current=origin. Idempotent at origin — re-asserts state and
  emits a friendly "Already at origin" message instead of erroring.

Tests cover case existence, env-var pipeline, the origin rejection
path, and the unset-vars in exit. The old sandbox)/use) arm is still
present; it is removed in the next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: ShellFunctionGenerator — drop `sandbox)/use)` and migrate every call site (TDD)

This is the cleanup: remove the old dispatch arm, update every place in the generated script that still says `orrery sandbox use`, and translate the phantom loop.

**Files:**
- Modify: `Tests/OrreryTests/ShellFunctionGeneratorTests.swift` (tighten `autoActivatesCurrent`; add `sandboxUseGone`, `runUsesEnter`, `phantomLoopTranslatesOrigin`)
- Modify: `Sources/OrreryCore/Shell/ShellFunctionGenerator.swift` (remove `sandbox)/use)` arm; rewrite `_orrery_init` + `sandbox)/create)` auto-switch + `run)` target + phantom loop)

- [ ] **Step 1: Update / add the failing tests**

In `Tests/OrreryTests/ShellFunctionGeneratorTests.swift`:

**Replace** the existing `autoActivatesCurrent` test (lines 21-29) with:
```swift
    @Test("output auto-activates current sandbox on shell start")
    func autoActivatesCurrent() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("_orrery_init"))
        #expect(script.contains("current"))
        // Init must dispatch through the v3 verbs: origin → exit, other → enter.
        #expect(script.contains("orrery exit >/dev/null 2>&1"))
        #expect(script.contains("orrery enter \"$env_name\" >/dev/null 2>&1"))
        // Old call site is gone.
        #expect(!script.contains("orrery sandbox use \"$env_name\""))
    }
```

**Add** three new tests at the bottom of the suite (before the closing `}`):

```swift
    @Test("sandbox)/use) arm is removed from the dispatcher")
    func sandboxUseGone() {
        let script = ShellFunctionGenerator.generate()
        // The nested use) arm under sandbox) must be gone.
        // Match the indented dispatch line specifically so we don't false-match
        // a different "use)" elsewhere.
        #expect(!script.contains("                use)\n"))
        // sandbox)/create) auto-switch must hand off to enter, not sandbox use.
        #expect(!script.contains("orrery sandbox use \"$_name\""))
        #expect(script.contains("orrery enter \"$_name\""))
    }

    @Test("run -e <env> hands the target to orrery enter (or exit for origin)")
    func runUsesEnter() {
        let script = ShellFunctionGenerator.generate()
        // No bare `orrery sandbox use` left in the run case.
        #expect(!script.contains("orrery sandbox use \"$_run_target\""))
        // origin → exit; other → enter.
        #expect(script.contains("if [ \"$_run_target\" = \"origin\" ]; then"))
        #expect(script.contains("orrery enter \"$_run_target\""))
    }

    @Test("phantom loop translates TARGET_SANDBOX=origin into orrery exit")
    func phantomLoopTranslatesOrigin() {
        let script = ShellFunctionGenerator.generate()
        // The phantom-supervisor loop must dispatch on TARGET_SANDBOX with an
        // origin → exit fallback so the user can switch back via the slash
        // command without breaking the supervisor.
        #expect(script.contains("if [ \"$TARGET_SANDBOX\" = \"origin\" ]; then"))
        #expect(script.contains("orrery exit"))
        #expect(script.contains("orrery enter \"$TARGET_SANDBOX\""))
        // Old direct call is gone.
        #expect(!script.contains("orrery sandbox use \"$TARGET_SANDBOX\""))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && swift test --filter ShellFunctionGenerator 2>&1 | tail -25
```
Expected: 4 failing tests (`autoActivatesCurrent` now fails because it expects the new call sites; the three new tests fail because the old script still has the old call sites).

- [ ] **Step 3: Remove the `use)` arm inside `sandbox)` case**

In `Sources/OrreryCore/Shell/ShellFunctionGenerator.swift`, find the nested `case "${2:-}" in` block inside `sandbox)` (lines 33-87). Delete the entire `use)` arm (lines 34-62). The result:

```swift
            sandbox)
              case "${2:-}" in
                create)
                  command orrery-bin "$@"
                  if [ $? -eq 0 ]; then
                    local _name="" _skip=0
                    for _arg in "${@:3}"; do
                      if [ $_skip -eq 1 ]; then _skip=0; continue; fi
                      case "$_arg" in
                        --description|--clone|--tool|--copy-login-from) _skip=1 ;;
                        --*) ;;
                        *) _name="$_arg"; break ;;
                      esac
                    done
                    if [ -n "$_name" ]; then
                      printf "切換到 sandbox '%s'？[Y/n] " "$_name"
                      read -r _ans </dev/tty
                      case "${_ans:-Y}" in
                        [Yy]*|"") orrery enter "$_name" ;;
                      esac
                    fi
                  fi
                  ;;
                *)
                  command orrery-bin "$@"
                  ;;
              esac
              ;;
```

(The `create)` arm's auto-switch line `[Yy]*|"") orrery sandbox use "$_name" ;;` becomes `[Yy]*|"") orrery enter "$_name" ;;`. `_name` is never `"origin"` because `sandbox create origin` is rejected upstream — no exit translation needed here.)

- [ ] **Step 4: Update the `run)` case target-switch**

Find (around line 143-146):
```swift
              if [ $_run_non_phantom -eq 0 ] && [ "${1:-}" = "claude" ]; then
                if [ -n "$_run_target" ]; then
                  orrery sandbox use "$_run_target" || return $?
                fi
```

Replace with:
```swift
              if [ $_run_non_phantom -eq 0 ] && [ "${1:-}" = "claude" ]; then
                if [ -n "$_run_target" ]; then
                  if [ "$_run_target" = "origin" ]; then
                    orrery exit || return $?
                  else
                    orrery enter "$_run_target" || return $?
                  fi
                fi
```

- [ ] **Step 5: Update the phantom supervisor loop**

Still in the `run)` case, find the supervisor loop's TARGET_SANDBOX branch (around lines 163-165):

```swift
                  if [ -n "$TARGET_SANDBOX" ]; then
                    orrery sandbox use "$TARGET_SANDBOX" || break
                  fi
```

Replace with:
```swift
                  if [ -n "$TARGET_SANDBOX" ]; then
                    if [ "$TARGET_SANDBOX" = "origin" ]; then
                      orrery exit || break
                    else
                      orrery enter "$TARGET_SANDBOX" || break
                    fi
                  fi
```

- [ ] **Step 6: Update `_orrery_init` auto-activation**

Find (around lines 250-260):
```swift
          if [ -f "$current_file" ]; then
            local env_name
            env_name=$(cat "$current_file" 2>/dev/null)
            if [ "$env_name" = "default" ]; then
              env_name="origin"
              echo "origin" > "$current_file" 2>/dev/null || true
            fi
            if [ -n "$env_name" ]; then
              orrery sandbox use "$env_name" >/dev/null 2>&1 || true
            fi
          fi
```

Replace with:
```swift
          if [ -f "$current_file" ]; then
            local env_name
            env_name=$(cat "$current_file" 2>/dev/null)
            if [ "$env_name" = "default" ]; then
              env_name="origin"
              echo "origin" > "$current_file" 2>/dev/null || true
            fi
            if [ -n "$env_name" ]; then
              if [ "$env_name" = "origin" ]; then
                orrery exit >/dev/null 2>&1 || true
              else
                orrery enter "$env_name" >/dev/null 2>&1 || true
              fi
            fi
          fi
```

- [ ] **Step 7: Run tests to verify all pass now**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && swift test 2>&1 | tail -5
```
Expected: all tests pass (target count is the previous total +/- a few based on adds/removes).

- [ ] **Step 8: Sanity-check the generated script visually**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && swift build 2>&1 | tail -3 && \
.build/debug/orrery-bin init 2>/dev/null | grep -nE '(enter\)|exit\)|sandbox use|orrery enter|orrery exit|orrery sandbox use)' | head -20
```
Expected: top-level `enter)` and `exit)` cases listed; no `orrery sandbox use` anywhere; multiple `orrery enter` / `orrery exit` references.

If anything still references `orrery sandbox use`, find and fix it before continuing.

- [ ] **Step 9: Commit**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && git add \
  Sources/OrreryCore/Shell/ShellFunctionGenerator.swift \
  Tests/OrreryTests/ShellFunctionGeneratorTests.swift && \
git commit -m "$(cat <<'EOF'
[REMOVE] shell function: drop sandbox)/use); migrate call sites to enter/exit

With top-level enter) and exit) in place, the nested sandbox)/use) arm
is dead. Removed; the sandbox) dispatch now only has create) and a
*) fallback to orrery-bin.

Every remaining call site that previously dispatched through the
old verb is migrated:

- sandbox)/create) auto-switch prompt → orrery enter "$_name"
- run -e <env>: if env=origin → orrery exit, else orrery enter "$_run_target"
- phantom supervisor loop: same TARGET_SANDBOX=origin → orrery exit
  translation
- _orrery_init startup activation: same origin → exit, other → enter

PhantomSandboxTriggerCommand's sentinel format is unchanged — the
translation happens entirely on the supervisor side, so the slash
command surface and the Swift side stay simple.

Tests cover: sandbox)/use) gone, create-auto-switch uses enter, run-e
dispatches correctly, phantom loop translates origin, _orrery_init
dispatches correctly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Refresh the `~/.orrery-v3` sandbox install

This is a verification step, not a code change.

**Files (out of git):**
- Modify: `~/.orrery-v3/bin/orrery-bin`
- Modify: `~/.orrery-v3/activate.sh`

- [ ] **Step 1: Build release**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && swift build -c release 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 2: Copy the binary into the sandbox install**

```bash
cp ~/.config/superpowers/worktrees/orrery/v3-command-restructure/.build/release/orrery-bin ~/.orrery-v3/bin/orrery-bin && \
ls -la ~/.orrery-v3/bin/orrery-bin
```
Expected: new mtime, binary at `~/.orrery-v3/bin/orrery-bin`.

- [ ] **Step 3: Regenerate `activate.sh` from the new binary**

```bash
ORRERY_HOME="$HOME/.orrery-v3" ~/.orrery-v3/bin/orrery-bin init > ~/.orrery-v3/activate.sh && \
grep -nE '^    (enter|exit|sandbox|run|add)\)' ~/.orrery-v3/activate.sh
```
Expected: lines for `enter)`, `exit)`, `sandbox)`, `run)`, `add)` appear at the top-level case.

- [ ] **Step 4: Smoke-test in a non-interactive sandbox subshell**

```bash
env ZDOTDIR="$HOME/.orrery-v3/zsh" zsh -i -c 'orrery enter doesnotexist 2>&1; echo "==="; orrery exit 2>&1' 2>&1 | tail -10
```
Expected: first call surfaces "sandbox 'doesnotexist' not found" or similar error; second call surfaces "Already at origin (no sandbox active)." (no crash, exit code 0).

- [ ] **Step 5: Verify enter origin is rejected**

```bash
env ZDOTDIR="$HOME/.orrery-v3/zsh" zsh -i -c 'orrery enter origin 2>&1' 2>&1 | tail -5
```
Expected: the cannotEnterOrigin message ("'origin' is not a sandbox — use 'orrery exit' to leave the current sandbox.").

- [ ] **Step 6: No commit — this task only refreshes the user's local v3 sandbox install.**

---

## Task 7: Push

- [ ] **Step 1: Push branch**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && git push 2>&1 | tail -10
```
Expected: `feat/v3-command-restructure` advanced with the new commits on remote.

- [ ] **Step 2: Confirm via `git log`**

```bash
cd ~/.config/superpowers/worktrees/orrery/v3-command-restructure && git log --oneline -10
```
Expected: the five new commits (L10n + reference updates, Enter/Exit add, SandboxCommand.Use remove, shell function enter/exit add, shell function sandbox/use remove + migrations) sit on top of the spec commits (`16a2e64`, `5c4e1dc`).

---

## Self-Review Notes

**Spec coverage:**
- §1 Why: no implementation needed.
- §2 State machine: behavior matrix → Task 4 (enter/exit cases) + Task 5 (call-site migrations).
- §3 Behavior matrix: all six rows covered by enter/exit case bodies and the reject/no-op branches.
- §4 CLI surface: Task 2 adds top-level; Task 3 removes sandbox/use.
- §5 Shell function dispatch tree: Task 4 + Task 5.
- §6 Phantom flow: Task 5 step 5 (loop translation) + step 4 (run target). Sentinel itself not changed — verified by reading PhantomSandboxTriggerCommand; that file does not change.
- §7 L10n key migration: Task 1 fully.
- §8 Implementation order: this plan's task order matches the spec's listed order (L10n → new commands → delete old → shell function additions → shell function cleanup → refresh sandbox → push).
- §9 In/out scope: env var `ORRERY_ACTIVE_ENV` and internal types deliberately not touched (verified by no task that mentions renaming them).
- §10 Risk: rollback is `git revert <commit-range>` since the changes are split into named commits.

**Placeholder scan:** All code blocks contain literal code; commit messages are real, complete sentences; commands list exact paths and expected results.

**Type consistency:** `L10n.Enter.abstract`, `L10n.Enter.nameHelp`, `L10n.Enter.needsShellIntegration`, `L10n.Enter.switched`, `L10n.Enter.cannotEnterOrigin`, `L10n.Exit.abstract`, `L10n.Exit.switched`, `L10n.Exit.alreadyAtOrigin` are used consistently across Tasks 1, 2, 4. The shared `L10n.Enter.needsShellIntegration` for both `EnterCommand` and `ExitCommand` is explicit in the code (Task 2 Step 2 has a comment explaining it).

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-22-enter-exit-commands.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch with checkpoints for review.

Which approach?
