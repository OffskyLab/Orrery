# Plugins Own Accounts

**Date:** 2026-09-25
**Status:** draft, core design
**Supersedes:** `2026-09-18-plugin-model.md` — "The principle" (the clause about
orrery's inventions never crossing), "The projection is feature-shaped" (the
claim that `orrery use` projects onto nothing), and "The first features to
project".

## What changed

The previous model had orrery own the account pool and ask a tool only about
directories. Its stated rule:

> **Vocabulary** stays with the tool. … orrery's inventions (accounts,
> workspaces, origin) never cross.

That rule is withdrawn for accounts. It produced a boundary where orrery kept a
table of accounts, kept the directories, kept the workspace association, and
asked the tool to answer questions about paths it had prepared — which is not a
tool owning anything, it is orrery doing the work and outsourcing a lookup.

The new rule is **dependency inversion**:

> orrery designs the framework. The framework specifies how every plugin must
> interact with orrery. Plugins own the ecosystem behind that interface.

orrery does not keep a parallel copy of account state to reconcile against. It
decides policy and asks; the plugin persists and answers.

## Account belongs to the framework

`Account` is defined in AIToolKit, not in OrreryCore and not in a plugin. Both
sides depend on the framework's definition; neither owns it.

This reverses a documented decision. `LoginIdentity` exists today precisely
*because* an account was held to be the host's invention:

> An account is the host's invention: pooled, named, switchable. A tool knows
> only that some directory carries a login.

Under the new model that is backwards, and `LoginIdentity` is replaced by
`Account`.

## The method set

```swift
public protocol AIToolAccounts: AITool {
    func list() async throws -> [Account]
    func current() async throws -> Account?
    func setCurrent(id: AccountID) async throws
    func addAccount(id: AccountID, name: String) async throws -> Account
    func deleteAccount(id: AccountID) async throws
}
```

`current()` returns an optional: no account pinned yet is an ordinary state, not
an error.

## Who decides, who stores

The split is **decision vs. storage**, not read vs. write.

| | orrery | plugin |
|---|---|---|
| Which account to use, and when | decides | — |
| Which workspace an account belongs to | decides | stores |
| Where account directories live, and what is in them | — | owns |
| Credentials, identity files, symlinks | — | owns |
| The account list, and which is current | asks | stores |

`orrery use` stays orrery's decision — it knows the workspace layout and this
shell — and becomes `setCurrent(id:)` on the plugin, which persists it. So `use`
now projects onto a method, where the previous model said it projected onto
nothing.

## What this dissolves

Everything below is orrery holding state or knowledge that now belongs to a
plugin:

| Moves into plugins | Lines |
|---|---|
| `Storage/AccountStore.swift` — the pool, per-account `metadata.json` | ~100 |
| `OrreryAccountKit` — `ClaudeAdapter`, `CodexAdapter`, `GeminiAdapter`, `AccountDirLinker` | 721 |
| `Setup/ClaudeFlow.swift`, `CodexFlow`, `GeminiFlow`, `ToolFlow` | ~260 |
| `Setup/ClaudeKeychain.swift` — the claude half only (see below) | ~364 |
| `Setup/ClaudeJsonMerge.swift` | 235 |

`ClaudeKeychain` does not move whole. It holds two unrelated things: claude's own
credential knowledge (service naming, credential formats), which is the plugin's,
and generic Keychain primitives plus orrery's own pool keychain item, which are
not claude knowledge at all. It has to be split before anything can move.

## OrreryCore is a facade

The inversion stated precisely: OrreryCore defines, through the framework, the
types and methods it needs, and a plugin supplies them. OrreryCore depends on
the abstraction it wrote, never on a plugin's implementation — so a plugin is
free to hold whatever state it likes behind the interface, and OrreryCore cannot
reach past it to a second copy of the truth, because it does not keep one.

That is why `Account` lives in AIToolKit rather than in either side.

## Workspaces

A workspace is a management layer of its own, and eventually its own plugin, not
a field on `Account`.

What the tool plugin holds is the **account ↔ workspace pin table**: which
account is pinned to which workspace. The plugin stores it, and orrery can read
it. orrery still decides the pinning — it knows the workspace layout and this
shell — and the plugin persists the decision, the same split `setCurrent(id:)`
follows.

## The `Tool` enum goes

Not "claude moves to a plugin and the other two stay native". orrery stops
knowing which tools exist at all. `Tool` — the enum with `case claude`, `case
codex`, `case gemini` and nine behavioural members — is deleted, and with it
every `switch self` and `== .claude` that branches on identity the host had
compiled in.

This is the last place orrery hardcodes the world. Leaving it in place would keep
the facade half-built: a host that still enumerates its tools still owns them.

A tool is identified from here on by a plain string id, which the plugin states
in `tool/describe`.

### What replaces `Tool.allCases`

Enumeration comes from the registration config, exactly as
`2026-09-18-plugin-model.md` already specified: orrery records what it installed
under `~/.orrery` and reads that at runtime, rather than scanning `PATH` and
inferring. That spec's rule holds unchanged — *"what is installed" is something
orrery decided and wrote down, not an inference from the filesystem*.

Today's discovery cannot do this. `PluginDiscovery.locate(toolID:)` is a lookup
by id — it finds `orrery-<id>` for an id it is already given — and the only
source of ids is the enum. So the registration config is not an optimisation
here; it is what makes deleting the enum possible at all.

Its shape and location were left open by that spec and still are.

## Phasing

Functionality first, migration afterwards. No phase has to preserve existing
installations yet; migration is designed once the shape is settled.

**Phase 1 — claude, end to end.** `orrery-claude` owns claude's accounts, and
orrery supports Claude Code fully through the framework. This is the phase that
proves the facade: if orrery can support one tool while knowing nothing
tool-specific, the remaining two are repetition.

**Then codex and gemini leave the host too.** codex has a binary already.

**Gemini support is dropped for now, deliberately.** The enum is the whole of
orrery's gemini support, so deleting it drops gemini, and that is accepted: this
is a development version, and gemini comes back as a plugin later. Recorded so
that its absence is not later read as an oversight.

## Downstream: orrery-magi breaks

`orrery-magi` is a separate repo that pins OrreryCore by git revision, so orrery
is a library here, not only an app. It uses `Tool.allCases` in two places
(`SpecGenerator.swift:89`, `MagiCommand.swift:102`) to mean "every tool there
is", and its premise is a three-way debate — so that default is load-bearing for
it, not incidental.

Those two call sites need a registry query rather than a rename. Deleting the
enum is a breaking change for magi, and magi is refactored afterwards rather than
in step: its revision pin means it stays on working code until someone bumps it,
so orrery is free to move first.

## Open

- **`Account`'s fields.** `id` and `name` are given; `email` and `plan` are the
  facts `list` and `show` need. Settled: `workspace` is not one of them.
