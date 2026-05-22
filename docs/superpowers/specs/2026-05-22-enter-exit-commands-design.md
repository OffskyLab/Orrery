# Design — `orrery enter` / `orrery exit` (sandbox state verbs)

## Context

v3 promoted a number of subcommands to the top level (e.g. `orrery account add` → `orrery add`) but left **sandbox switching** under the nested `orrery sandbox use <name>` form. That decision was uniform with the rest of the `sandbox` subcommand group, but it produced a UX wart: `origin` — the user's real Claude/Codex/Gemini config, managed by orrery via takeover symlinks — has to be addressed as if it were a sandbox (`orrery sandbox use origin` to return to it).

That conflates two different operations:

- **Entering a sandbox** is opt-in: the user picks an alternate config and exports a different set of env vars.
- **Returning to origin** is the *absence* of a sandbox, not a sandbox of its own. It is an opt-out — the inverse of `enter`, not a peer of it.

## Problem

The current shape forces both operations through the same verb, with `origin` as a reserved sandbox name. As a result:

- `orrery sandbox use origin` is the documented way to "leave" — but reads like "enter the origin sandbox", which is misleading.
- The mental model "origin = my real config, sandboxes = alternate envs" is not reflected in the CLI.
- Hint strings either have to use the awkward `orrery sandbox use origin` literal, or skip the case entirely.

This is a design smell — not a bug — but v3 has not shipped, so it can be fixed now at zero compat cost.

## Decision

Replace `orrery sandbox use <name>` with two top-level verbs:

- `orrery enter <sandbox>` — switch into a sandbox
- `orrery exit` — return to origin (no sandbox active)

`orrery sandbox use` is **removed entirely** (CLI + shell function + L10n). There is no compat alias.

## CLI surface

### `orrery enter <sandbox>`

| Situation | Behavior |
| --- | --- |
| Currently at origin, `enter X` | unexport nothing; export X; set `ORRERY_ACTIVE_ENV=X`; print switched message. |
| Currently in sandbox Y, `enter X` | **Transparent switch**: unexport Y; export X; set `ORRERY_ACTIVE_ENV=X`; print switched message. No "you are in Y, exit first" prompt. |
| `enter origin` | **Rejected**. stderr: `'origin' is not a sandbox — use 'orrery exit' to leave the current sandbox.` exit 1. |
| `enter <nonexistent>` | Same error path as today's `sandbox use <nonexistent>`. exit 1. |

### `orrery exit`

| Situation | Behavior |
| --- | --- |
| Currently in sandbox X, `exit` | unexport X; unset `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / `CODEX_CONFIG_DIR` / `GEMINI_CONFIG_DIR` / `ORRERY_GEMINI_HOME`; set `ORRERY_ACTIVE_ENV=origin`; write `current=origin`; print switched-to-origin message. |
| Currently at origin, `exit` | **Friendly no-op**. stderr: `Already at origin (no sandbox active).` exit 0. |

## Shell function changes (`ShellFunctionGenerator`)

Top-level dispatch gains two cases:

- `enter)` — body is the body of today's `sandbox)/use)` case (env-var dance + active-env write), with an added guard that rejects `enter origin`.
- `exit)` — body is the `[ "$2" = "origin" ]` branch of today's `sandbox)/use)` case (unset vars + `ORRERY_ACTIVE_ENV=origin` + `_set-current origin`), with an added "already at origin" no-op + stderr message when `ORRERY_ACTIVE_ENV` is unset or `origin`.

The `sandbox)` case keeps its `create)` arm and the `*) command orrery-bin "$@"` fallback; the `use)` arm is deleted.

Two existing call sites are updated to use the new verbs:

- `_orrery_init` auto-activation: `orrery sandbox use "$env_name"` → `orrery enter "$env_name"`.
- `run)` phantom-claude pre-target: `orrery sandbox use "$_run_target"` → `orrery enter "$_run_target"`.

## Swift side

Two new top-level commands, both shell-integration-only (i.e. their `run()` throws `enter.needsShellIntegration`):

- `Sources/OrreryCore/Commands/EnterCommand.swift` — `commandName: "enter"`, one positional `name`. Mirrors today's `SandboxCommand.Use.run()` (the binary never executes the env-var dance; the shell function does).
- `Sources/OrreryCore/Commands/ExitCommand.swift` — `commandName: "exit"`, no args.

Both are registered on `OrreryCommand.configuration.subcommands` (after `UseCommand.self`).

`SandboxCommand.Use` (the entire nested struct in `Sources/OrreryCore/Commands/SandboxCommand.swift`) is deleted, and `Use.self` is removed from the `SandboxCommand` subcommand list.

## L10n key changes

Rename:

| Old | New |
| --- | --- |
| `use.abstract` | `enter.abstract` |
| `use.nameHelp` | `enter.nameHelp` |
| `use.needsShellIntegration` | `enter.needsShellIntegration` (shared by `exit`; body rewritten to `'orrery enter' or 'orrery exit' requires shell integration.\n...`) |
| `use.switched` | `enter.switched` |
| `use.switchedToOrigin` | `exit.switched` (semantically "switched back to origin") |

Add:

- `exit.abstract` — "Leave the current sandbox and return to origin."
- `exit.alreadyAtOrigin` — "Already at origin (no sandbox active)."
- `enter.cannotEnterOrigin` — "'origin' is not a sandbox — use 'orrery exit' to leave the current sandbox."

Update existing hint strings that reference `orrery sandbox use <name>` (committed in c242327 only days ago) to reference `orrery enter <name>` instead:

- `create.firstEnvCreated` × 3 langs
- `info.noActive` × 3 langs
- `memory.noActiveEnv` × 3 langs
- `tools.noActive` × 3 langs
- `which.noActive` × 3 langs
- `sandbox.setEnvNoActive` × 3 langs
- `ThirdPartyCommand.swift` / `InstallCommand.swift` ValidationError messages (also previously updated)

`keys.md` documentation table is updated in step.

## Phantom flow

The phantom sentinel keeps its existing `TARGET_SANDBOX` shape — no new sentinel file. `PhantomSandboxTriggerCommand` continues to write `TARGET_SANDBOX=<name>` (or `TARGET_SANDBOX=origin`).

The shell-function side of phantom (the supervisor loop that sources the sentinel after claude exits) translates:

```sh
if [ "$TARGET_SANDBOX" = "origin" ]; then
    orrery exit
