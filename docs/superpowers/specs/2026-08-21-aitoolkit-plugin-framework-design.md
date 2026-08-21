# AIToolKit — a plugin framework for AI CLI tools

**Status:** design approved, not yet implemented
**Date:** 2026-08-21

## Goal

Turn per-tool support in orrery from a closed enum into an open plugin
framework called **AIToolKit**, so that Claude, Codex, Gemini, and future
tools are all plugins over a shared account/workspace framework — and so a
third party can add a tool without changing orrery itself.

## Why

Three drivers, all stated as primary:

1. **Other tools destabilise the core.** Gemini is the live example: upstream
   removed the `gemini auth login` subcommand, gemini-cli ignores the config
   dir variable orrery was setting, and Google then blocked the client for
   individual Gemini Code Assist accounts outright. None of that is orrery's
   doing, yet all of it lands in orrery's core, its tests, and its release
   cadence.
2. **Third parties should be able to add tools.** Someone wanting Cursor or
   Copilot CLI support should not have to patch `Tool.swift`.
3. **Shrink the maintenance surface.** Core's tests, docs, and releases
   should be about the framework and Claude; other tools get their own
   lifecycle.

Driver 2 is the binding one. It rules out the cheap alternatives (marking
non-Claude tools experimental, or simply deleting them), because none of
those produce an extension point.

## Current state

Measured on `main` at the time of writing, not estimated:

| | Value |
|---|---|
| Total `Sources/` | 17,256 LOC |
| Claude-named files | 1,468 LOC |
| Phantom subsystem | 1,123 LOC |
| **Claude-related total** | **~2,600 LOC (~15%)** |
| `Tool` references | 197, across 51 files |
| Per-tool `switch` / `case .claude` sites | 62 |
| `Tool.allCases` sites | 24 |

Two findings shape the design.

**The framework is already the bulk.** ~85% of the codebase — account pool,
workspaces, memory, session sharing, `run`/`delegate`, MCP, setup, shell
generation — is tool-agnostic already. This is a smaller job than "rewrite
orrery".

**Half the pattern already exists.** `AccountDirectoryRuntime.makeManager`
plus the `ToolAccountManaging` protocol (implemented by `ClaudeAdapter`,
`CodexAdapter`, `GeminiAdapter` in `OrreryAccountKit`) is exactly the
registration seam this design needs — just scoped narrowly to account
directory layout. `ThirdPartyRuntime` is a second instance of the same
injection idiom. AIToolKit generalises a pattern the codebase already
trusts rather than introducing a foreign one.

Note that `OrreryAccountKit` is *not* a first draft of AIToolKit that
should be replaced by it. It is a separate layer that will sit on top —
see "Target layout".

## The core insight

`Tool` currently carries two unrelated responsibilities:

