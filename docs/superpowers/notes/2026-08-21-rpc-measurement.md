# RPC transport measurement

**Date:** 2026-08-21

## Spawn + initialize + describe

median: 0.007620833 seconds  min: 0.006546291 seconds  max: 0.020688583 seconds  (20 samples)

A second run of the same 20-sample test (to sanity-check variance) produced
median: 0.007690625s, min: 0.006936708s, max: 0.008974500s — medians agree to
within ~0.1ms across runs; the max is the noisy figure (0.0089s vs 0.0207s
on the first run), consistent with an occasional scheduling hiccup on an
otherwise-quick spawn rather than a systemic cost. Both runs: macOS,
`swift test --package-path /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit --filter SpawnCost`.

## orrery's real high-frequency call sites

Found by running the exact greps in Step 3 against
`Sources/OrreryCore/Shell/ShellFunctionGenerator.swift` and `Sources/`, not
by guessing which sites sound busy.

| Call site | Frequency | Reads tool facts? |
|---|---|---|
| `orrery-bin _check-update` (background version check, `ShellFunctionGenerator.swift:27`) | at most once per 4 hours (rate-limited via `$_orrery_home/.update-ts`), per shell that happens to cross the threshold | no |
| `_orrery_init` → `orrery-bin --version`, `_link-memory`, `_current-export` (`ShellFunctionGenerator.swift:255-271`) | once per new interactive shell (every new terminal/tab that sources the rc file) | `_current-export` loops `for tool in Tool.allCases` (claude, codex, gemini — 3 tools) to print export lines for pinned accounts |
| `_account-add-heal-hook` (`ShellFunctionGenerator.swift:168`) | `while true … sleep 1` — but only while an interactive `orrery use --add` flow is in progress; not part of steady-state shell use | no |
| `claude()` phantom supervisor loop, `_phantom-next` (`ShellFunctionGenerator.swift:334-351`) | once per supervised `claude` process exit/relaunch (user-driven — e.g. `/orrery:phantom` account switch), not a tight or timed loop | no |
| `Tool.allCases` elsewhere (33 occurrences across 17 files: `ListCommand`, `CurrentCommand`, `SessionsCommand`, `SetupCommand`, `RunCommand`, `AccountStore`, etc.) | one-shot, per explicit user CLI invocation (`orrery list`, `orrery current`, `orrery use`, …) — no automatic repetition found | most iterate tools to check/print per-tool state; none found inside a `sleep`/`while true`/`refreshInterval` construct |

No `refreshInterval` hits anywhere in `ShellFunctionGenerator.swift`. The
only two loops in the whole shell script are the two rows above with
`while true` — one interactive/transient (account-add heal-hook), one
gated on process exit (phantom supervisor), neither a steady-state
sub-second poll.

Notably, the thing originally assumed to be the hot RPC client — the Claude
Code status line — does not appear in any of these results: it was already
established (during design) that the status line reads orrery's config tree
and queries the keychain directly, never invoking `orrery-bin` at all. This
grep pass did not surface a status-line call site either, which is
consistent with that.

## Verdict

The measured cost of one spawn+initialize+describe round trip is ~7-8ms
median (worst observed single sample: ~21ms). The only call site that fires
automatically, without a direct user command, is `_orrery_init` on new-shell
startup, and within it only `_current-export` iterates tool facts — over 3
tools (claude, codex, gemini). Worst case, that is 3 spawns ≈ 21-24ms added
to opening a new terminal (up to roughly 60ms if every one of the 3 hit the
observed single-sample max). That is below the threshold a user would
consciously notice in shell startup latency, which already includes
prompt/plugin initialization on the order of tens to hundreds of
milliseconds for most setups.

Every other call site that touches `Tool.allCases` is a one-shot response to
an explicit CLI command the user just typed (`orrery list`, `orrery use`,
`orrery current`, `orrery setup`, …), where a single-digit-millisecond
per-tool spawn cost is not distinguishable from normal CLI latency, and the
two `while true` loops in the shell script are either interactive/transient
(account-add) or gated on a full child-process exit (phantom supervisor),
not steady-state polling that would multiply the spawn cost.

So: no, spawn-per-orrery-process for tool facts does not cost anything a
user would notice, based on the call sites this repo's evidence actually
supports. A persistent transport stays unbuilt until a measurement — not a
guess — demands it. This verdict is scoped to the call sites the Step 3
greps found; it does not rule out a future call site (e.g. a hypothetical
tight loop added later) that would change the answer.
