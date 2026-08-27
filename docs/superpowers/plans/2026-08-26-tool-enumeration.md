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
| Fixed point | `AIToolRegistration.registerBuiltInTools` | stays on the enum by definition — it is what *populates* the registry |

## Phase 2 — a registered tool can be *asked to do things*

The capability boundary. Out of scope for this plan to design in full; in scope to
state what it must cover and to get agreement on the shape before any call site
moves.

- [ ] **Step 2.1 — enumerate the behaviours a tool must supply**, from the loop
  bodies in Phase 1 rather than from imagination: copy login state, copy non-login
  settings, name its credential file, lay out an account directory, say which env
  var exports its config dir.
- [ ] **Step 2.2 — decide where they live.** Three candidates, and the choice is the
  user's: extend the RPC protocol with these operations; keep them in-process behind
  a second registry of behaviour providers, keyed by id; or accept that third-party
  tools are description-only and *scope orrery's behaviour to built-ins forever*.
  The third is a legitimate answer and is cheaper than it sounds — it means
  `allCases` never fully dies.

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

1. **Phase 2's shape** — RPC operations, in-process behaviour registry, or
   built-ins-only behaviour. Everything in Phase 3 past Step 3.2 depends on it, and
   the third option is a legitimate, much cheaper answer.
2. **What a description-only third-party tool should do in listings** before Phase 2
   exists. Appear with no accounts? Be hidden? Refuse to register with a diagnostic?
   Today it cannot happen; the moment discovery widens past `pluginProvidedTools`,
   it can.

## Explicitly not in this plan

- **`Tool.envVarName`'s 11 readers.** `Tool.gemini.envVarName` returns
  `"GEMINI_CONFIG_DIR"` while `configDirEnvVar` is `nil`, and PR #52 needs that
  literal string as a key to *remove* from a child environment. `AITool` cannot yet
  express "a variable this tool ignores but that must be cleared".
- **`Account.tool` and `Workspace.isolatedSessionTools`.** The enum is in a persisted
  format in both, so a third-party tool cannot own an account regardless of anything
  here. Sub-project B.
- **Deleting `Tool`.** It survives this plan either way: as the built-in registration
  source at minimum, and as the behaviour key if Phase 2's answer is the third option.