- **Identity** — a stable string used as a dictionary key, a path segment
  (`accounts/claude/…`), a JSON value (`metadata.json`'s `"tool": "claude"`),
  and a CLI flag (`--claude`).
- **Behaviour** — `envVarName`, `defaultConfigDir`, `authLoginCommand`,
  `ansiColor`, `sessionSubdirectories`, and friends.

These can be separated independently, and separating them in that order is
what makes the work safe. Behaviour can move out while identity stays
exactly as it is, which means no on-disk migration and no CLI change for the
entire first phase.

## Design

### Types

- **`ToolID`** — identity. Initially *literally the existing `Tool` enum*,
  unchanged. Later a `String`-backed struct.
- **`ToolPlugin`** — behaviour. A protocol carrying what is today the enum's
  computed properties, plus the optional capabilities below.
- **`ToolRegistry`** — `ToolID -> ToolPlugin`, and enumeration, replacing
  `Tool.allCases`.

### Repository layout

**AIToolKit is its own repository from day one**, published as a Swift
package. It is not an orrery target.

This is forced by driver 2 rather than chosen for tidiness. A plugin author
writing `orrery-codex-support` must be able to depend on the protocol
*alone*. If AIToolKit lived inside orrery, every plugin would have to pull
in the entire application — its commands, its account store, its shell
generator — to reach an interface. That is not a dependency anyone can
reasonably take, and it would make "third parties can add tools" false in
practice while looking true on paper.

```
                    AIToolKit  (own repo, versioned package)
                    ↑        ↑
                orrery     orrery-codex-support
```

Both sides depend on the framework; neither depends on the other.

**Accepted cost.** Extracting on day one means every interface adjustment
during Phase 1a is a cross-repo version bump rather than a local edit. That
is slower, and it was chosen deliberately over the alternative — keeping
AIToolKit inside orrery until the interface settles — because the
dependency story is then correct from the first commit and the API is
forced to be explicit rather than accidentally reaching into orrery
internals.

**Discipline this requires.** AIToolKit stays on `0.x` through Phase 1a,
with breaking changes expected and semver honoured from `1.0`. Nothing in
AIToolKit may reference orrery types.

### Layering inside orrery

`AIToolKit` sits **below** `OrreryAccountKit`, which stays where it is:

```
AIToolKit         what a tool IS — launch, config location, login, resume
    ↑
OrreryAccountKit  orrery's account pool, expressed over those tool facts
    ↑
OrreryCore
```

An earlier draft had AIToolKit absorb `OrreryAccountKit`. That was wrong,
and the reason is worth stating because it also gives the framework its
organising rule: **account management is orrery's invention, not the
tool's.** Claude Code, Codex and gemini-cli have no concept of an account
pool — each knows only that it has one config directory. Orrery is what
layers pooling on top. Folding account management into the tool abstraction
would push a consumer down inside the thing it consumes.

So the boundary is:

> **AIToolKit states facts about the tool. AccountKit decides orrery's
> policy in response to them.**

Worked example. "gemini-cli only reads `$HOME/.gemini` and ignores
`GEMINI_CONFIG_DIR`" is a fact about gemini — AIToolKit. "Therefore build a
sibling wrapper directory holding `.gemini -> <account dir>` and redirect
`HOME`" is orrery's isolation policy — AccountKit. Likewise
`privateSubdirs` / `baseSharedSubdirs` are orrery's sharing policy, not
properties of the tool, and stay in AccountKit.

This keeps `ToolAccountManaging` exactly where it is, re-expressed in terms
of AIToolKit's facts rather than a hardcoded enum.

`OrreryCore` depends on AIToolKit's *protocols*; concrete plugins are
registered at startup by the binary, as `OrreryAccountKitRuntime.register()`
already does.

### Capability layering

Claude is a plugin too — not a privileged case. If Claude reached past the
interface, the interface would never be exercised by its most demanding
consumer and third parties would hit walls the maintainers never felt.

That said, "everything becomes a plugin capability" would be
over-abstraction. Applying the facts/policy rule:

| Mechanism | Home | Reasoning |
|---|---|---|
| Phantom registry, liveness, supervisor shim loop | **core** | Genuinely tool-agnostic |
| `--resume` semantics, session-id discovery | **AIToolKit** capability | A fact about how the tool resumes |
| Where credentials live (Keychain item vs file in config dir) | **AIToolKit** fact | `CredentialAdapter` already prefigures this |
| Copying/importing a credential into a pooled account | **AccountKit** | Pooling is orrery's idea |
| Config-file merge/split at launch and exit | **AIToolKit** capability (optional hooks) | Only Claude needs it; the *shape* generalises |
| `auth_success` notification | **AIToolKit** capability | "the tool can tell us login finished" |
| Account-dir sharing policy (`privateSubdirs`, shared subdirs) | **AccountKit** | Orrery's policy, not a tool property |
| Shell wrapper function contribution | **AIToolKit** capability | **Least precedent — see risks** |
| OAuth token refresh | **AIToolKit** capability | Provider-specific |

Capabilities are optional. A plugin implements the subset its tool needs;
Claude will implement the most, which is what keeps the interface honest.

## Phasing

### Phase 0 — the framework repo exists

Create the AIToolKit repository with the protocol skeleton and nothing else.
orrery takes it as an SPM dependency. No behaviour has moved yet; this
phase exists so that every subsequent interface decision is made in the
place third parties will consume it, not retrofitted later.

### Phase 1a — behaviour moves, identity does not

Introduce `ToolPlugin` + `ToolRegistry`. Move behaviour off the `Tool` enum
into three plugins. Keep the enum as `ToolID`.

- On-disk format: **unchanged**
- CLI surface: **unchanged**
- `Tool.allCases`: still valid, migrated opportunistically
- Delivers: driver 1 and driver 3, partially; the interface exists and is
  under real load

Explicitly **not** delivered: third-party extension still requires editing
the enum. This intermediate state is accepted deliberately in exchange for a
large drop in risk.

### Phase 1b — identity opens

Replace the enum with a `String`-backed `ToolID` struct resolved through the
registry. This is where `Tool.allCases` and static `--claude`/`--codex`
ArgumentParser flags actually have to be solved.

- Delivers driver 2

### Phase 2 — plugins split

Move the Codex and Gemini plugins to their own repos
(`orrery-codex-support`, `orrery-gemini-support`), each depending only on
AIToolKit.

The loading mechanism is **deliberately left open** until 1a/1b have shown
what the interface really needs. Note that it interacts with Phase 0's
choice: if plugins load as compile-time SPM dependencies, then AIToolKit as
a Swift package is exactly the right artifact, but orrery must still
enumerate every plugin in its own `Package.swift` — so a third party can
*build* against the framework without orrery's cooperation, but not *ship*
without it. Truly independent shipping needs a discovered executable
speaking a wire protocol, at which point the Swift package matters less
than the protocol document. Extracting AIToolKit early is right either way;
what it does not by itself deliver is runtime pluggability.

## Compatibility constraints

Non-negotiable for phases 1a and 1b:

- `metadata.json` keeps `"tool": "claude"`.
- Account paths keep `accounts/<tool>/<id>/`.
- `--claude` / `--codex` / `--gemini` keep working.
- Existing installs must not require re-login or migration.

## Risks

**Shell function contribution has no precedent.** `ShellFunctionGenerator`
emits `claude()` and `gemini()` wrappers as literal text. Letting plugins
contribute shell is the least-designed part of this and the most likely to
need its own round of design. It is also the part where a bad interface is
most expensive, because the output is written into users' rc files.

**62 switch sites is a real refactor.** Mitigated by the strangler shape —
protocol alongside enum, migrate incrementally, delete last — but it will
span many PRs.

**Phantom's core/plugin boundary is a guess until tested.** The claim that
the registry and shim are tool-agnostic while only resume semantics vary is
plausible but unproven; no non-Claude tool has ever been supervised. Phase
1a should not try to settle it.

**Gemini may be unsupportable regardless.** Google has blocked gemini-cli
for individual Code Assist accounts. Whether existing gemini accounts keep
working is unverified. If gemini support is dead upstream, that changes what
Phase 2 is even for — worth confirming before starting it.

## Non-goals

- Runtime dynamic loading (`dlopen`). Swift ABI and macOS codesigning make
  it a poor fit; the session that produced this design hit a SIGKILL from a
  broken signature after a plain `cp`.
- Changing on-disk formats.
- Rewriting phantom.
- Adding a new tool as part of this work.

## Open questions

1. Does Phase 1a ship as one PR or several? (Recommendation: several, one
   capability at a time — credentials, launch/exit, shell, phantom.)
2. Do Codex and Gemini stay in-repo through 1b, moving only at Phase 2?
   (Assumed yes.)
3. Does the gemini upstream block change whether Gemini is worth carrying at
   all?
4. Does AccountKit eventually deserve its own repo too? It is orrery's own
   layer rather than a per-tool one, so probably not — but if AIToolKit ends
   up genuinely reusable outside orrery, the question changes.
5. Where do the several remaining Claude-specific *commands* live —
   `_prepare-claude-launch`, `_capture-claude-exit`, `orrery-claude-hook`?
   They are entry points, not library code, so they may need a plugin
   mechanism of their own rather than fitting the `ToolPlugin` protocol.
