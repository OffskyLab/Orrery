# Plugin Registration Wiring

**Goal:** make claude's registry entry come from `orrery-claude` in production, then
move orrery's own readers onto the registry — starting with the ones that can be
migrated mechanically.

**Spec:** `docs/superpowers/specs/2026-08-21-rpc-plugin-boundary-design.md`

## Where the previous phase stopped

The mechanism is built and tested; nothing in production touches it.

- `main.swift:21` calls `registerBuiltInTools()` only. `registerPlugins` has no
  production call site — tests are its only caller.
- Production's single reference to `AIToolRegistry` is a doc comment in
  `RemoteAITool.swift:19`. The registry is populated and never read.
- Fact readers still go through the enum: 26 `defaultConfigDir`, 6 `subdirectory`,
  11 `envVarName`, and 33 `Tool.allCases`.
- If `registerPlugins` were called today, `orrery-claude` would be *refused*:
  built-ins register first and `AIToolRegistration.swift:88` rejects a plugin whose
  id is taken.

## Decisions already made, and where

Two things I had been treating as open are settled in the spec, not by me:

- **Precedence.** Not "built-in wins" and not "fall back to built-in". Under *An
  installation-time distinction*: `orrery-claude` ships with orrery, so its absence
  is a broken install and a **hard error for claude**; a third-party plugin's
  absence is a **soft error** — that tool disappears, everything else continues.
- **Spawn cost.** `docs/superpowers/notes/2026-08-21-rpc-measurement.md` measured
  spawn+initialize+describe at ~7.6ms median, and found the only automatically
  fired call site to be `_orrery_init` on new-shell startup. Eager registration at
  bootstrap is inside the envelope that measurement already accepted. Lazy
  connection stays the escape hatch if a future call site changes the answer.

**Precondition, verified before writing any of this:** every install path now ships
`orrery-claude` — `install.sh` (both the tarball and build-from-source loops), the
Homebrew formula, and both `.deb` layouts, all as of v3.5.4. `orrery update` shells
out to `brew upgrade` or the install script, so there is no upgrade route that
leaves the sidecar behind. The hard-error stance would have been unsafe before
3.5.4 and is safe now.

## Global constraints

- Tests use swift-testing. Never XCTest.
- Commit messages use `[FEAT]`/`[FIX]`/`[DOCS]`, no `Co-Authored-By` trailer.
- Timeouts stay injectable; no hardcoded call timeout reaches a test.
- `Tool` stays alive this phase. Slice 2 removes *readers*, not the enum.
- A plugin failure must never abort an invocation for the other tools.

---

## Slice 1 — claude is registered from the plugin

**Exit criterion:** on a machine with `orrery-claude` installed, the shared registry
holds a `RemoteAITool` for `claude` after bootstrap, and a `BuiltInAITool` for codex
and gemini. With the binary absent, claude is absent from the registry, a diagnostic
names the broken install, and codex and gemini are unaffected.

- [ ] **Step 1.1 — `registerBuiltInTools` skips plugin-provided tools**

`AIToolRegistration` gains the list of tools orrery provides via plugin rather than
from the enum. Today that is `[.claude]`. `registerBuiltInTools` skips them, so the
id is free when `registerPlugins` runs and the existing collision guard keeps doing
its real job — stopping a *third party* from displacing a built-in.

Test first: `registerBuiltInTools(into:)` registers codex and gemini and does not
register claude; the guard's behaviour for an unexpected duplicate is unchanged.

- [ ] **Step 1.2 — failure of a shipped plugin is loud, and scoped**

`registerPlugins` currently treats every failure identically: warn on stderr, skip.
That is right for a third party and wrong for `orrery-claude`, whose absence means
the install is broken. Add the distinction the spec asks for — a shipped plugin's
failure is reported as a broken install, in the user's language, naming the binary
and how to repair it — while still leaving every other tool registered.

Not a thrown error at bootstrap: aborting the invocation would take codex and gemini
down with claude, which the spec forbids in the same breath.

Test first: a shipped-plugin id that cannot be located produces the broken-install
diagnostic and leaves the other two tools registered; a third-party id that cannot
be located produces the soft diagnostic.

- [ ] **Step 1.3 — call it from `main.swift`**

After `registerBuiltInTools()`, before the migrations — the ordering `main.swift`'s
existing comment already argues for, and which becomes load-bearing in slice 2.