else
    orrery enter "$TARGET_SANDBOX"
fi
```

The `/orrery:phantom` slash command surface and `PhantomSandboxTriggerCommand` itself do not change.

## Tests

`ShellFunctionGeneratorTests`:

- Rename `handlesSandboxUse` → `handlesEnter`. Assert script contains top-level `enter)` case and `sandbox _export` (still the underlying mechanism).
- Add `handlesExit` test. Assert script contains top-level `exit)` case and clears `CLAUDE_CONFIG_DIR` etc.
- Existing `autoActivatesCurrent` test: change assertion from `orrery sandbox use "$env_name"` to `orrery enter "$env_name"`.
- New assertion: top-level `sandbox)` case no longer contains a `use)` arm.
- Phantom-loop assertion: covers the `TARGET_SANDBOX=origin → orrery exit` / else `orrery enter` translation.

Other tests: grep for `sandbox use` / `Use.self` / `L10n.Use.*` across `Tests/` and update as needed.

## What is explicitly NOT in scope

- The env-var `ORRERY_ACTIVE_ENV` is **not** renamed. Calling it `ORRERY_ACTIVE_SANDBOX` would be more accurate, but it ripples across every export/unexport pathway and external consumers (statusline, MCP server). Out of scope.
- Internal Swift types `EnvironmentStore`, `Environment`, `ReservedEnvironment.defaultName` are **not** renamed.
- Other `SandboxCommand` subcommands (list, create, delete, info, rename, current, set-env, unset-env, memory, sync, export, unexport) are **not** touched.
- No compat shim or hidden alias for `sandbox use`. v3 has not shipped; clean break.

## Implementation order

1. L10n string additions + renames (en / zh-Hant / ja) — Swift generated `L10n.Enter.*` / `L10n.Exit.*` types appear before code that references them.
2. `EnterCommand` + `ExitCommand` Swift files; register on `OrreryCommand`.
3. Delete `SandboxCommand.Use`; remove from subcommands list.
4. Rewrite affected sections of `ShellFunctionGenerator` (new `enter)` + `exit)` cases; drop `sandbox)/use)`; update init + run-target).
5. Update phantom-loop branch in shell function for `TARGET_SANDBOX=origin` handling.
6. Update `ShellFunctionGeneratorTests` to match.
7. Update hint strings + ValidationError text that reference `orrery sandbox use`.
8. Update `keys.md`.
9. `swift build` → `swift test` → commit (one commit, possibly split: "L10n + new commands + delete SandboxCommand.Use" then "shell function + tests" then "hint strings").
10. Refresh `~/.orrery-v3/bin/orrery-bin` + regenerate `~/.orrery-v3/activate.sh` so the sandbox test shell sees the new verbs.
11. Push.

## Risk / rollback

- Pre-ship — no external dependence on `sandbox use`. If the change turns out wrong, revert the implementation commits; the spec stays for future reference.
- The shell function regenerates on `eval "$(orrery init)"` (i.e. next shell start after install), so the user can't get into a partially-updated state on a single machine.

## Open questions

None — design fully resolved during brainstorming.
