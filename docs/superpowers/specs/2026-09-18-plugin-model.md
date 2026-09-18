# The Plugin Model

**Date:** 2026-09-18
**Status:** draft, core design
**Related:** `2026-08-31-three-repositories.md` (where the code lives),
`2026-08-21-rpc-plugin-boundary-design.md` (how the processes talk)

This is the design the rest follows from. The repository split and the RPC
transport are consequences of it, not the other way round.

## The principle

> **The protocol's method set is a projection of orrery's feature set.**

Two halves, and they come from different places:

- **Extent** comes from orrery. A method exists in the protocol because some
  orrery feature needs a tool to answer something. Nothing is in the protocol
  speculatively.
- **Vocabulary** stays with the tool. A method is named and typed in the tool's
  own terms — plain paths, plain facts. orrery's inventions (accounts,
  workspaces, origin) never cross.

The projection is *partial*, not many-to-one: a feature that needs nothing from
the tool — `orrery use` decides pool state and asks the tool nothing — projects
onto no method at all. What it is not is a merging: two features that both need a
tool's help get two methods, even when a plugin implements them out of the same
internal helper. See below.

## The projection is feature-shaped, and sharing belongs to the implementation

`orrery list` projects onto `list()`. `orrery show` projects onto `show()`.
`orrery use` projects onto nothing.

An earlier draft argued the opposite — that the projection should land on
capabilities rather than features, so that `list` and `show` shared one
`accountInfo()` method. The evidence offered was this comment on
`AccountAuthInfo.resolve`:

> shared by `list` and `show` so both commands agree on what "currently logged
> in" means per tool

That argument was wrong, and it is worth saying why, because it is a tempting
mistake. The comment describes how *orrery* shares an implementation internally
today. Once the plugin owns that implementation, the plugin shares it the same
way: its own `list()` and `show()` both call its own `accountInfo()` helper. **A
protocol surface does not have to be deduplicated for the implementation behind
it to be.** Collapsing two features into one method buys nothing and costs the
distinction between them.

And the distinction earns its keep. `resolve` currently takes this parameter:

> `isLiveInThisShell`: … Only then is a live credential-source read attempted;
> otherwise persisted/cached info is used.

That is the host telling the tool how hard to work — how fresh an answer to go
and get. It is a leak: how expensive it is to read an identity, and which source
is authoritative when, is knowledge about the tool's own storage. With separate
methods, the tool decides its own cost profile for each: a listing stays cheap, a
detail view reaches for the freshest source it has.

The flag does not vanish, and it would be wrong to say it does. What it actually
decides is *which directory* orrery hands over — the live `CLAUDE_CONFIG_DIR`
when this shell is pointed at that account, the pool directory otherwise. That is
orrery's own knowledge, about its pins and this shell, and it stays on orrery's
side. What stops crossing the boundary is the *instruction*: the tool is no
longer told how fresh an answer to fetch, only which directory to look in.

What the tool returns is *facts*, not formatting. The host still lays out the
row; the tool decides which of its facts each view is worth.

## Registration happens at install, not at every invocation

orrery does **not** scan `$ORRERY_HOME/tools/` or `PATH` looking for what might
be there. Discovery is a recorded fact, not a search:

1. orrery installs a plugin.
2. It runs that plugin's registration flow.
3. It records the result in a config under `~/.orrery`.

At runtime orrery reads that config. The difference matters twice over: a scan
pays for discovery on every invocation and, worse, makes "what is installed" an
inference from the filesystem rather than something orrery decided and wrote
down.

### The config records capabilities, not presence

`initialize` already advertises per method — `tool/describe`,
`tool/copyLoginState`, and so on. So what registration records is not "claude is
installed" but "claude is installed and can do these things".

That answers a question that looked open: **what must a plugin implement to be
manageable at all?** Nothing in particular. It implements what it can, the
registration records the rest as unavailable, and orrery says so when asked to
do one of them. There is no minimum set to define and no gate to pass.

## A missing binary is marked, never forgotten

Reading the config stats the binary — one syscall, no spawn.

When it is gone, the entry is **marked unavailable and the user is told**. It is
not deleted.

Deleting would be orrery pretending the plugin was never installed, and those
are different situations with different fixes: a tool that was never installed
needs installing, while a tool whose binary has vanished means something removed
it — an interrupted upgrade, a cleanup script, a partially applied uninstall.
Collapsing the two hands the user a message that cannot be acted on.

**Accepted limitation:** a stat catches removal, not substitution. A plugin
upgraded in place to a build with a different capability set will still be
described by the recorded registration. Re-registering on every invocation would
catch it, at one spawn per run; that is inside the measured budget
(`2026-08-21-rpc-measurement.md`, ~7.6 ms) but buys little while plugins
negotiate a protocol version at `initialize`. Revisit if capability sets start
moving between builds.

## What the user sees

`orrery list` prints the registered plugins, and for each asks it for the facts
that plugin owns. Two absences to keep apart:

- **A capability the plugin never declared** is a known fact, recorded at
  registration. orrery can state it plainly — this tool does not do that.
- **A declared capability that fails at call time** is a read that degrades:
  the field renders as missing, the way `ListCommand` already leaves a blank
  rather than inventing a value.

The second must never be silent where a *write* was involved. That rule predates
this document and is unchanged: an action that may not have happened is never
reported as done.

## The first features to project

`orrery list` and `orrery show`, onto `list()` and `show()`.

They are the right pair to start with because the host code behind them is
`AccountAuthInfo.resolve`: a `switch account.tool` holding claude's entire
identity fallback chain — the live `CLAUDE_CONFIG_DIR`, then
`claude-identity.json`'s `oauthAccount.emailAddress` / `subscriptionType`, then
the `metadata.json` cache, with a comment about newer Claude versions that
stopped writing `emailAddress` anywhere re-derivable. Every step of that is
claude knowledge sitting in the host, and it is exactly what a plugin's own
shared `accountInfo()` helper becomes.

Projected:

- **orrery keeps** the account pool, which accounts exist, and the layout of the
  row.
- **the tool answers** `list()` with the facts a listing needs and `show()` with
  the facts a detail view needs, deciding for itself how fresh each has to be.

Plain paths in, plain facts out — the same shape as `AIToolStateTransfer`. Two
features, two methods, one `switch account.tool` removed from the host, and the
`isLiveInThisShell` parameter gone with it.

## Open

- **The config's shape and location.** Not decided here.
- **Registration's own failure modes.** If a plugin's registration flow fails
  halfway — some capabilities recorded, others not — the recorded result is a
  partial truth. Whether that is a valid state or must be rolled back is
  undecided.