Test first: an end-to-end test over the composed bootstrap (both registration calls,
against a temp dir holding a real built `orrery-claude`) asserting the registry holds
a remote claude and local codex/gemini.

- [ ] **Step 1.4 — the migration-coverage guarantee gets its test**

The spec says this must be a test, not an emergent property: a tool whose plugin
failed to load is never recorded as covered by a one-shot migration. Today the
migrations read `Tool.allCases`, so the property holds trivially and the test would
pass without exercising anything. Write it against the registry-sourced path instead,
so it is already guarding when slice 2 flips the source — and say so in the test, so
nobody reads a green test as proof of something it is not yet testing.

---

## Slice 2 — the mechanical readers move to the registry

32 of the 43 fact reads can move without changing behaviour:

| Reader | Count | Registry equivalent |
|---|---|---|
| `Tool.defaultConfigDir` | 26 | `configDirectoryName` joined to `userHomeURL()` |
| `Tool.subdirectory` | 6 | `id` |

**Exit criterion:** those 32 sites read the registry; claude's answers on that path
demonstrably come from another process; the suite is green with no behaviour change.

- [ ] **Step 2.1** — a seam that resolves a tool's facts through the registry, with
  the enum as the input key. Not a rewrite of every call site's shape.
- [ ] **Step 2.2** — migrate `subdirectory`'s 6 sites (smallest, and `id` is exact).
- [ ] **Step 2.3** — migrate `defaultConfigDir`'s 26 sites.

## Two rules that emerged while migrating, and one limitation

**Any reader reachable from a `for tool in Tool.allCases` loop stays on the enum.**
Not a syntactic rule about where the line sits — `EnvironmentStore.isOriginManaged`
is four call frames from a loop and is covered by it. Mixing an enum-sourced
iteration with registry-sourced facts produces a tool the loop knows about and
cannot describe, and the guard written in Step 1.4 only protects the case where
*both* come from the registry. This defers `EnvironmentStore`'s four sites
(`isOriginManaged`, `originTakeover`, `originRelease`), which are the highest-stakes
writes in the codebase — they move the user's real `~/.claude` in and out of orrery
storage — plus `SessionsCommand.sessionRoots`, `SetupCommand`, `UninstallCommand`
and `SandboxCommand`. They move when `Tool.allCases` moves.

**`Tool.subdirectory` is not worth migrating.** The registry equivalent is `.id`,
which for a built-in *is* `rawValue` and for the claude plugin is pinned to it by
`ClaudePluginParityTests`. Migrating its 6 sites buys nil-handling at each one and
no new source of truth. Step 2.2 as originally written is dropped; `subdirectory`
goes when the enum does.

**The absent-tool branch at a migrated call site is not directly testable.**
Production reads `AIToolRegistry.shared`, and the suite's seeding is process-wide,
so once any suite seeds it every suite sees a populated registry — there is no way
to ask a call site what it does when its tool is missing. The seam's own absence is
covered (`ToolFactsTests.unregisteredToolHasNoConfigDir`, against a private
registry), and the call sites are thin `guard let` branches, but that is coverage by
inspection and should be named as such. Making it real means these call sites taking
an injected registry the way `AIToolRegistration` does — cheap for a free function,
not cheap for `CredentialAdapter.materialize`, which is a protocol requirement. Worth
doing deliberately, not smuggled into a migration commit.

## Explicitly not in this plan

- **`Tool.envVarName`'s 11 readers.** `Tool.gemini.envVarName` returns
  `"GEMINI_CONFIG_DIR"` while `configDirEnvVar` is `nil`, and PR #52 needs that
  literal string as a key to *remove* from a child environment. `AITool` cannot yet
  express "a variable this tool ignores but that must be cleared". Migrating these
  changes gemini's behaviour and collides with an unmerged PR.
- **`Tool.allCases`'s 33 readers.** These mean "every tool there is", which is a
  compile-time claim today. Replacing it with a registry query is what actually opens
  the door to a third-party tool, and it is the change that makes the one-shot
  migrations' ordering load-bearing for real. It deserves its own plan.
- **codex and gemini plugins.** They stay on the enum bridge. The point of this phase
  is one tool proving the path end to end.
- **`Account.tool` and `Workspace.isolatedSessionTools`.** The enum is in a persisted
  format in both places; a third-party tool still cannot own an account. Sub-project B.
