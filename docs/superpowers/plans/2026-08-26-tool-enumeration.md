# Tool Enumeration: what "every tool" means

**Goal:** decide, and then implement, what replaces `Tool.allCases` — the 33 sites
that currently mean "every tool there is" as a compile-time claim.

**Spec:** `docs/superpowers/specs/2026-08-21-rpc-plugin-boundary-design.md`
**Precedes:** nothing else in sub-project A. This is the change that actually opens
the door to a third-party tool, and the one the deferred work in
`2026-08-26-plugin-registration-wiring.md` is waiting on.

## The finding that shapes this plan

`Tool.allCases` is not merely an iteration source. The enum is also the **key to
behaviour the registry cannot supply**:

- `Tool.flowType` → `ClaudeFlow` / `CodexFlow` / `GeminiFlow`: a `switch self` with
  no registry equivalent. It decides how login state is copied, which files are
  credentials, what "non-login settings" means.
- `AccountDirectoryRuntime.manager(for:)` → `ClaudeAdapter` / `CodexAdapter`:
  account-directory layering, symlink layout, workspace mirroring.
- `Tool.envVarName`, and the `switch self` shape generally.

`AITool` describes eight facts. None of the above is one of them. So swapping the
iteration source is not a mechanical change: a registered third-party tool would be
iterated and then hit `Tool(rawValue: id) == nil`, or a `switch` with no case for
it. Every loop body would need an answer that does not exist.

**This is the real blocker, and it is a capability boundary, not a plumbing one.**
The plan below is shaped around that rather than around the 33 call sites.

The direction is settled: `AITool` should be fully decoupled from orrery, and what
is an enum today becomes a registry. So the answer is not to keep behaviour in the
enum — it is to make behaviour part of what the framework asks a tool to implement,
and leave orrery as the thing that triggers it. See Phase 2.

Not urgent today, and worth writing down so it is not mistaken for a live bug:
`registerPlugins` is only ever asked for `pluginProvidedTools` (claude), so no
third-party tool can register yet. The half-present state described above is
currently unreachable.

## Global constraints

- Tests use swift-testing. Never XCTest.
- `[FEAT]`/`[FIX]`/`[DOCS]` commit prefixes, no `Co-Authored-By` trailer.
- A plugin failure must never abort an invocation for the other tools.
- `AccountMigration.legacyBuiltInTools` stays a fixed historical list and must
  **not** become any registry query — it is a claim about what the past covered.
  Its own comment already says so.

---

## Phase 1 — split the 33 sites by what the loop body needs

Not a code change: a survey that ends in a table in this file. The distinction that
matters is not display-vs-write, it is **description-vs-behaviour**.

- [ ] **Step 1.1 — classify every site.** For each, record which of the eight facts
  it reads, and which enum-only behaviour it reaches for. A site that touches only
  facts can move as soon as there is something to iterate; a site that reaches for
  `flowType` or an account-dir manager cannot move until Phase 2 lands.

Expected shape, to be confirmed rather than assumed:

| Group | Sites | Needs |
|---|---|---|
| Description only | `ListCommand`, `ShowCommand`, `CurrentCommand`, `CurrentExportCommand`, `SessionsCommand` listing | the eight facts |
| Behaviour | `AccountMigration` (7 sites), `OriginTakeoverBootstrap`, `OriginAccountSeeder`, `AccountStore`, `SandboxCommand`, `SetupCommand`, `UninstallCommand`, `RunCommand`, `DelegateProcessBuilder` | `flowType`, account-dir managers, `envVarName` |
| Last to move | `AIToolRegistration.registerBuiltInTools` | a *list* of built-ins — it is what populates the registry, so it cannot read from it. A list, not necessarily an enum: `[BuiltInAITool]` serves once nothing else needs the type |

## Phase 2 — behaviour becomes part of the framework spec

**Decided (2026-08-26).** A third-party tool implements the framework's spec and
orrery *triggers* it. orrery's own vocabulary — account dir, workspace, origin —
stays out of the framework; the tool is independent of orrery while conforming to
it. "Third-party tools are description-only" is rejected: a tool that cannot be
asked to do anything is not a tool orrery can manage.

The load-bearing observation is that **`ToolFlow` is already framework-shaped**:

```swift
static func copyLoginState(sourceDir: URL?, targetDir: URL) -> Bool
static func copyNonLoginSettings(sourceDir: URL, targetDir: URL)
static var supportsMemoryIsolation: Bool { get }
```

