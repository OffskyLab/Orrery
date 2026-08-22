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

Naming the two is what makes the work tractable: identity is a string that
must stay byte-identical on disk, behaviour is nine members that can move
anywhere. What must *not* be inferred from that is that the enum should
survive as the identity carrier — see below.

## Design

### What `Tool` is today

Writing the whole thing out is worth doing, because it settles where the
line falls:

```swift
public enum Tool: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case gemini

    public var envVarName: String            // CLAUDE_CONFIG_DIR / CODEX_HOME / GEMINI_CONFIG_DIR
    public var subdirectory: String          // rawValue
    public var defaultConfigDir: URL         // ~/.claude / ~/.codex / ~/.gemini
    public var displayName: String
    public var installCommand: [String]?
    public var installCommandDisplay: String
    public var supportsSetup: Bool           // installCommand != nil
    public var authLoginCommand: [String]?
    public var ansiColor: String
    public var coloredTag: String
    public var sessionSubdirectories: [String]
}
```

Of the eleven members, exactly two are identity — `rawValue`, and
`subdirectory`, which *is* `rawValue`. The other nine are behaviour. The
split is far more lopsided than the phrase "separate identity from
behaviour" suggests.

### The constraint that enum makes visible

`CaseIterable` over three hardcoded cases is a closed world. Inside a
framework third parties depend on, that is fatal: **adding a tool would mean
editing the framework**, so AIToolKit would become the bottleneck rather
than the extension point, and driver 2 would be defeated by the very
package meant to deliver it.

An intermediate draft kept the enum inside orrery as a host-side
"allowlist". That does not survive scrutiny either: it only relocates the
closed set from the framework to the host. It is still three names compiled
in, and a third party still cannot add a fourth. The enum has to go
entirely.

### Types

- **`AITool`** — a **struct** in AIToolKit holding what the enum's members
  described: `id`, `envVarName`, `defaultConfigDir`, `authLoginCommand`,
  `ansiColor`, `sessionSubdirectories`, and the optional capabilities below.
  Each tool *constructs one* describing itself.
- **`AIToolRegistry`** — the registered set. `orrery`'s
  `Tool.allCases` becomes `registry.all`: the answer comes from **what has
  been registered**, not from what was compiled in.

Registration at startup already has precedent in this codebase —
`OrreryAccountKitRuntime.register()` and `OrreryThirdPartyRuntime.register()`
are called from `main.swift` today.

On-disk compatibility survives this: `AITool` is `Codable` through its `id`
alone, so `metadata.json` keeps reading and writing `"tool": "claude"`.

### The hazard this introduces

`CaseIterable` is **total at compile time**. A registry is **total only if
registration ran**. That difference is not cosmetic — but it is dangerous in
fewer places than it first appears, and the distinction is what makes the
fix small.

**Safe: everything guarded per tool.** `OriginTakeoverBootstrap`
(`!store.isOriginManaged(tool:)`) and `OriginAccountSeeder`
(`origin.account(for: tool) == nil`) both loop `Tool.allCases` but hold no
global flag and re-run every invocation. A tool registered later is simply
picked up on the next command — they self-heal.

**Dangerous: the four flag-guarded one-shots in `AccountMigration`.**

| flag file | function |
|---|---|
| `.migration-v3` | `runIfNeeded` |
| `.backfill-account-info-v1` | `runInfoBackfillIfNeeded` |
| `.account-config-consolidated` | `runAccountConfigConsolidationIfNeeded` |
| `.workspace-structure-relocated` | `runWorkspaceStructureRelocationIfNeeded` |

Each writes a single global "done" marker. If a tool is not registered when
one runs, that tool is skipped *and the flag is still written* — so it is
never migrated on that machine again. The failure is invisible and
permanent.

Requirements that follow, and they are not optional:

- Registration completes before any migration, takeover, or seeding runs —
  ordered explicitly in `main.swift`, not left to chance.
- One-shot flags become per-tool, or record which tools they covered, so a
  tool registered later still gets its migration.
- A test asserts that the registry is non-empty and complete at the point
  the first flag-guarded routine executes.

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
during Phase 1 is a cross-repo version bump rather than a local edit. That
is slower, and it was chosen deliberately over the alternative — keeping
AIToolKit inside orrery until the interface settles — because the
dependency story is then correct from the first commit and the API is
forced to be explicit rather than accidentally reaching into orrery
internals.

**Discipline this requires.** AIToolKit stays on `0.x` through Phase 1,
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

### Phase 1 — the enum gives way to the registry

A strangler, not a rewrite. `AITool` and the registry appear first, with the
existing enum *bridging* into them — each case produces its descriptor — so
call sites can migrate a few at a time while both shapes coexist. The enum
is deleted once nothing reads it.

Order within the phase, because it is too large for one change:

1. `AITool` + registry exist; enum bridges to them; registration wired into
   `main.swift` ahead of every migration path.
2. The one-shot flag hazard above is fixed *before* any call site moves —
   this is the step that must not be deferred.
3. Behaviour migrates per capability: credentials → launch/exit → shell →
   phantom.
4. `Tool.allCases` → `registry.all` across the 24 sites.
5. Enum deleted.

- On-disk format: **unchanged** (`AITool` encodes as its id)
- CLI: `--claude` / `--codex` / `--gemini` stay as orrery's own convenience
  flags, mapped to registered ids. They are host UI, not framework surface;
  a tool with no dedicated flag is still reachable generically.
- Delivers all three drivers

The 62 per-tool `switch` sites are not extra work here — nearly all of them
*are* the behaviour being moved, so they resolve as part of step 3 rather
than as a separate migration.

### Phase 2 — plugins split

Move the Codex and Gemini plugins to their own repos
(`orrery-codex-support`, `orrery-gemini-support`), each depending only on
AIToolKit.

The loading mechanism is **deliberately left open** until Phase 1 has shown
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

Non-negotiable throughout Phase 1:

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
Phase 1 should not try to settle it.

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

1. Do Phase 1's five steps each ship as one PR, or does the capability
   migration step get subdivided further?
2. Do Codex and Gemini stay in-repo through Phase 1, moving only at Phase 2?
   (Assumed yes.)
3. Does the gemini upstream block change whether Gemini is worth carrying at
   all?
4. Does AccountKit eventually deserve its own repo too? It is orrery's own
   layer rather than a per-tool one, so probably not — but if AIToolKit ends
   up genuinely reusable outside orrery, the question changes.
5. Where do the several remaining Claude-specific *commands* live —
   `_prepare-claude-launch`, `_capture-claude-exit`, `orrery-claude-hook`?
   They are entry points, not library code, so they may need a plugin
   mechanism of their own rather than fitting the `AITool` struct.
