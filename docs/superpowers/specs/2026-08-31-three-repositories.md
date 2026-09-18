# Three Repositories

**Date:** 2026-08-31
**Status:** draft, for discussion
**Follows:** `2026-08-21-rpc-plugin-boundary-design.md`, `2026-08-26-tool-enumeration.md`
**Follows from:** `2026-09-18-plugin-model.md` — the core design. This document is
where the code ends up; that one is why the plugin exists in the shape it does.
Read it first.

## The finding that forces this

`Sources/orrery-claude/main.swift` carries this claim in its own doc comment:

> This ships with orrery but is loaded through exactly the mechanism a third
> party would use — which is what makes it evidence that the mechanism works,
> rather than a special case that proves nothing.

The claim is currently false, and measurably so. Nine files in `OrreryCore` are
named after Claude and total **1,320 lines**; **26 files** touch a claude-specific
concept. A third party cannot do what claude does, because claude's way of doing
it is to live inside the host.

The first attempt at fixing this was to extract an `OrreryClaudeKit` target
inside the orrery repository. That fails for the same reason: a target in the
host repo *is* native support. Whatever boundary it draws internally, a third
party still has no equivalent of it.

## The three repositories

| Repository | Holds | Depends on |
|---|---|---|
| **AIToolKit** | the protocol: `AITool`, `AIToolStateTransfer`, the JSON-RPC layer, `PluginServer` | — |
| **OrreryClaudeSupport** | claude's knowledge: keychain service naming, `.claude.json` identity merging, where hooks are written, which directories hold session state | AIToolKit |
| **orrery** | the host: account pool, workspaces, phantom supervision, and every decision about *what* is wanted | AIToolKit |

No cycle. orrery never imports claude's implementation; it talks to a process.

## The assignment rule

**The host says what it wants. The tool knows how.**

This is the same decomposition `AIToolStateTransfer` already uses —
`copyLoginState(from:to:)` takes plain directory URLs, and not one of its
parameters names an account, a workspace, or an origin. Applied to the 1,320
lines:

| Today | Rule | Lands in |
|---|---|---|
| `ClaudeFlow` (148) | how login state moves between two directories | OrreryClaudeSupport |
| `ClaudeKeychain` (364) | how claude's credentials are stored and named | OrreryClaudeSupport |
| `ClaudeJsonMerge` (235) | which keys in `.claude.json` are identity | OrreryClaudeSupport |
| `ClaudeSessionHookInstaller` (91), `ClaudeAuthSuccessHookInstaller` (56) | where claude's hooks are written | OrreryClaudeSupport |
| `PrepareClaudeLaunchCommand` (207) | *what* to prepare is orrery's; *which files* is claude's | split |
| `CaptureClaudeExitCommand` (86) | same split | split |
| `orrery-claude-hook` (49) | pool keychain sync, account hooks — host work throughout | orrery, and stops being claude-specific |

## Events

The last category to resolve, and the one that changes orrery's role most.

Today claude fires a hook at `orrery-claude-hook`, a binary that understands
claude's payload and performs host work. Under the split, neither half of that
belongs where it is.

### Registration and dispatch belong to the tool

1. orrery installs a plugin and starts its registration flow.
2. The plugin does everything about its own install directory.
3. The plugin writes its own hooks, pointing at a callback address orrery gave
   it. orrery never writes into the tool's directory and does not know what
   hooks exist.
4. When an event fires, orrery receives the raw payload, hands it to the plugin,
   and the plugin dispatches internally to whichever of *its own* methods
   handles that event. The plugin reports back what happened; orrery performs the
   consequences it recognises.

**orrery is the address and the consequence, not the intermediary.** It does not
parse the payload — the payload's shape is the tool's knowledge.

### Open vocabulary, limited reception

Event kinds are open strings: a third-party tool invents whatever events it has,
and registers them itself. orrery cannot then know statically what to do, so:

- orrery acts only on the kinds it recognises.
- An unrecognised kind is **recorded, never silently dropped**. A login event
  swallowed in silence surfaces much later and somewhere else — a pool
  credential that was never synced, discovered on a switch weeks afterwards.

Open on the sending side and limited on the receiving side is not a
contradiction; it is how an HTTP header works.

### The one boundary that stays

A plugin reports **facts**, not **commands**. "A login succeeded" is a fact
orrery acts on. "Overwrite this keychain item with this value" is a command, and
a host that accepts it has handed a third-party process its privileges.

The distinction is narrow but load-bearing, and it is *not* the same as
forbidding the plugin to decide things. A plugin deciding which of its own
methods handles an event is ordinary dispatch — the host obtaining an execution
method is a normal framework arrangement, not the tool commanding the host.

## Open, and deliberately unanswered here

**Packaging — resolved, and it was not the dilemma it looked like.** The draft
treated "does claude ship with orrery?" as an architectural fork, with
`swift build --product` building only the root package's products as the
obstacle. It is not a fork. *Mechanism* — claude goes through the same path a
third party does — and *convenience* — which binaries the install script puts
down by default — are independent. The install script fetches two independent
release artifacts and installs both; orrery never pulls the plugin into its build
graph, so the `--product` limitation never applies.

What follows from that, and is **not** yet done: the diagnostic added in v3.5.4
tells the user their install is broken and to run `orrery update`. That is
accurate while orrery ships the binary, and becomes wrong the moment the plugin
is independently installable — absence turns into a legitimate state, and the
message has to say how to obtain claude rather than accuse the install. The
wording changes with the split, not before it.

**Phantom supervision.** `PrepareClaudeLaunchCommand` and
`CaptureClaudeExitCommand` are marked "split" above, and the split has not been
drawn. Both are claude-specific *and* orrery's own invention; the rule says the
"what" stays and the "how" moves, but which lines are which has not been worked
out.

**When.** This is a direction, not a schedule. `AIToolStateTransfer` — protocol,
plugin server, and host-side forwarding — is finished and tested against the
current single-repo layout, and none of it changes shape under this split.