Every member takes plain URLs and booleans. Not one mentions an account, a
workspace, or origin. The only orrery-specific thing about it is *who decides
those two URLs* — and that stays in orrery. So this is not a protocol to design
from scratch; it is one that already exists in the right shape and needs moving.

- [ ] **Step 2.1 — lift `ToolFlow` into the framework** as operations on a tool,
  in the tool's own terms. orrery keeps deciding the paths and keeps calling.
- [ ] **Step 2.2 — the same for account-directory layout**
  (`AccountDirectoryRuntime.manager(for:)`). Check first whether it is already
  path-shaped the way `ToolFlow` is, rather than assuming it needs redesigning.
- [ ] **Step 2.3 — `ClaudeFlow`'s 148 lines move into `orrery-claude`.** Its
  bespoke logic — the macOS Keychain service name derived from a hash of
  `CLAUDE_CONFIG_DIR`, `.claude.json` living somewhere different for origin than
  for an env, the identity/ephemeral key merge, `prepareForSelfLogin` — is
  claude-specific knowledge, and the plugin is the claude-specific process. Codex
  and gemini are 25 lines each and reduce to little more than "my credential file
  is named this", which is a fact rather than a behaviour.

**A consequence to design for, not discover later:** that logic will run in
*another process*. `ClaudeFlow.swift:47` reaches for
`fm.homeDirectoryForCurrentUser` today, and a plugin has its own process
environment — `ORRERY_USER_HOME` does not follow it across the boundary. The
protocol must therefore state that the paths orrery passes are the whole truth
and a plugin may not derive a home of its own. This repo has fixed that same
isolation-seam family three times already; moving code across a process boundary
is exactly where it would come back.

## Phase 3 — move the sites, in the order Phase 1 established

## Phase 3 — move the sites, in the order Phase 1 established

- [ ] **Step 3.1 — description-only sites** move to iterating the registry. Behaviour
  preserving today: with built-ins plus the claude plugin the set is the same three
  tools, so the suite should show no change. The one intended difference is a broken
  install, where claude is absent and listings say so.
- [ ] **Step 3.2 — the migrations.** This is where Step 1.4's guard in
  `2026-08-26-plugin-registration-wiring.md` finally becomes live: `pending` starts
  coming from the registry, and a tool whose plugin failed to load must not be
  recorded as covered. That test is already written and currently proves nothing —
  it starts proving something here, and the first thing to check is that it *fails*
  when the union in `markCovered` is broken.
- [ ] **Step 3.3 — the remaining behavioural sites**, gated on Phase 2's answer.

## Open questions for the user

1. **What a third-party tool should do in listings before Phase 2 lands** — it can
   be described but not yet triggered. Appear with no accounts? Be hidden? Refuse
   to register with a diagnostic? Today it cannot happen at all, because discovery
   is only ever asked for `pluginProvidedTools`; the question arrives the moment
   that widens.
2. **Whether `supportsMemoryIsolation` belongs in the framework.** It is the one
   `ToolFlow` member that reads like an orrery policy question rather than a fact
   about the tool — "does *orrery* offer per-env memory isolation for this tool"
   rather than "can this tool do X".

## Explicitly not in this plan

- **`Tool.envVarName`'s 11 readers.** `Tool.gemini.envVarName` returns
  `"GEMINI_CONFIG_DIR"` while `configDirEnvVar` is `nil`, and PR #52 needs that
  literal string as a key to *remove* from a child environment. `AITool` cannot yet
  express "a variable this tool ignores but that must be cleared".
- **`Account.tool` and `Workspace.isolatedSessionTools`.** The enum is in a persisted
  format in both, so a third-party tool cannot own an account regardless of anything
  here. Sub-project B.
- **Deleting `Tool`.** Now the destination rather than an open question, and out of
  scope only in the sense that it is the *last* step: once behaviour is in the
  framework and the sites iterate the registry, what is left of the enum is a list
  of built-ins — which does not need to be an enum. An earlier draft of this plan
  called `registerBuiltInTools` a fixed point that "stays on the enum by
  definition"; that was wrong. It needs a *list*, and a `[BuiltInAITool]` serves.
  What genuinely outlives this plan is sub-project B: `Account.tool` and
  `Workspace.isolatedSessionTools` put the enum in a persisted format.
